// Only unrelated audio/network services and the settings row model are stood in.
// The tested row actions, presentation helper and SGPresentDark are production code;
// alerts, document pickers, windows and presentation transitions are real UIKit.
#import "Settings/SGModPage.h"
#import "Shared/AudioSources/SGAddons.h"
#import "Shared/AudioSources/SGWireGuard.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"

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
NSDictionary *SGAddonMediaInfo(void) { return @{}; }
BOOL SGWireGuardImport(NSString *text, NSString **reason) { return YES; }
BOOL SGWireGuardDelete(void) { return YES; }
BOOL SGWireGuardHasProfile(void) { return NO; }
NSDictionary *SGWireGuardStatus(void) { return @{@"state": @"Off"}; }
static BOOL sg_appProxy;
BOOL SGWireGuardAppProxyActive(void) { return sg_appProxy; }
void SGWireGuardSetAppProxyActive(BOOL active) { sg_appProxy = active; }
BOOL SGWireGuardApplyToConfiguration(NSURLSessionConfiguration *config) { return NO; }
void SGWireGuardTestDNS(void (^completion)(NSString *)) { completion(@"Test result"); }
void SGWireGuardTestHTTPS(void (^completion)(NSString *)) { completion(@"Test result"); }
BOOL SGFlag(NSString *key, BOOL fallback) { return [key isEqualToString:SGKeyAppWireGuard]; }
void SGSetEnabled(NSString *key, BOOL on) {}
SPTPlayerState *SGPlayerState(void) { return nil; }
NSString *SGURIString(id uri) { return nil; }
BOOL SGLosslessPlaying(void) { return NO; }
BOOL SGLosslessRendering(void) { return NO; }
NSDictionary *SGLosslessSourceInfo(void) { return @{}; }
BOOL SGPlayerMusicClientFormat(AudioStreamBasicDescription *format) { return NO; }
double SGPlayerSpeed(void) { return 1; }
float SGPlayerPitch(void) { return 0; }
float SGPlayerReverb(void) { return 0; }
NSDictionary *SGWiredOutputStatus(void) { return @{@"state": @"Off", @"detail": @"Wired source output is off"}; }
void SGWiredOutputSettingsChanged(void) {}
BOOL SGSingOn(void) { return NO; }
