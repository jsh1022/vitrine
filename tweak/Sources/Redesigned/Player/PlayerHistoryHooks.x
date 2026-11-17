#import "Core/SGCore.h"
#import "PlayerHistory.h"

@interface _TtC14Queue_ViewImpl19QueueViewController : UIViewController
@end

// Verified against the local Spotify 9.1.90 binary and the live queue tree.
%hook _TtC14Queue_ViewImpl19QueueViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SGRPlayerUpdateHistory(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    SGRPlayerLayoutHistory(self);
}
%end

// These terminal selectors are already verified by Shared/Sing and SourceEvents.
// Count before forwarding, even on a background thread, so an async queue reply
// cannot resume/skip after a newer user pause, seek or skip.
%hook SPTEsperantoPlayer
- (id)pause:(id)options { SGRPlayerHistoryTransportCommand(); return %orig; }
- (id)resume:(id)options { SGRPlayerHistoryTransportCommand(); return %orig; }
- (id)stop { SGRPlayerHistoryTransportCommand(); return %orig; }
- (id)skipToNextTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    SGRPlayerHistoryTransportCommand(); return %orig;
}
- (id)skipToPreviousTrackWithOptions:(id)options track:(id)track loggingParams:(id)params {
    SGRPlayerHistoryTransportCommand(); return %orig;
}
- (id)seekTo:(double)position relative:(long long)relative options:(id)options creatorTimestampPositionMs:(double)creator {
    SGRPlayerHistoryTransportCommand(); return %orig;
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC14Queue_ViewImpl19QueueViewController"]);
}
