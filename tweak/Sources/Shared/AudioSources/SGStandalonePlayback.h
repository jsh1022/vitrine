#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

// Shared behavior, enabled only for redesigned addon playback. Main-thread control;
// decoder cancellation and getter snapshots are safe from Spotify's other threads.
#define SGStandaloneFailedNotification @"spotifyglass.addons.standaloneFailed"
BOOL SGStandaloneEnabled(void);
BOOL SGStandaloneEligible(void);
BOOL SGStandaloneActive(void);
BOOL SGStandaloneBusy(NSString *uri);
BOOL SGStandaloneRecovering(NSString *uri);
BOOL SGStandaloneInternalCommand(void);
uint64_t SGStandaloneCommandEpoch(void);
void SGStandaloneSetHooksReady(BOOL ready);
// localPauseLease must come from the unchanged addon wait/prepared-next intent.
void SGStandaloneStart(NSString *path, NSString *uri, BOOL localPauseLease, void (^completion)(BOOL));
void SGStandaloneCancel(void);
void SGStandaloneRecover(NSString *reason);
BOOL SGStandalonePause(BOOL paused);
BOOL SGStandaloneSeek(double seconds, long long relative);
void SGStandaloneWillSkip(NSString *uri);
void SGStandaloneDidSkip(void);
BOOL SGStandaloneTakeStartIntent(NSString *uri);
void SGStandaloneObserveNativeState(id state);
NSDictionary *SGStandaloneClock(id state);
NSDictionary *SGStandaloneSourceInfo(void);
BOOL SGStandaloneRendering(void);
BOOL SGStandaloneOutputFormat(AudioStreamBasicDescription *format);

// Defined beside the verified Logos hooks; these bypass only our clock overlay.
BOOL SGStandaloneNativePaused(id state);
double SGStandaloneNativePosition(id state);
void SGStandalonePublish(void);
