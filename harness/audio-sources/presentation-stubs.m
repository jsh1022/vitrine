// Only unrelated audio/network services and the settings row model are stood in.
// The tested row actions, presentation helper and SGPresentDark are production code;
// alerts, document pickers, windows and presentation transitions are real UIKit.
#import "Settings/SGModPage.h"
#import "Shared/AudioSources/SGAddons.h"
#import "Shared/AudioSources/SGWireGuard.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Player/SGLastTrack.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"

NSArray<SGModRow *> *SGPresentationRows;
@implementation SGModRow
@end
@implementation SGModSection
@end
@implementation SGPage
@end
@implementation SGModPage
- (instancetype)initWithTitle:(NSString *)title intro:(NSString *)intro sections:(NSArray<SGModSection *> *)sections footer:(NSString *)footer {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = title;
    if ([@[@"Lossless sources", @"WireGuard proxy"] containsObject:title]) {
        NSMutableArray *rows = [NSMutableArray array];
        for (SGModSection *section in sections) [rows addObjectsFromArray:section.rows];
        SGPresentationRows = rows;
    }
    return self;
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return 0; }
- (void)refreshVisibility {}
@end
SGModRow *SGOptionRow(NSString *title, NSString *subtitle, NSString *key) {
    SGModRow *row = [SGModRow new]; row.title = title; row.subtitle = subtitle; row.key = key; return row;
}
SGModRow *SGActionRow(NSString *title, NSString *subtitle, void (^action)(void)) {
    SGModRow *row = [SGModRow new]; row.title = title; row.subtitle = subtitle; row.action = action; return row;
}
SGModRow *SGStatRow(NSString *title, NSString *(^value)(void)) {
    SGModRow *row = [SGModRow new]; row.title = title; row.value = value; return row;
}
SGModRow *SGStatActionRow(NSString *title, NSString *subtitle, NSString *(^value)(void), void (^action)(void)) {
    SGModRow *row = SGActionRow(title, subtitle, action); row.value = value; return row;
}
SGModRow *SGPageRow(NSString *title, UIViewController *(^page)(void)) {
    SGModRow *row = [SGModRow new]; row.title = title; row.page = page; return row;
}
SGModSection *SGNotedSection(NSString *title, NSArray<SGModRow *> *rows, NSString *footer) {
    SGModSection *section = [SGModSection new]; section.title = title; section.rows = rows; section.footer = footer; return section;
}
SGModSection *SGSection(NSString *title, NSArray<SGModRow *> *rows) { return SGNotedSection(title, rows, nil); }
UIViewController *SGTopController(void) {
    UIWindow *window = [(id)UIApplication.sharedApplication.delegate window];
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}
NSArray<NSDictionary *> *SGAddonSources(void) { return @[]; }
BOOL SGAddonAddSource(NSString *input) { return NO; }
BOOL SGAddonRemoveSource(NSString *identifier) { return YES; }
void SGAddonTestSource(NSString *identifier, void (^completion)(NSString *)) { completion(@"Test result"); }
void SGAddonRetryCurrentTrack(void) {}
NSString *SGAddonStatus(void) { return @"Idle"; }
NSString *SGAddonStatusSummary(void) { return @"Idle"; }
SGAddonPreparationState SGPresentationPreparation;
SGAddonPreparationState SGAddonPreparation(void) { return SGPresentationPreparation; }
NSDictionary *SGPresentationPreparedInfo;
NSDictionary *SGAddonMediaInfo(void) { return SGPresentationPreparedInfo ?: @{}; }
BOOL SGWireGuardImport(NSString *text, NSString **reason) { return YES; }
BOOL SGWireGuardDelete(void) { return YES; }
BOOL SGWireGuardHasProfile(void) { return NO; }
NSDictionary *SGWireGuardStatus(void) { return @{@"state": @"꺼짐"}; }
static BOOL sg_appProxy;
BOOL SGWireGuardAppProxyActive(void) { return sg_appProxy; }
void SGWireGuardSetAppProxyActive(BOOL active) { sg_appProxy = active; }
BOOL SGWireGuardApplyToConfiguration(NSURLSessionConfiguration *config) { return NO; }
void SGWireGuardTestDNS(void (^completion)(NSString *)) { completion(@"Test result"); }
void SGWireGuardTestHTTPS(void (^completion)(NSString *)) { completion(@"Test result"); }
BOOL SGPresentationStaticCover;
UIImage *SGPresentationArtwork;
BOOL SGFlag(NSString *key, BOOL fallback) {
    return [key isEqualToString:SGKeyAppWireGuard] || ([key hasSuffix:@".staticCoverFallback"] && SGPresentationStaticCover);
}
void SGSetEnabled(NSString *key, BOOL on) {}
SPTPlayerState *SGPlayerState(void) { return nil; }
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) {}
NSString *SGURIString(id uri) { return nil; }
BOOL SGLosslessPlaying(void) { return NO; }
BOOL SGPresentationExternal;
NSDictionary *SGPresentationSourceInfo;
BOOL SGLosslessRendering(void) { return SGPresentationExternal; }
NSDictionary *SGLosslessSourceInfo(void) { return SGPresentationSourceInfo ?: @{}; }
BOOL SGPlayerMusicClientFormat(AudioStreamBasicDescription *format) {
    if (!SGPresentationExternal) return NO;
    *format = (AudioStreamBasicDescription){44100,kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved,4,1,4,2,32,0};
    return YES;
}
double SGPlayerSpeed(void) { return 1; }
float SGPlayerPitch(void) { return 0; }
float SGPlayerReverb(void) { return 0; }
NSDictionary *SGWiredOutputStatus(void) { return @{@"state": @"꺼짐", @"detail": @"Wired source output is off"}; }
void SGWiredOutputSettingsChanged(void) {}
BOOL SGSingOn(void) { return NO; }
BOOL SGRedesignedUI(void) { return getenv("SG_QUALITY_REDESIGNED") != NULL; }
BOOL SGNativeUI(void) { return !SGRedesignedUI(); }
void SGRequireClasses(NSArray<NSString *> *names) {
    for (NSString *name in names) NSCAssert(NSClassFromString(name), @"Fixture class missing: %@", name);
}
@implementation SGShownTrack
- (NSString *)uri { return @"spotify:track:background-fixture"; }
- (NSString *)title { return @"Fixture"; }
- (NSString *)artist { return @"Fixture"; }
- (NSString *)album { return @"Fixture"; }
- (NSURL *)artworkURL { return [NSURL URLWithString:@"https://example.invalid/artwork-fixture.jpg"]; }
- (NSURL *)canvasURL { return nil; }
- (BOOL)current { return SGPresentationArtwork != nil; }
@end
SGShownTrack *SGShownTrackNow(void) { return SGPresentationArtwork ? [SGShownTrack new] : nil; }
void SGShownTrackArtwork(SGShownTrack *track, void (^done)(UIImage *)) { done(SGPresentationArtwork); }
@implementation SGMotionFollower
- (instancetype)initWithBegin:(BOOL (^)(NSString *, SPTPlayerState *))begin found:(void (^)(NSString *, NSURL *))found { return [super init]; }
- (void)restart {}
@end
