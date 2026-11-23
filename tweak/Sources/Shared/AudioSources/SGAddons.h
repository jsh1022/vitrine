#import <UIKit/UIKit.h>
#define SGKeyAddons @"spotifyglass.sources.addons"
#define SGKeyAddonCellular @"spotifyglass.sources.cellular"
#define SGKeyAddonPlaybackMode @"spotifyglass.redesign.sources.playbackMode"
#define SGKeyAddonAutoSwitch @"spotifyglass.redesign.sources.autoSwitch"
#define SGKeyAddonPrefetchCellular @"spotifyglass.redesign.sources.prefetchCellular"
#define SGKeyAddonPrefetchEnabled @"spotifyglass.redesign.sources.prefetchEnabled"
#define SGKeyAddonWaitSeconds @"spotifyglass.redesign.sources.waitSeconds"
typedef NS_ENUM(NSInteger, SGAddonPlaybackStrategy) {
    SGAddonPlaybackFast, SGAddonPlaybackContinuous, SGAddonPlaybackPrefer,
};
enum { SGAddonPrefetchMaxTracks = 3 };
SGAddonPlaybackStrategy SGAddonPlaybackMode(void);
BOOL SGAddonAllowsCurrentLookup(void);
// Main thread. The entries contain uri/title/artist/duration, never provider credentials.
void SGAddonUpdateUpcoming(NSArray<NSDictionary *> *tracks);
void SGAddonBeginPlaybackWait(NSString *uri);
void SGAddonFinishPlaybackWait(void);

// Main thread. URLs and profile text live only in Keychain.
NSArray<NSDictionary *> *SGAddonSources(void);
NSArray<NSDictionary *> *SGAddonEnabledSources(void);
BOOL SGAddonSetSourceEnabled(NSString *identifier, BOOL enabled);
BOOL SGAddonMoveSource(NSString *identifier, NSUInteger index);
void SGAddonRefreshSourceInfo(NSString *identifier, void (^completion)(NSString *error));
UIViewController *SGAddonSourcesPage(void);
BOOL SGAddonAddSource(NSString *input);
BOOL SGAddonRemoveSource(NSString *identifier);
void SGAddonTestSource(NSString *identifier, void (^completion)(NSString *status));
void SGAddonCancel(void);
// Main: preserve only the new current track's active prefetch; otherwise cancel.
void SGAddonTrackChanged(NSString *uri);
// Any thread: bounded skip handoff until a state report identifies the target.
void SGAddonWillChangeTrack(void);
// Any thread. Revoke in-flight I/O before a skip/stop is reported on main.
void SGAddonInvalidateRequests(void);
void SGAddonRetryCurrentTrack(void);
#define SGAddonRetryNotification @"spotifyglass.addons.retry"
#define SGAddonDownloadFinishedNotification @"spotifyglass.addons.downloadFinished"
void SGAddonPrepare(NSString *uri, NSString *title, NSString *artist, double duration,
                    void (^completion)(NSString *path));
NSString *SGAddonStatus(void);
NSString *SGAddonStatusSummary(void);
typedef NS_ENUM(NSInteger, SGAddonPreparationState) {
    SGAddonPreparationIdle, SGAddonPreparationSearching, SGAddonPreparationAligning,
    SGAddonPreparationAligned, SGAddonPreparationUnavailable,
    SGAddonPreparationDownloading, SGAddonPreparationDecoding,
};
SGAddonPreparationState SGAddonPreparation(void);
void SGAddonSetPlaybackUnavailable(void);
void SGAddonSetPlaybackStatus(NSString *status, BOOL aligned);
// Main-thread presentation only; does not change playback or network policy.
void SGAddonSetPreparationStage(SGAddonPreparationState stage, NSString *status);
NSDictionary *SGAddonMediaInfo(void);
NSDictionary *SGMeasureLosslessFile(NSString *path, double duration);
UIViewController *SGAudioSourcesPage(void);
UIViewController *SGWireGuardSettingsPage(void);
UIViewController *SGPlaybackDetailsPage(void);
void SGShowPlaybackDetails(void);
NSDictionary *SGAudioPipelineSnapshot(void);
