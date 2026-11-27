#import <Foundation/Foundation.h>

BOOL SGAddonMeasuredHiRes(NSDictionary *info);
NSComparisonResult SGAddonCompareMeasured(NSDictionary *a, NSDictionary *b);
// Resolve and prepare run concurrently; discard may run on any worker.
// Prepare must honor the stop block supplied to its resolver, including HTTP/probe waits.
NSDictionary *SGAddonRaceSources(NSArray<NSDictionary *> *sources,
    NSDictionary *(^resolve)(NSDictionary *source, BOOL (^stop)(void)),
    NSDictionary *(^prepare)(NSDictionary *resolved),
    BOOL (^stop)(void), void (^discard)(NSDictionary *entry));
