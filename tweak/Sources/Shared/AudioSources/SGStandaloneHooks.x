// Spotify 9.1.90: signatures checked in native-source-runtime.json and engine probe.
// No backend restrictions are changed. The UI overlay permits control of our own file only.
#import "SGStandalonePlayback.h"
#import "SGAddons.h"
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import <objc/runtime.h>
#import <objc/message.h>

static IMP sg_rawPaused, sg_rawPosition;
static __weak id sg_platform;
static NSObject *platformLock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock=[NSObject new]; }); return lock;
}
BOOL SGStandaloneNativePaused(id state) {
    return state && sg_rawPaused ? ((BOOL(*)(id,SEL))sg_rawPaused)(state,@selector(isPaused)) : YES;
}
double SGStandaloneNativePosition(id state) {
    return state && sg_rawPosition ? ((double(*)(id,SEL))sg_rawPosition)(state,@selector(positionAsOfTimestamp)) : 0;
}
void SGStandalonePublish(void) {
    id target; @synchronized(platformLock()) { target=sg_platform; }
    if (!target) return;
    id player=SGPlayer(); id state=[(id<SPTPlayer>)player state];
    if (player && state) ((void(*)(id,SEL,id,id))objc_msgSend)(target,NSSelectorFromString(@"player:stateDidChange:"),player,state);
}

%hook SPTPlayerState
- (double)position {
    NSDictionary *clock=SGStandaloneClock(self);
    if (!clock) return %orig;
    double position=[clock[@"position"] doubleValue];
    if ([clock[@"playing"] boolValue]) position+=MAX(0,MIN(.05,CFAbsoluteTimeGetCurrent()-[clock[@"stamp"] doubleValue]));
    return MIN([clock[@"duration"] doubleValue],position);
}
- (double)positionAsOfTimestamp {
    NSDictionary *clock=SGStandaloneClock(self);
    return clock ? [clock[@"position"] doubleValue] : %orig;
}
- (NSDate *)timestamp {
    NSDictionary *clock=SGStandaloneClock(self);
    return clock ? [NSDate dateWithTimeIntervalSinceReferenceDate:[clock[@"stamp"] doubleValue]] : %orig;
}
- (BOOL)isPaused { NSDictionary *clock=SGStandaloneClock(self); return clock ? ![clock[@"playing"] boolValue] : %orig; }
- (BOOL)isPlaying { return SGStandaloneClock(self) ? YES : %orig; }
- (double)playbackSpeed { return SGStandaloneClock(self) ? 1 : %orig; }
%end

%hook SPTEsperantoPlayer
- (void)addPlayerObserver:(id)observer {
    NSString *name=NSStringFromClass([observer class]);
    if ([name containsString:@"NowPlaying_Platform"] && [observer respondsToSelector:@selector(player:stateDidChange:)]) {
        @synchronized(platformLock()) { sg_platform=observer; }
    }
    %orig;
}
- (id)pause:(id)options { if (SGStandalonePause(YES)) return nil; return %orig; }
- (id)resume:(id)options { if (SGStandalonePause(NO)) return nil; return %orig; }
- (id)seekTo:(double)position relative:(long long)relative options:(id)options creatorTimestampPositionMs:(double)creator {
    if (SGStandaloneSeek(position,relative)) return nil;
    return %orig;
}
- (id)skipToNextTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    if (!SGStandaloneEnabled() || SGStandaloneInternalCommand()) return %orig;
    dispatch_block_t invoke=^{
        id next=track ?: [SGPlayerState().future firstObject];
        SGStandaloneWillSkip(SGURIString([next URI]));
        %orig;
        SGStandaloneDidSkip();
    };
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),invoke); return nil; }
    id next=track ?: [SGPlayerState().future firstObject];
    SGStandaloneWillSkip(SGURIString([next URI]));
    id task=%orig; SGStandaloneDidSkip(); return task;
}
- (id)skipToPreviousTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    if (!SGStandaloneEnabled() || SGStandaloneInternalCommand()) return %orig;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGStandaloneWillSkip(nil); %orig; }); return nil;
    }
    SGStandaloneWillSkip(nil); return %orig;
}
- (id)playContext:(id)context options:(id)options loggingParams:(id)params origin:(id)origin {
    if (!SGStandaloneEnabled() || SGStandaloneInternalCommand()) return %orig;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGStandaloneWillSkip(nil); %orig; }); return nil;
    }
    SGStandaloneWillSkip(nil); return %orig;
}
- (id)stop {
    if (SGStandaloneEnabled() && !SGStandaloneInternalCommand()) {
        if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ SGStandaloneWillSkip(nil); %orig; }); return nil; }
        SGStandaloneWillSkip(nil);
    }
    return %orig;
}
%end

%hook SPTNowPlayingPlaybackControllerImplementation
- (BOOL)isPaused { return SGStandaloneActive() ? [SGStandaloneClock(SGPlayerState())[@"playing"] boolValue]==NO : %orig; }
- (void)setPaused:(BOOL)paused { if (SGStandalonePause(paused)) return; %orig; }
%end
%hook SPTPlayerRestrictions
- (BOOL)disallowPausing { return SGStandaloneActive() ? ![SGStandaloneClock(SGPlayerState())[@"playing"] boolValue] : %orig; }
- (BOOL)disallowResuming { return SGStandaloneActive() ? [SGStandaloneClock(SGPlayerState())[@"playing"] boolValue] : %orig; }
- (BOOL)disallowSeeking { return SGStandaloneActive() ? NO : %orig; }
%end

%hook _TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation
- (void)player:(id)player stateDidChange:(id)state {
    if (NSThread.isMainThread) SGStandaloneObserveNativeState(state);
    else dispatch_async(dispatch_get_main_queue(), ^{ SGStandaloneObserveNativeState(state); });
    %orig;
}
%end
// Refuse the experimental bridge as a unit if a supported selector changes ABI.
static BOOL matches(Class cls, NSString *name, const char *returns, NSArray<NSString *> *arguments) {
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));
    if (!method || method_getNumberOfArguments(method)!=arguments.count+2) return NO;
    char *type=method_copyReturnType(method); BOOL valid=type && strchr(returns,type[0]); free(type);
    for (NSUInteger index=0; valid && index<arguments.count; ++index) {
        type=method_copyArgumentType(method,(unsigned)index+2);
        valid=type && strchr(arguments[index].UTF8String,type[0]); free(type);
    }
    return valid;
}
%ctor {
    if (!SGRedesignedUI() || !SGFlag(SGKeyAddons,NO)) return;
    Class state=NSClassFromString(@"SPTPlayerState");
    Method paused=class_getInstanceMethod(state,@selector(isPaused));
    Method position=class_getInstanceMethod(state,@selector(positionAsOfTimestamp));
    if (!paused || !position || !NSClassFromString(@"SPTNowPlayingPlaybackControllerImplementation")) return;
    Class player=NSClassFromString(@"SPTEsperantoPlayer"), options=NSClassFromString(@"SPTPlayOptions");
    Class restrictions=NSClassFromString(@"SPTPlayerRestrictions"), ui=NSClassFromString(@"SPTNowPlayingPlaybackControllerImplementation");
    if (!matches(state,@"isPaused","Bc",@[]) || !matches(state,@"positionAsOfTimestamp","d",@[])
        || !matches(state,@"position","d",@[]) || !matches(state,@"timestamp","@",@[])
        || !matches(options,@"setInitiallyPaused:","v",@[@"Bc"])
        || !matches(options,@"setSeekTo:","v",@[@"@"])
        || !matches(options,@"setSkipTo:","v",@[@"@"])
        || !matches(player,@"playContext:options:loggingParams:origin:","@",@[@"@",@"@",@"@",@"@"])
        || !matches(player,@"pause:","@",@[@"@"]) || !matches(player,@"resume:","@",@[@"@"])
        || !matches(state,@"isPlaying","Bc",@[]) || !matches(state,@"playbackSpeed","d",@[])
        || !matches(player,@"addPlayerObserver:","v",@[@"@"])
        || !matches(player,@"seekTo:relative:options:creatorTimestampPositionMs:","@",@[@"d",@"qQ",@"@",@"d"])
        || !matches(player,@"skipToNextTrackWithOptions:track:loggingParams:","@",@[@"@",@"@",@"@"])
        || !matches(player,@"skipToPreviousTrackWithOptions:track:loggingParams:","@",@[@"@",@"@",@"@"])
        || !matches(player,@"stop","@",@[])
        || !matches(ui,@"isPaused","Bc",@[]) || !matches(ui,@"setPaused:","v",@[@"Bc"])
        || !matches(restrictions,@"disallowPausing","Bc",@[])
        || !matches(restrictions,@"disallowResuming","Bc",@[])
        || !matches(restrictions,@"disallowSeeking","Bc",@[])) {
        SGLog(@"%@",@"addon engine: unsupported runtime signatures; existing playback path retained"); return;
    }
    sg_rawPaused=method_getImplementation(paused); sg_rawPosition=method_getImplementation(position);
    %init;
    SGStandaloneSetHooksReady(YES);
}
