#import <Foundation/Foundation.h>
#import "Shared/AudioSources/SGAddons.h"
#import "Shared/AudioSources/SGAddonDiagnostics.h"
#import "Shared/AudioSources/SGSourceSecrets.h"
#import "Shared/AudioSources/SGProgressiveFLAC.h"
#import "Shared/AudioSources/SGWireGuard.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/Lossless/SGWiredOutput.h"
#import "Shared/Lossless/SGSegmentedDecode.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Core/SGCore.h"
#import "Core/SGPrefs.h"

static NSMutableDictionary<NSString *, id> *prefs;
static NSMutableDictionary<NSString *, NSString *> *secrets;
static NSUInteger saveCount, retryCount, settingsCount, lookupCount, discardCount;
static NSString *lastSettingsKey;
static NSUInteger outputChanges;

static void require(BOOL value, NSString *message) {
    NSLog(@"%@ %@", value ? @"PASS:" : @"FAIL:", message);
    if (!value) exit(1);
}
static NSArray *sources(void) { return [NSJSONSerialization JSONObjectWithData:[secrets[@"addons"] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] ?: @[]; }
static NSDictionary *sourceAt(NSUInteger index) { return sources()[index]; }

BOOL SGFlag(NSString *key, BOOL fallback) { id value=prefs[key]; return value ? [value boolValue] : fallback; }
NSInteger SGInt(NSString *key, NSInteger fallback) { id value=prefs[key]; return value ? [value integerValue] : fallback; }
BOOL SGRedesignedUI(void) { return YES; }
NSString *SGSourceSecret(NSString *key) { return secrets[key]; }
BOOL SGSaveSourceSecret(NSString *key, NSString *value) { saveCount++; secrets[key]=value; return YES; }
void SGAddonDiagnostic(NSString *sourceID, NSString *stage, NSString *event, NSDictionary *details) { (void)sourceID; (void)stage; (void)event; (void)details; }
void SGAddonDiagnosticsBindFile(NSString *path, NSString *sourceID) { (void)path; (void)sourceID; }
void SGAddonDiagnosticsNameSource(NSString *sourceID, NSString *name) { (void)sourceID; (void)name; }
NSString *SGAddonDiagnosticsSourceName(NSString *sourceID) { (void)sourceID; return nil; }
NSString *SGAddonDiagnosticSourceForFile(NSString *path) { (void)path; return nil; }
NSString *SGAddonDiagnosticsSafeText(NSString *text) { return text ?: @""; }
NSString *SGAddonDiagnosticsSafeSourceID(NSString *sourceID) { return sourceID ?: @""; }
#ifndef SG_REAL_PROGRESSIVE_FLAC
BOOL SGProgressiveFLACRegistered(NSString *path) { (void)path; return NO; }
void SGProgressiveFLACForgetAll(void) {}
@implementation SGProgressiveFLAC
- (instancetype)initWithPath:(NSString *)path cancelled:(BOOL (^)(void))cancelled { (void)path; (void)cancelled; return [super init]; }
- (void)publishBytes:(uint64_t)bytes total:(uint64_t)total { (void)bytes; (void)total; }
- (void)finish:(BOOL)success { (void)success; }
- (NSDictionary *)probeDuration:(double)expected { (void)expected; return nil; }
@end
#endif
BOOL SGLosslessRendering(void) { return NO; }
void SGLosslessPrepareNext(NSString *path, double rate) { (void)path; (void)rate; }
void SGAddonFinishPlaybackWait(void) {}
BOOL SGDecodeSegmentedLossless(NSString *input, NSString *output, BOOL (^cancelled)(void)) { (void)input; (void)output; (void)cancelled; return NO; }
void SGWiredOutputSettingsChanged(void) { ++outputChanges; }
void SGLosslessStop(BOOL immediate) { (void)immediate; }
void SGPlayerInvalidateSource(void) {}
BOOL SGPlayerMusicClientFormat(AudioStreamBasicDescription *format) { (void)format; return NO; }
static NSURLSessionConfiguration *fixtureSessionConfiguration;
NSURLSessionConfiguration *SGSourceSessionConfiguration(NSString **reason) { if(reason)*reason=nil; return fixtureSessionConfiguration; }
SPTPlayerState *SGPlayerState(void) { return nil; }
NSString *SGURIString(id uri) { (void)uri; return nil; }

static void retryNotification(NSNotification *note) { (void)note; retryCount++; }
static void settingsNotification(NSNotification *note) { settingsCount++; lastSettingsKey=note.userInfo[@"key"]; }
static void resetSignals(void) { retryCount=settingsCount=lookupCount=discardCount=0; lastSettingsKey=nil; }

int main(void) { @autoreleasepool {
    prefs=[@{SGKeyAddons:@YES, SGKeyAddonCellular:@NO, SGKeyAddonPlaybackMode:@(SGAddonPlaybackContinuous),
        SGKeyAddonAutoSwitch:@YES, SGKeyAddonPrefetchEnabled:@YES, SGKeyAddonPrefetchCellular:@NO,
        SGKeyAddonWaitSeconds:@10, SGKeySourceWireGuard:@NO} mutableCopy];
    secrets=[@{@"addons":@"[{\"id\":\"one\",\"url\":\"https://one.example\",\"enabled\":true},{\"id\":\"two\",\"url\":\"https://two.example\",\"enabled\":true}]"} mutableCopy];
    [NSNotificationCenter.defaultCenter addObserverForName:SGAddonRetryNotification object:nil queue:nil usingBlock:^(NSNotification *n){ retryNotification(n); }];
    [NSNotificationCenter.defaultCenter addObserverForName:SGAddonSettingsNotification object:nil queue:nil usingBlock:^(NSNotification *n){ settingsNotification(n); }];
    NSMutableArray *legacy=[NSJSONSerialization JSONObjectWithData:[secrets[@"addons"] dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:nil];
    [legacy addObject:@{@"id":@"legacy-amazon",@"builtin":@"amazon",@"enabled":@YES}];
    secrets[@"addons"]=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:legacy options:0 error:nil] encoding:NSUTF8StringEncoding];
    secrets[@"hosted-lossless.amazon"]=@"legacy-auth";
    require(SGAddonSources().count==2 && sources().count==2 && secrets[@"hosted-lossless.amazon"]==nil, @"legacy Amazon registration and credentials removed without changing other sources");
    SGAddonSettingsChanged(nil); // Baseline current values before checking deltas.
    SGAddonSetPlaybackStatus(@"playing", YES);
    resetSignals();

    require(SGAddonMoveSource(@"two",0), @"source reorder succeeds");
    require([sourceAt(0)[@"id"] isEqual:@"two"] && retryCount==0, @"reorder persists without retrying the current track");
    NSUInteger before=saveCount;
    require(SGAddonMoveSource(@"two",0) && retryCount==0 && saveCount==before, @"same-position reorder is a no-op with no Keychain write");
    require(SGAddonAddSource(@"https://three.example/api"), @"source add succeeds");
    require(sources().count==3 && retryCount==0, @"adding a source preserves current playback and does not retry");
    NSString *addedID=sourceAt(2)[@"id"];
    before=saveCount;
    require(SGAddonSetSourceEnabled(addedID,YES) && saveCount==before, @"setting an already-enabled source does not write Keychain");
    require(retryCount==0, @"same-value enable is silent");
    require(SGAddonSetSourceEnabled(addedID,NO), @"disabling a source succeeds");
    require(retryCount==0 && [SGAddonStatus() isEqual:@"playing"], @"disable affects only the selected source and keeps playback status");
    require(SGAddonRemoveSource(addedID), @"removing a source succeeds");
    require(retryCount==0 && [SGAddonStatus() isEqual:@"playing"], @"remove keeps the current track and emits no retry");
    before=saveCount;
    require(SGAddonRemoveSource(addedID) && retryCount==0 && saveCount==before, @"removing an absent source is a no-op with no Keychain write");

    // Baseline is nil above. Same-value policy calls must not publish notifications.
    resetSignals();
    SGAddonSettingsChanged(SGKeyAddonWaitSeconds);
    SGAddonSettingsChanged(SGKeyAddonPrefetchEnabled);
    require(settingsCount==0 && retryCount==0, @"same-valued wait and prefetch policies emit no notifications");

    prefs[SGKeyAddonWaitSeconds]=@12; SGAddonSettingsChanged(SGKeyAddonWaitSeconds);
    require(settingsCount==1 && retryCount==0 && [lastSettingsKey isEqual:SGKeyAddonWaitSeconds], @"changed wait policy notifies without retrying");
    prefs[SGKeyAddonPrefetchEnabled]=@NO; SGAddonSettingsChanged(SGKeyAddonPrefetchEnabled);
    require(settingsCount==2 && retryCount==0 && [lastSettingsKey isEqual:SGKeyAddonPrefetchEnabled], @"changed prefetch policy notifies without retrying");
    prefs[SGKeyAddonAutoSwitch]=@NO; SGAddonSettingsChanged(SGKeyAddonAutoSwitch);
    require(settingsCount==3 && retryCount==0, @"changed auto-switch policy notifies without retrying");
    prefs[SGKeyAddonPlaybackMode]=@(SGAddonPlaybackFast); SGAddonSettingsChanged(SGKeyAddonPlaybackMode);
    require(settingsCount==4 && retryCount==0, @"changed playback mode notifies without retrying");

    prefs[SGKeySourceWireGuard]=@YES; SGAddonSettingsChanged(SGKeySourceWireGuard);
    require(settingsCount==5 && retryCount==0, @"transport change revokes policy without requesting a track retry");
    prefs[SGKeyAddons]=@NO; SGAddonSettingsChanged(SGKeyAddons);
    require(settingsCount==6 && retryCount==0, @"global off revokes in-flight work without retry notification");
    resetSignals();
    SGAddonSettingsChanged(SGKeyAddons);
    require(settingsCount==0 && retryCount==0, @"repeating the same global-off value is silent");

    prefs[SGKeyWiredSourceOutput]=@YES; SGAddonSettingsChanged(SGKeyWiredSourceOutput);
    require(outputChanges==1 && retryCount==0,@"wired output changes request only output preparation, not a source retry");
    SGAddonSettingsChanged(SGKeyWiredSourceOutput);
    require(outputChanges==1 && retryCount==0,@"same wired value does not reconfigure output");

    require(!SGAddonAddHostedSource(@"unknown") && SGAddonAddHostedSource(@"qobuz"),@"only supported built-in sources can be registered");
    require(sources().count==3 && [sourceAt(2)[@"enabled"] isEqual:@NO] && retryCount==0,@"built-in source is opt-in and registration preserves playback");
    before=saveCount;
    require(SGAddonAddHostedSource(@"qobuz") && saveCount==before,@"re-adding a built-in source is a no-op");
    require(!SGAddonSetSourceEnabled(@"builtin-qobuz",YES),@"unverified built-in source cannot be enabled");
    secrets[@"hosted-lossless.qobuz"]=@"{\"session_id\":\"test-session\",\"session_secret\":\"test-secret\",\"expires_at\":\"2099-01-01T00:00:00Z\"}";
    require(SGAddonSetSourceEnabled(@"builtin-qobuz",YES) && retryCount==0,@"verified built-in source enables without restarting playback");
    require(SGAddonRemoveSource(@"builtin-qobuz") && [secrets[@"hosted-lossless.qobuz"] rangeOfString:@"session_secret"].location==NSNotFound,@"removing built-in source clears its credentials");

    SGAddonSetPlaybackStatus(@"playing",YES);
    prefs[SGKeyAddonParallelQuality]=@YES;
    SGAddonSettingsChanged(SGKeyAddonParallelQuality);
    require(retryCount==0 && [SGAddonStatus() isEqual:@"playing"],@"quality comparison switch keeps current playback and never forces a retry");
    SGAddonRetryCurrentTrack();
    require(retryCount==1, @"explicit retry still emits the retry notification");
    prefs[SGKeyAddons]=@YES;
    secrets[@"addons"]=@"[{\"id\":\"q1\",\"builtin\":\"qobuz\",\"enabled\":true},{\"id\":\"q2\",\"builtin\":\"qobuz\",\"enabled\":true},{\"id\":\"t1\",\"builtin\":\"tidal\",\"enabled\":false},{\"id\":\"d1\",\"builtin\":\"deezer\",\"enabled\":true},{\"id\":\"external\",\"name\":\"hidden-private-name\",\"expiresAt\":1,\"enabled\":true}]";
    secrets[@"hosted-lossless.qobuz"]=@"{\"session_id\":\"old\",\"session_secret\":\"old-secret\",\"expires_at\":\"2000-01-01T00:00:00Z\"}";
    secrets[@"hosted-lossless.tidal"]=secrets[@"hosted-lossless.qobuz"];
    require([SGAddonExpiredSourceNames() isEqual:@[@"Qobuz"]],@"only confirmed expired enabled built-ins appear, without duplicate names or external URLs");
    secrets[@"hosted-lossless.qobuz"]=@"{\"authentication_expired\":true}";
    require([SGAddonExpiredSourceNames() isEqual:@[@"Qobuz"]],@"server invalidation remains visible after credentials are revoked");
    prefs[SGKeyAddons]=@NO;
    require(SGAddonExpiredSourceNames().count==0,@"disabled addon feature does not interrupt app launch");
    NSLog(@"RESULT addon settings policy passed");
    return 0;
} }
