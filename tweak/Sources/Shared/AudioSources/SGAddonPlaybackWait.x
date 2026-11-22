// An owned, bounded pause lease. Any user transport command revokes automatic resume.
#import "SGAddons.h"
#import "SGStandalonePlayback.h"
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import <stdatomic.h>

static atomic_uint_fast64_t sg_transportCommands;
static _Thread_local BOOL sg_ownedCommand;
@interface SGAddonWait : NSObject <SGPlayerStateObserver>
@property(nonatomic, copy) NSString *uri;
@property(nonatomic) uint64_t command, serial;
@property(nonatomic) BOOL finished;
- (void)finish;
@end
static SGAddonWait *sg_wait;
@implementation SGAddonWait
- (void)playerStateDidChange:(SPTPlayerState *)state { [self playerStateDidReport:state]; }
- (void)playerStateDidReport:(SPTPlayerState *)state {
    if (!self.uri) return;
    if (self.command != atomic_load(&sg_transportCommands) || ![SGURIString(state.track.URI) isEqual:self.uri]) {
        self.uri = nil; return;
    }
    if (self.finished && state.isPaused) {
        self.uri = nil;
        id<SPTPlayer> player = SGPlayer();
        if ([player respondsToSelector:@selector(resume:)]) {
            sg_ownedCommand = YES; [player resume:nil]; sg_ownedCommand = NO;
        }
    }
}
- (void)finish {
    self.finished = YES;
    [self playerStateDidReport:SGPlayerState()];
}
@end
void SGAddonBeginPlaybackWait(NSString *uri) {
    if (!SGRedesignedUI() || SGAddonPlaybackMode() != SGAddonPlaybackPrefer || !uri.length ||
        !SGAddonEnabledSources().count || !SGPlayerMusicOutput()) return;
    id<SPTPlayer> player = SGPlayer();
    SPTPlayerState *state = SGPlayerState();
    if (state.isPaused || !state.isPlaying || ![player respondsToSelector:@selector(pause:)]) return;
    if (!sg_wait) { sg_wait = [SGAddonWait new]; SGAddPlayerStateObserver(sg_wait); }
    sg_wait.uri = uri; sg_wait.finished = NO;
    sg_wait.command = atomic_load(&sg_transportCommands);
    uint64_t serial = ++sg_wait.serial;
    sg_ownedCommand = YES; [player pause:nil]; sg_ownedCommand = NO;
    double seconds = MAX(5, MIN(30, SGInt(SGKeyAddonWaitSeconds, 10)));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sg_wait.serial != serial || !sg_wait.uri || sg_wait.finished) return;
        if (sg_wait.command != atomic_load(&sg_transportCommands)) { sg_wait.uri = nil; return; }
        [sg_wait finish];
        SGAddonCancel();
        SGAddonSetPlaybackStatus(@"애드온 대기 시간이 지나 Spotify 기본 스트림으로 재생합니다", NO);
        SGAddonSetPlaybackUnavailable();
    });
}
void SGAddonFinishPlaybackWait(void) { [sg_wait finish]; }
BOOL SGAddonTakePlaybackWait(NSString *uri) {
    if (![sg_wait.uri isEqual:uri] || sg_wait.command!=atomic_load(&sg_transportCommands)) return NO;
    sg_wait.uri=nil; ++sg_wait.serial; return YES;
}
// Signatures are already declared/called in Headers/SPTPlayer.h and Shared/Sing/Sing.x.
%hook SPTEsperantoPlayer
- (id)pause:(id)options {
    if (!sg_ownedCommand && !SGStandaloneInternalCommand()) atomic_fetch_add(&sg_transportCommands, 1);
    return %orig;
}
- (id)resume:(id)options {
    if (!sg_ownedCommand && !SGStandaloneInternalCommand()) atomic_fetch_add(&sg_transportCommands, 1);
    return %orig;
}
- (id)seekTo:(double)position relative:(long long)relative options:(id)options creatorTimestampPositionMs:(double)creator {
    atomic_fetch_add(&sg_transportCommands, 1); return %orig;
}
- (id)skipToNextTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    atomic_fetch_add(&sg_transportCommands, 1); SGAddonInvalidateRequests(); return %orig;
}
- (id)skipToPreviousTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    atomic_fetch_add(&sg_transportCommands, 1); SGAddonInvalidateRequests(); return %orig;
}
- (id)stop { atomic_fetch_add(&sg_transportCommands, 1); SGAddonInvalidateRequests(); return %orig; }
%end
%ctor {
    if (!SGRedesignedUI()) return;
    %init;
}
