//
//  CBLView+Internal.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 12/8/11.
//  Copyright (c) 2011-2013 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CBLView+Internal.h"
#import "CBLInternal.h"
#import "CouchbaseLitePrivate.h"
#import "CBLCollateJSON.h"
#import "CBLMisc.h"
#import "ExceptionUtils.h"

#import <CBForest/CBForest.hh>

using namespace forestdb;


@implementation CBLView (Querying)


#pragma mark - QUERYING:


/** Main internal call to query a view. */
- (CBLQueryIteratorBlock) _queryWithOptions: (CBLQueryOptions*)options
                                     status: (CBLStatus*)outStatus
{
    if (!options)
        options = [CBLQueryOptions new];
    CBLQueryIteratorBlock iterator;
    if (options.fullTextQuery) {
        iterator = [self _fullTextQueryWithOptions: options status: outStatus];
    } else if ([self groupOrReduceWithOptions: options])
        iterator = [self _reducedQueryWithOptions: options status: outStatus];
    else
        iterator = [self _regularQueryWithOptions: options status: outStatus];
    LogTo(View, @"Query %@: Returning iterator", _name);
    return iterator;
}


// Should this query be run as grouped/reduced?
- (BOOL) groupOrReduceWithOptions: (CBLQueryOptions*) options {
    if (options->group || options->groupLevel > 0)
        return YES;
    else if (options->reduceSpecified)
        return options->reduce;
    else
        return (self.reduceBlock != nil); // Reduce defaults to true iff there's a reduce block
}


- (CBLQueryIteratorBlock) _regularQueryWithOptions: (CBLQueryOptions*)options
                                            status: (CBLStatus*)outStatus
{
    IndexEnumerator e = [self _runForestQueryWithOptions: options];
    if (!e)
        return nil;

    CBLDatabase* db = _weakDB;
    return ^CBLQueryRow*() {
        if (!e)
            return nil;

        id docContents = nil;
        id value = e.value;
        NSString* docID = e.docID;
        SequenceNumber sequence = e.sequence;
        if (options->includeDocs) {
            NSDictionary* valueDict = nil;
            NSString* linkedID = nil;
            if (value) {
                valueDict = $castIf(NSDictionary, value);
                linkedID = valueDict.cbl_id;
            }
            if (linkedID) {
                // Linked document: http://wiki.apache.org/couchdb/Introduction_to_CouchDB_views#Linked_documents
                NSString* linkedRev = valueDict.cbl_rev; // usually nil
                CBLStatus linkedStatus;
                CBL_Revision* linked = [db getDocumentWithID: linkedID
                                                  revisionID: linkedRev
                                                     options: options->content
                                                      status: &linkedStatus];
                docContents = linked ? linked.properties : $null;
                sequence = linked.sequence;
            } else {
                CBLStatus status;
                CBL_Revision* rev = [db getDocumentWithID: docID revisionID: nil
                                                  options: options->content status: &status];
                docContents = rev.properties;
            }
        }
        LogTo(QueryVerbose, @"Query %@: Found row with key=%@, value=%@, id=%@",
              _name, CBLJSONString(key), CBLJSONString(value), CBLJSONString(docID));
        return [[CBLQueryRow alloc] initWithDocID: docID
                                         sequence: sequence
                                              key: key
                                            value: value
                                    docProperties: docContents];
    };
}


#pragma mark - REDUCING/GROUPING:

#define PARSED_KEYS

// Are key1 and key2 grouped together at this groupLevel?
#ifdef PARSED_KEYS
static bool groupTogether(id key1, id key2, unsigned groupLevel) {
    if (groupLevel == 0)
        return [key1 isEqual: key2];
    if (![key1 isKindOfClass: [NSArray class]] || ![key2 isKindOfClass: [NSArray class]])
        return groupLevel == 1 && [key1 isEqual: key2];
    NSUInteger level = MIN(groupLevel, MIN([key1 count], [key2 count]));
    for (NSUInteger i = 0; i < level; i++) {
        if (![[key1 objectAtIndex: i] isEqual: [key2 objectAtIndex: i]])
            return NO;
    }
    return YES;
}

// Returns the prefix of the key to use in the result row, at this groupLevel
static id groupKey(id key, unsigned groupLevel) {
    if (groupLevel > 0 && [key isKindOfClass: [NSArray class]] && [key count] > groupLevel)
        return [key subarrayWithRange: NSMakeRange(0, groupLevel)];
    else
        return key;
}
#else
static bool groupTogether(NSData* key1, NSData* key2, unsigned groupLevel) {
    if (!key1 || !key2)
        return NO;
    if (groupLevel == 0)
        groupLevel = UINT_MAX;
    return CBLCollateJSONLimited(kCBLCollateJSON_Unicode,
                                (int)key1.length, key1.bytes,
                                (int)key2.length, key2.bytes,
                                groupLevel) == 0;
}

// Returns the prefix of the key to use in the result row, at this groupLevel
static id groupKey(NSData* keyJSON, unsigned groupLevel) {
    id key = fromJSON(keyJSON);
    if (groupLevel > 0 && [key isKindOfClass: [NSArray class]] && [key count] > groupLevel)
        return [key subarrayWithRange: NSMakeRange(0, groupLevel)];
    else
        return key;
}
#endif


// Invokes the reduce function on the parallel arrays of keys and values
static id callReduce(CBLReduceBlock reduceBlock, NSMutableArray* keys, NSMutableArray* values) {
    if (!reduceBlock)
        return nil;
    NSArray *lazyKeys, *lazyValues;
#ifdef PARSED_KEYS
    lazyKeys = keys;
#else
    keys = [[CBLLazyArrayOfJSON alloc] initWithMutableArray: keys];
#endif
    lazyValues = [[CBLLazyArrayOfJSON alloc] initWithMutableArray: values];
    @try {
        id result = reduceBlock(lazyKeys, lazyValues, NO);
        if (result)
            return result;
    } @catch (NSException *x) {
        MYReportException(x, @"reduce block");
    }
    return $null;
}


- (CBLQueryIteratorBlock) _reducedQueryWithOptions: (CBLQueryOptions*)options
                                            status: (CBLStatus*)outStatus
{
    unsigned groupLevel = options->groupLevel;
    bool group = options->group || groupLevel > 0;

    CBLReduceBlock reduce = self.reduceBlock;
    if (options->reduceSpecified) {
        if (!options->reduce) {
            reduce = nil;
        } else if (!reduce) {
            Warn(@"Cannot use reduce option in view %@ which has no reduce block defined",
                 _name);
            *outStatus = kCBLStatusBadParam;
            return nil;
        }
    }

    __block id lastKey = nil;
    NSMutableArray* keysToReduce = nil, *valuesToReduce = nil;
    if (reduce) {
        keysToReduce = [[NSMutableArray alloc] initWithCapacity: 100];
        valuesToReduce = [[NSMutableArray alloc] initWithCapacity: 100];
    }

    CBForestQueryEnumerator* e = [self _runForestQueryWithOptions: options status: outStatus];
    if (!e)
        return nil;

    return ^CBLQueryRow*() {
        CBLQueryRow* row = nil;
        do {
            id key = e.nextObject;
            if (lastKey && (!key || (group && !groupTogether(lastKey, key, groupLevel)))) {
                // key doesn't match lastKey; emit a grouped/reduced row for what came before:
                row = [[CBLQueryRow alloc] initWithDocID: nil
                                        sequence: 0
                                             key: (group ? groupKey(lastKey, groupLevel) : $null)
                                           value: callReduce(reduce, keysToReduce,valuesToReduce)
                                   docProperties: nil];
                [keysToReduce removeAllObjects];
                [valuesToReduce removeAllObjects];
            }

            if (key && reduce) {
                // Add this key/value to the list to be reduced:
                [keysToReduce addObject: key];
                [valuesToReduce addObject: e.valueData ?: $null];
                //TODO: Reduce the keys/values when there are too many; then rereduce at end
            }

            lastKey = key;
        } while (!row && lastKey);
        return row;
    };
}


#pragma mark - FULL-TEXT:


- (CBLQueryIteratorBlock) _fullTextQueryWithOptions: (CBLQueryOptions*)options
                                             status: (CBLStatus*)outStatus
{
    MapReduceIndex* index = self.index;
    if (!index) {
        *outStatus = kCBLStatusNotFound;
        return nil;
    } else if (index->indexType() != kCBLFullTextIndex) {
        *outStatus = kCBLStatusBadRequest;
        return nil;
    }
    NSError* error;
    NSEnumerator* e = [index enumerateDocsContainingWords: options.fullTextQuery
                                                      all: YES
                                                    error: &error];
    if (!e) {
        *outStatus = CBLStatusFromNSError(error, kCBLStatusDBError);
        return nil;
    }
    return ^CBLQueryRow*() {
        NSString* docID = e.nextObject;
        if (!docID)
            return nil;
        return [[CBLQueryRow alloc] initWithDocID: docID
                                         sequence: 0
                                              key: options.fullTextQuery
                                            value: nil
                                    docProperties: nil];
    };
}



/** Starts a view query, returning a CBForest enumerator. */
- (IndexEnumerator) _runForestQueryWithOptions: (CBLQueryOptions*)options
{
    MapReduceIndex* index = self.index;
    if (!index) {
        *outStatus = kCBLStatusNotFound;
        return nil;
    }
    Database::enumerationOptions forestOpts = Database::enumerationOptions::kDefault;
    forestOpts.skip = options->skip;
    forestOpts.limit = options->limit;
    forestOpts.descending = options->descending;
    forestOpts.inclusiveEnd = options->inclusiveEnd;
    if (options.keys) {
        return index->enumerate(collatableKeys,
                                &forestOpts);
    } else {
        return index->enumerate(forestdb::slice(options.startKey),
                                forestdb::slice(options.startKeyDocID),
                                forestdb::slice(options.endKey),
                                forestdb::slice(options.endKeyDocID),
                                &forestOpts);
    }
}


#pragma mark - OTHER:

// This is really just for unit tests & debugging
#if DEBUG
- (NSArray*) dump {
    MapReduceIndex* index = self.index;
    if (!index)
        return nil;
    NSMutableArray* result = $marray();
    CBForestQueryEnumerator* e = [[CBForestQueryEnumerator alloc] initWithIndex: index
                                                                       startKey: nil startDocID: nil endKey: nil endDocID: nil options: NULL error: NULL];
    while (e.nextObject) {
        [result addObject: $dict({@"key", CBLJSONString(e.key)},
                                 {@"value", [e.valueData my_UTF8ToString]},
                                 {@"seq", @(e.sequence)})];
    }
    return result;
}
#endif


@end