#import <UIKit/UIKit.h>
#define SGKeyAddons @"spotifyglass.sources.addons"
#define SGKeyAddonCellular @"spotifyglass.sources.cellular"

// Main thread. URLs and profile text live only in Keychain.
NSArray<NSDictionary *> *SGAddonSources(void);
BOOL SGAddonAddSource(NSString *input);
BOOL SGAddonRemoveSource(NSString *identifier);
void SGAddonTestSource(NSString *identifier, void (^completion)(NSString *status));
void SGAddonCancel(void);
void SGAddonRetryCurrentTrack(void);
#define SGAddonRetryNotification @"spotifyglass.addons.retry"
void SGAddonPrepare(NSString *uri, NSString *title, NSString *artist, double duration,
                    void (^completion)(NSString *path));
NSString *SGAddonStatus(void);
NSString *SGAddonStatusSummary(void);
typedef NS_ENUM(NSInteger, SGAddonPreparationState) {
    SGAddonPreparationIdle, SGAddonPreparationSearching, SGAddonPreparationAligning,
    SGAddonPreparationAligned, SGAddonPreparationUnavailable,
};
SGAddonPreparationState SGAddonPreparation(void);
void SGAddonSetPlaybackUnavailable(void);
void SGAddonSetPlaybackStatus(NSString *status, BOOL aligned);
NSDictionary *SGAddonMediaInfo(void);
NSDictionary *SGMeasureLosslessFile(NSString *path, double duration);
UIViewController *SGAudioSourcesPage(void);
UIViewController *SGWireGuardSettingsPage(void);
UIViewController *SGPlaybackDetailsPage(void);
void SGShowPlaybackDetails(void);
NSDictionary *SGAudioPipelineSnapshot(void);
