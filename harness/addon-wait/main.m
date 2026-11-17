#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/AudioSources/SGAddons.h"

static BOOL g_redesigned = YES;
static NSInteger g_mode = SGAddonPlaybackPrefer;
static NSInteger g_waitSeconds = 5;
static BOOL g_autoSwitch = YES;
static BOOL g_hasSources = YES;
static AudioUnit g_output = (AudioUnit)1;
static SPTPlayerState *g_state;
static id<SGPlayerStateObserver> g_observer;
static NSMutableArray<dispatch_block_t> *g_delayed;
static NSUInteger g_cancelCount;
static NSUInteger g_unavailableCount;
static NSString *g_status;
static int64_t g_lastDelay;

@implementation SPTPlayerTrack
@end
@implementation SPTPlayerState
@end

void SGRWaitHarnessDispatchAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block);
dispatch_time_t SGRWaitHarnessDispatchTime(dispatch_time_t when, int64_t delta);
#define dispatch_after SGRWaitHarnessDispatchAfter
#define dispatch_time SGRWaitHarnessDispatchTime
#import "build/SGAddonPlaybackWait.m"
#undef dispatch_after
#undef dispatch_time
#import "../../tweak/Sources/Shared/AudioSources/SGAddonPolicy.m"

@interface SPTEsperantoPlayer : NSObject <SPTPlayer>
@property(nonatomic) NSUInteger pauseCount;
@property(nonatomic) NSUInteger resumeCount;
- (id)seekTo:(double)position relative:(long long)relative options:(id)options creatorTimestampPositionMs:(double)creator;
- (id)skipToNextTrackWithOptions:(id)options track:(id)track loggingParams:(id)params;
- (id)skipToPreviousTrackWithOptions:(id)options track:(id)track loggingParams:(id)params;
@end
@implementation SPTEsperantoPlayer
- (id)pause:(id)options { self.pauseCount++; return nil; }
- (id)resume:(id)options { self.resumeCount++; return nil; }
- (id)seekTo:(double)position relative:(long long)relative options:(id)options creatorTimestampPositionMs:(double)creator { return nil; }
- (id)skipToNextTrackWithOptions:(id)options track:(id)track loggingParams:(id)params { return nil; }
- (id)skipToPreviousTrackWithOptions:(id)options track:(id)track loggingParams:(id)params { return nil; }
- (id)stop { return nil; }
@end

static SPTEsperantoPlayer *g_player;
static void require(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}

BOOL SGRedesignedUI(void) { return g_redesigned; }
NSInteger SGInt(NSString *key, NSInteger fallback) {
    if ([key isEqual:SGKeyAddonPlaybackMode]) return g_mode;
    if ([key isEqual:SGKeyAddonWaitSeconds]) return g_waitSeconds;
    return fallback;
}
BOOL SGFlag(NSString *key, BOOL fallback) {
    return [key isEqual:SGKeyAddonAutoSwitch] ? g_autoSwitch : fallback;
}
AudioUnit SGPlayerMusicOutput(void) { return g_output; }
id<SPTPlayer> SGPlayer(void) { return g_player; }
SPTPlayerState *SGPlayerState(void) { return g_state; }
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) { g_observer = observer; }
NSString *SGURIString(id uri) { return [uri isKindOfClass:NSString.class] ? uri : nil; }
NSArray<NSDictionary *> *SGAddonSources(void) { return g_hasSources ? @[@{@"id": @"fixture"}] : @[]; }
void SGAddonCancel(void) { g_cancelCount++; }
void SGAddonInvalidateRequests(void) {}
void SGAddonSetPlaybackStatus(NSString *status, BOOL aligned) { g_status = status; }
void SGAddonSetPlaybackUnavailable(void) { g_unavailableCount++; }
void SGRWaitHarnessDispatchAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    if (!g_delayed) g_delayed = [NSMutableArray array];
    [g_delayed addObject:[block copy]];
}
dispatch_time_t SGRWaitHarnessDispatchTime(dispatch_time_t when, int64_t delta) {
    g_lastDelay = delta;
    return (dispatch_time_t)delta;
}

static void reportState(BOOL paused, BOOL playing, NSString *uri) {
    g_state.track.URI = uri;
    g_state.isPaused = paused;
    g_state.isPlaying = playing;
    [g_observer playerStateDidChange:g_state];
}
static void startTrack(NSString *uri) {
    g_state = [SPTPlayerState new];
    g_state.track = [SPTPlayerTrack new];
    g_state.track.URI = uri;
    g_state.isPlaying = YES;
    g_state.isPaused = NO;
}
static void begin(NSString *uri) { SGAddonBeginPlaybackWait(uri); }
static dispatch_block_t lastTimeout(void) { return g_delayed.lastObject; }

int main(void) { @autoreleasepool {
    g_player = [SPTEsperantoPlayer new];
    // The Logos constructor should have installed hooks on this fake Spotify class.
    startTrack(@"spotify:track:finish-before-ack");
    begin(@"spotify:track:finish-before-ack");
    require(g_player.pauseCount == 1, @"prefer mode pauses the playing track");
    SGAddonFinishPlaybackWait();
    require(g_player.resumeCount == 0, @"finish before Spotify reports pause does not resume early");
    reportState(YES, NO, @"spotify:track:finish-before-ack");
    require(g_player.resumeCount == 1, @"paused report after finish resumes the same track once");
    reportState(YES, NO, @"spotify:track:finish-before-ack");
    require(g_player.resumeCount == 1, @"duplicate paused report cannot resume twice");

    // Every hooked user transport command invalidates the owned wait lease.
    void (^exerciseCommand)(SEL) = ^(SEL command) {
        startTrack(@"spotify:track:user-command");
        begin(@"spotify:track:user-command");
        if (command == @selector(pause:)) [g_player pause:nil];
        else if (command == @selector(resume:)) [g_player resume:nil];
        else if (command == @selector(seekTo:relative:options:creatorTimestampPositionMs:))
            [g_player seekTo:10 relative:0 options:nil creatorTimestampPositionMs:0];
        else if (command == @selector(skipToNextTrackWithOptions:track:loggingParams:))
            [g_player skipToNextTrackWithOptions:nil track:nil loggingParams:nil];
        else if (command == @selector(skipToPreviousTrackWithOptions:track:loggingParams:))
            [g_player skipToPreviousTrackWithOptions:nil track:nil loggingParams:nil];
        else if (command == @selector(stop)) [g_player stop];
        NSUInteger resumeAfterCommand = g_player.resumeCount;
        reportState(YES, NO, @"spotify:track:user-command");
        require(g_player.resumeCount == resumeAfterCommand, @"user transport command revokes automatic resume");
    };
    exerciseCommand(@selector(pause:));
    exerciseCommand(@selector(resume:));
    exerciseCommand(@selector(seekTo:relative:options:creatorTimestampPositionMs:));
    exerciseCommand(@selector(skipToNextTrackWithOptions:track:loggingParams:));
    exerciseCommand(@selector(skipToPreviousTrackWithOptions:track:loggingParams:));
    exerciseCommand(@selector(stop));

    startTrack(@"spotify:track:old");
    begin(@"spotify:track:old");
    NSUInteger resumeBeforeChange = g_player.resumeCount;
    reportState(YES, NO, @"spotify:track:new");
    SGAddonFinishPlaybackWait();
    require(g_player.resumeCount == resumeBeforeChange, @"track change cancels the old wait lease");

    startTrack(@"spotify:track:timeout");
    begin(@"spotify:track:timeout");
    require(g_lastDelay == 5 * NSEC_PER_SEC, @"wait timeout is clamped to the five-second minimum");
    NSUInteger cancelBeforeTimeout = g_cancelCount;
    NSUInteger unavailableBeforeTimeout = g_unavailableCount;
    NSUInteger resumeBeforeTimeout = g_player.resumeCount;
    lastTimeout()(); // deterministic delivery of the production five-second dispatch_after block
    require(g_cancelCount == cancelBeforeTimeout + 1 && g_unavailableCount == unavailableBeforeTimeout + 1,
            @"five-second timeout cancels source preparation and reports unavailable");
    require([g_status containsString:@"애드온 대기 시간이 지나"], @"timeout publishes the fallback status");
    reportState(YES, NO, @"spotify:track:timeout");
    require(g_player.resumeCount == resumeBeforeTimeout + 1, @"fallback resumes after its delayed paused report");

    g_redesigned = YES;
    g_mode = SGAddonPlaybackFast;
    g_autoSwitch = YES;
    require(!SGAddonAllowsCurrentLookup(), @"fast mode does not look up a substitute");
    g_mode = SGAddonPlaybackContinuous;
    require(SGAddonAllowsCurrentLookup(), @"continuous mode allows automatic switching when enabled");
    g_autoSwitch = NO;
    require(!SGAddonAllowsCurrentLookup(), @"continuous mode disables current lookup when auto-switch is off");
    g_mode = SGAddonPlaybackPrefer;
    require(SGAddonAllowsCurrentLookup(), @"prefer mode allows addon-first lookup");
    g_redesigned = NO;
    g_mode = SGAddonPlaybackFast;
    g_autoSwitch = NO;
    require(SGAddonAllowsCurrentLookup(), @"native look retains the continuous lookup baseline despite stored fast mode");

    // Gates which must never take control away from native or ordinary playback.
    void (^assertNoPause)(NSString *, dispatch_block_t) = ^(NSString *label, dispatch_block_t configure) {
        NSUInteger before = g_player.pauseCount;
        g_redesigned = YES; g_mode = SGAddonPlaybackPrefer; g_hasSources = YES; g_output = (AudioUnit)1;
        configure();
        startTrack(@"spotify:track:no-pause");
        begin(@"spotify:track:no-pause");
        require(g_player.pauseCount == before, [NSString stringWithFormat:@"%@ does not pause", label]);
    };
    assertNoPause(@"native look", ^{ g_redesigned = NO; });
    assertNoPause(@"fast mode", ^{ g_mode = SGAddonPlaybackFast; });
    assertNoPause(@"continuous mode", ^{ g_mode = SGAddonPlaybackContinuous; });
    assertNoPause(@"no configured source", ^{ g_hasSources = NO; });
    assertNoPause(@"no local audio output", ^{ g_output = 0; });

    NSLog(@"PASS: addon playback wait fixtures");
} return 0; }
