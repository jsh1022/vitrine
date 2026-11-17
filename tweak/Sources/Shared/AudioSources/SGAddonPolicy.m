#import "SGAddons.h"
#import "Core/SGCore.h"

SGAddonPlaybackStrategy SGAddonPlaybackMode(void) {
    // Native retains the previously shipped immediate lookup and safe handoff.
    if (!SGRedesignedUI()) return SGAddonPlaybackContinuous;
    NSInteger mode = SGInt(SGKeyAddonPlaybackMode, SGAddonPlaybackContinuous);
    return mode >= SGAddonPlaybackFast && mode <= SGAddonPlaybackPrefer ? mode : SGAddonPlaybackContinuous;
}
BOOL SGAddonAllowsCurrentLookup(void) {
    SGAddonPlaybackStrategy mode = SGAddonPlaybackMode();
    return mode != SGAddonPlaybackFast && (mode != SGAddonPlaybackContinuous || !SGRedesignedUI() || SGFlag(SGKeyAddonAutoSwitch, YES));
}
