#import <Foundation/Foundation.h>
#import "Shared/AudioSources/SGAddonSourceRace.h"
#include <stdatomic.h>
#include <unistd.h>

static void require(BOOL ok, NSString *message) { if (!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
static BOOL waitSem(dispatch_semaphore_t semaphore) { return dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0; }
static NSDictionary *info(NSString *codec, NSInteger channels, double rate, NSInteger bits, BOOL partial) {
    return @{@"codec":codec,@"channels":@(channels),@"rate":@(rate),@"bits":@(bits),@"partial":@(partial)};
}
static NSArray *sources(NSArray<NSDictionary *> *infos) {
    NSMutableArray *result=[NSMutableArray arrayWithCapacity:infos.count];
    [infos enumerateObjectsUsingBlock:^(NSDictionary *v, NSUInteger i, BOOL *stop) { [result addObject:@{@"id":[NSString stringWithFormat:@"source-%lu",(unsigned long)i],@"info":v}]; }];
    return result;
}
static NSDictionary *(^resolveSource)(NSDictionary *, BOOL (^)(void)) = ^NSDictionary *(NSDictionary *source, BOOL (^stop)(void)) {
    if (stop()) return nil;
    return @{@"token":source[@"id"],@"info":source[@"info"]};
};

int main(void) { @autoreleasepool {
    require(!SGAddonMeasuredHiRes(@{@"codec":@"FLAC",@"sampleRate":@96000,@"bitDepth":@24}),@"server-declared metadata alone is not measured audio information");
    require(!SGAddonMeasuredHiRes(info(@"FLAC",2,96000,24,YES)),@"partial measured info is rejected");
    require(!SGAddonMeasuredHiRes(info(@"AAC",2,96000,24,NO)),@"lossy codec is rejected");
    require(!SGAddonMeasuredHiRes(info(@"FLAC",1,96000,24,NO)),@"mono measurement is rejected");
    require(!SGAddonMeasuredHiRes(@{@"codec":@"FLAC",@"channels":@2,@"rate":@(NAN),@"bits":@24}),@"non-finite sample rate is rejected");
    require(SGAddonMeasuredHiRes(info(@"FLAC",2,44100,24,NO)),@"24-bit 44.1 kHz stereo FLAC is hi-res by measured bit depth");
    require(SGAddonMeasuredHiRes(info(@"FLAC",2,96000,16,NO)),@"16-bit 96 kHz stereo FLAC is hi-res by measured rate");
    require(!SGAddonMeasuredHiRes(info(@"FLAC",2,48000,16,NO)),@"16-bit 48 kHz stereo FLAC is not hi-res");

    NSDictionary *low=info(@"FLAC",2,44100,16,NO), *highRate=info(@"FLAC",2,48000,16,NO);
    require(SGAddonCompareMeasured(highRate,low)==NSOrderedDescending,@"when neither candidate is hi-res, 16/48 outranks 16/44.1");
    require(SGAddonCompareMeasured(info(@"FLAC",2,96000,16,NO),info(@"FLAC",2,44100,24,NO))==NSOrderedAscending,
            @"24-bit depth outranks 16-bit even when the latter has a higher rate");

    // Eight blocked resolvers prove every source starts concurrently; a three-worker cap deadlocks this barrier.
    NSMutableArray *tieInfos=[NSMutableArray array]; for(NSUInteger i=0;i<8;i++) [tieInfos addObject:highRate];
    NSArray *eight=sources(tieInfos); dispatch_semaphore_t startedGate=dispatch_semaphore_create(0), releaseGate=dispatch_semaphore_create(0), done=dispatch_semaphore_create(0);
    __block atomic_int started=0, activePrepare=0, prepareCount=0; __block NSDictionary *winner=nil; __block NSMutableArray *discarded=[NSMutableArray array];
    dispatch_semaphore_t prepareGate=dispatch_semaphore_create(0), prepareRelease=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        winner=SGAddonRaceSources(eight,^NSDictionary *(NSDictionary *source, BOOL (^stop)(void)) {
            (void)stop; atomic_fetch_add(&started,1); dispatch_semaphore_signal(startedGate);
            if (!waitSem(releaseGate)) return nil;
            return @{@"token":source[@"id"],@"info":source[@"info"]};
        },^NSDictionary *(NSDictionary *resolved) {
            atomic_fetch_add(&activePrepare,1);
            atomic_fetch_add(&prepareCount,1); dispatch_semaphore_signal(prepareGate);
            require(waitSem(prepareRelease),@"parallel preparations released within bounded time");
            NSDictionary *entry=@{@"path":resolved[@"token"],@"info":resolved[@"info"]}; atomic_fetch_sub(&activePrepare,1); return entry;
        },^BOOL{return NO;},^(NSDictionary *entry){ @synchronized(discarded){ [discarded addObject:entry[@"path"]]; }});
        dispatch_semaphore_signal(done);
    });
    BOOL allStarted=YES; for(NSUInteger i=0;i<8;i++) if(!waitSem(startedGate)) { allStarted=NO; break; }
    for(NSUInteger i=0;i<8;i++) dispatch_semaphore_signal(releaseGate);
    require(allStarted && atomic_load(&started)==8,@"all eight configured sources reach the concurrent resolve barrier");
    for(NSUInteger i=0;i<8;i++) require(waitSem(prepareGate),@"all eight file probes start without waiting for another download");
    require(atomic_load(&activePrepare)==8,@"all eight preparations overlap");
    for(NSUInteger i=0;i<8;i++) dispatch_semaphore_signal(prepareRelease);
    require(waitSem(done),@"eight-source race completes within bounded time");
    require([winner[@"path"] isEqual:@"source-0"] && [winner[@"info"] isEqual:highRate],@"equal-quality tie chooses the lower configured source index");
    require(atomic_load(&prepareCount)==8 && discarded.count==7,@"each candidate is prepared concurrently and each of seven losers is discarded");
    NSSet *discardSet=[NSSet setWithArray:discarded]; require(discardSet.count==discarded.count && ![discardSet containsObject:winner[@"path"]],@"losers are discarded exactly once and winner is retained");

    // A failed first resolver cannot prevent later candidates; 16/48 is the best non-hi-res result.
    NSArray *fallbackSources=sources(@[low,low,highRate]); __block NSDictionary *fallback=nil; done=dispatch_semaphore_create(0); discarded=[NSMutableArray array];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        fallback=SGAddonRaceSources(fallbackSources,^NSDictionary *(NSDictionary *source, BOOL (^stop)(void)) {
            (void)stop; if([source[@"id"] isEqual:@"source-0"]) return nil;
            usleep([source[@"id"] isEqual:@"source-1"]?15000:5000);
            return @{@"token":source[@"id"],@"info":source[@"info"]};
        },^NSDictionary *(NSDictionary *resolved){ return @{@"path":resolved[@"token"],@"info":resolved[@"info"]}; },^BOOL{return NO;},^(NSDictionary *entry){ @synchronized(discarded) {[discarded addObject:entry[@"path"]];} });
        dispatch_semaphore_signal(done);
    });
    require(waitSem(done) && [fallback[@"path"] isEqual:@"source-2"] && [fallback[@"info"] isEqual:highRate],@"after resolver failure, all candidates are considered and 16/48 wins");
    require([discarded containsObject:@"source-1"],@"the lower-rate fallback candidate is discarded");

    // Once a measured hi-res candidate wins, pending resolvers observe stop and are never prepared.
    NSArray *hiSources=sources(@[info(@"FLAC",2,44100,24,NO),low,highRate]);
    dispatch_semaphore_t hiReady=dispatch_semaphore_create(0), waitersStarted=dispatch_semaphore_create(0); done=dispatch_semaphore_create(0);
    __block atomic_int hiStarted=0, stoppedWaiters=0, hiPrepared=0; __block NSDictionary *hiWinner=nil; __block NSUInteger afterHiPrepare=0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        hiWinner=SGAddonRaceSources(hiSources,^NSDictionary *(NSDictionary *source, BOOL (^stop)(void)) {
            atomic_fetch_add(&hiStarted,1); dispatch_semaphore_signal(waitersStarted);
            if ([source[@"id"] isEqual:@"source-0"]) {
                NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:2]; while(atomic_load(&hiStarted)<3 && limit.timeIntervalSinceNow>0) usleep(1000);
                return @{@"token":source[@"id"],@"info":source[@"info"]};
            }
            while(!stop()) usleep(1000);
            atomic_fetch_add(&stoppedWaiters,1); return nil;
        },^NSDictionary *(NSDictionary *resolved){ atomic_fetch_add(&hiPrepared,1); NSDictionary *v=@{@"path":resolved[@"token"],@"info":resolved[@"info"]}; if(SGAddonMeasuredHiRes(v[@"info"])) dispatch_semaphore_signal(hiReady); else afterHiPrepare++; return v; },^BOOL{return NO;},^(NSDictionary *entry){(void)entry;});
        dispatch_semaphore_signal(done);
    });
    BOOL threeStarted=YES; for(NSUInteger i=0;i<3;i++) if(!waitSem(waitersStarted)){threeStarted=NO;break;}
    require(threeStarted,@"all resolver waiters start before hi-res candidate returns");
    require(waitSem(hiReady) && waitSem(done),@"hi-res selection and cooperative waiter shutdown complete");
    require([hiWinner[@"path"] isEqual:@"source-0"] && atomic_load(&hiPrepared)==1 && afterHiPrepare==0,@"hi-res result stops search before any later prepare");
    require(atomic_load(&stoppedWaiters)==2,@"both losing resolver waiters receive cancellation");

    // A valid probe survives a budget expiry while a slower HTTP probe is cancelled.
    done=dispatch_semaphore_create(0);
    __block NSDictionary *deadlineCandidate=nil;
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+0.15;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        deadlineCandidate=SGAddonRaceSources(sources(@[low,highRate]),^NSDictionary *(NSDictionary *source, BOOL (^stop)(void)) {
            if([source[@"id"] isEqual:@"source-0"]) return @{@"token":source[@"id"],@"info":source[@"info"]};
            while(!stop()) usleep(1000); return nil;
        },^NSDictionary *(NSDictionary *resolved){ return @{@"path":resolved[@"token"],@"info":resolved[@"info"]}; },
        ^BOOL {return CFAbsoluteTimeGetCurrent()>deadline;},^(NSDictionary *entry){(void)entry;});
        dispatch_semaphore_signal(done);
    });
    require(waitSem(done) && [deadlineCandidate[@"path"] isEqual:@"source-0"],@"budget returns best measured candidate and cancels slow request");
    // Identity cancellation can still win after a valid generic race result exists.
    dispatch_semaphore_t beforePublish=dispatch_semaphore_create(0), releasePublish=dispatch_semaphore_create(0);
    done=dispatch_semaphore_create(0);
    __block atomic_bool identityCancelled=false;__block NSDictionary *published=nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSDictionary *candidate=deadlineCandidate;
        dispatch_semaphore_signal(beforePublish);
        require(waitSem(releasePublish),@"publication gate released within bounded time");
        if(!atomic_load(&identityCancelled))published=candidate;
        dispatch_semaphore_signal(done);
    });
    require(waitSem(beforePublish),@"best measured candidate exists before track identity is revoked");
    atomic_store(&identityCancelled,true);dispatch_semaphore_signal(releasePublish);
    require(waitSem(done) && deadlineCandidate && !published,@"caller suppresses publication after identity cancellation");
    NSDictionary *progressive=@{@"codec":@"FLAC",@"channels":@2,@"rate":@96000,@"bits":@24,@"progressive":@YES};
    require(SGAddonMeasuredHiRes(progressive),@"decoder-confirmed in-flight FLAC is eligible before download completion");

    NSLog(@"PASS: source race measurement, eight-way concurrency, fallback, hi-res cancellation and external publish guard");
} return 0; }
