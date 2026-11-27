#import "SGAddonSourceRace.h"
#include <math.h>

static BOOL measured(NSDictionary *info) {
    if (![info isKindOfClass:NSDictionary.class] || [info[@"partial"] boolValue]) return NO;
    NSString *codec=[info[@"codec"] isKindOfClass:NSString.class] ? [info[@"codec"] uppercaseString] : @"";
    double rate=[info[@"rate"] doubleValue];
    return [@[@"FLAC",@"ALAC",@"PCM"] containsObject:codec] && [info[@"channels"] integerValue]==2 && isfinite(rate) && rate>0;
}
BOOL SGAddonMeasuredHiRes(NSDictionary *info) {
    return measured(info) && ([info[@"bits"] integerValue]>16 || [info[@"rate"] doubleValue]>48000);
}
NSComparisonResult SGAddonCompareMeasured(NSDictionary *a, NSDictionary *b) {
    if (!measured(a)) return measured(b) ? NSOrderedAscending : NSOrderedSame;
    if (!measured(b)) return NSOrderedDescending;
    NSInteger depthA=[a[@"bits"] integerValue], depthB=[b[@"bits"] integerValue];
    if (depthA!=depthB) return depthA>depthB ? NSOrderedDescending : NSOrderedAscending;
    double rateA=[a[@"rate"] doubleValue], rateB=[b[@"rate"] doubleValue];
    return rateA>rateB ? NSOrderedDescending : rateA<rateB ? NSOrderedAscending : NSOrderedSame;
}
@interface SGAddonRaceState : NSObject
@property(atomic) BOOL cancelled;
@end
@implementation SGAddonRaceState
@end
NSDictionary *SGAddonRaceSources(NSArray<NSDictionary *> *sources,
    NSDictionary *(^resolve)(NSDictionary *, BOOL (^)(void)), NSDictionary *(^prepare)(NSDictionary *),
    BOOL (^externalStop)(void), void (^discard)(NSDictionary *)) {
    SGAddonRaceState *state=[SGAddonRaceState new];
    BOOL (^stop)(void)=^BOOL { return state.cancelled || externalStop(); };
    NSObject *lock=[NSObject new]; NSMutableArray *ready=[NSMutableArray array];
    dispatch_group_t jobs=dispatch_group_create(); dispatch_semaphore_t changed=dispatch_semaphore_create(0);
    __block NSUInteger completed=0;
    for (NSUInteger index=0;index<sources.count;index++) {
        NSDictionary *source=sources[index];
        dispatch_group_async(jobs,dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ @autoreleasepool {
            NSDictionary *result=stop() ? nil : resolve(source,stop);
            NSDictionary *entry=result && !stop() ? prepare(result) : nil;
            if(entry && !measured(entry[@"info"])) {discard(entry);entry=nil;}
            BOOL queued=NO;
            @synchronized(lock) {
                if(entry && !stop()) { [ready addObject:@{@"value":entry,@"index":@(index)}]; queued=YES; }
                completed++;
            }
            if(entry && !queued) discard(entry);
            dispatch_semaphore_signal(changed);
        }});
    }
    NSDictionary *best=nil; NSUInteger bestIndex=NSUIntegerMax;
    while (!externalStop()) {
        NSDictionary *next=nil; BOOL drained=NO;
        @synchronized(lock) {
            if (ready.count) {next=ready.firstObject;[ready removeObjectAtIndex:0];}
            drained=completed==sources.count;
        }
        if(!next) { if(drained)break; dispatch_semaphore_wait(changed,dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC));continue; }
        NSDictionary *entry=next[@"value"];
        if(externalStop()) {discard(entry);break;}
        NSComparisonResult order=SGAddonCompareMeasured(entry[@"info"],best[@"info"]);
        NSUInteger index=[next[@"index"] unsignedIntegerValue];
        if(order==NSOrderedDescending || (!best && measured(entry[@"info"])) || (order==NSOrderedSame && index<bestIndex)) {
            if(best)discard(best);best=entry;bestIndex=index;
        } else discard(entry);
        if(SGAddonMeasuredHiRes(best[@"info"]))break;
    }
    // Revoke HTTP on every losing resolver before returning; no background round may leak into the next track.
    state.cancelled=YES;
    dispatch_group_wait(jobs,DISPATCH_TIME_FOREVER);
    for (NSDictionary *unused in ready) discard(unused[@"value"]);
    // A time budget may end with a valid lower-resolution candidate. Identity/skip cancellation
    // is checked separately by the caller before publishing that candidate.
    return best;
}
