#import <UIKit/UIKit.h>
#import "Settings/SGModPage.h"
#import "Shared/AudioSources/SGAddons.h"
#import "Shared/AudioSources/SGAudioPresentation.h"
#import "Shared/AudioSources/SGWireGuard.h"
#import "Shared/AudioSources/SGPlaybackQuality.h"
#import "Core/SGViewTree.h"

extern NSArray<SGModRow *> *SGPresentationRows;
extern BOOL SGPresentationExternal;
extern NSDictionary *SGPresentationSourceInfo, *SGPresentationPreparedInfo;

// Same runtime class name and accessibility identifiers as the verified duration unit.
// The production hooks, UIButton hit target and popover run against real UIKit views.
@interface _TtC20NowPlaying_ModesImpl19DurationElementUnit : UIViewController
@end
@implementation _TtC20NowPlaying_ModesImpl19DurationElementUnit {
    UISlider *_slider;
    UILabel *_elapsed, *_remaining;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    _slider = [UISlider new];
    _elapsed = [UILabel new]; _remaining = [UILabel new];
    _elapsed.text = @"0:26"; _remaining.text = @"-2:25";
    _elapsed.accessibilityIdentifier = @"now-playing-time-take-label-internal";
    _remaining.accessibilityIdentifier = @"now-playing-time-remaning-label-internal";
    [self.view addSubview:_slider]; [self.view addSubview:_elapsed]; [self.view addSubview:_remaining];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    _slider.frame = CGRectMake(20, 10, width - 40, 22);
    _elapsed.frame = CGRectMake(20, 38, 44, 16);
    _remaining.frame = CGRectMake(width - 64, 38, 44, 16);
}
@end
static UIView *identified(UIView *root, NSString *identifier) {
    __block UIView *found;
    SGForEachView(root, ^(UIView *view) { if ([view.accessibilityIdentifier isEqualToString:identifier]) found = view; });
    return found;
}
static void fail(NSString *reason) {
    fprintf(stderr, "FAIL audio source presentations: %s\n", reason.UTF8String);
    fflush(stderr); exit(1);
}
static void progress(NSString *stage) {
    fprintf(stderr, "CHECK audio source presentations: %s\n", stage.UTF8String);
    fflush(stderr);
}
static void uncaught(NSException *exception) {
    fail([NSString stringWithFormat:@"uncaught %@: %@\n%@", exception.name, exception.reason, exception.callStackSymbols]);
}
@interface SGUnrelatedProtocol : NSURLProtocol
@end
@implementation SGUnrelatedProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return NO; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
@end
static void checkBlockedTransport(void) {
    progress(@"checking URLSession hooks and unavailable-engine blocking");
    NSDictionary *pipeline = SGAudioPipelineSnapshot();
    NSArray *stages = pipeline[@"stages"];
    if (stages.count != 5 || ![stages[0][@"title"] isEqual:@"Track Info"] || ![stages[4][@"title"] isEqual:@"Output Device"] ||
        ![pipeline[@"statsLine"] isEqual:@"No decoder measurement for the selected source"]) {
        fail(@"pipeline must contain five stages without inventing unknown source measurements"); return;
    }
    if (!SGWireGuardAppProxyActive()) { fail(@"proxy hooks not installed"); return; }
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPAdditionalHeaders = @{@"X-Fixture": @"preserved"};
    config.protocolClasses = [config.protocolClasses arrayByAddingObject:SGUnrelatedProtocol.class];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:nil];
    Class blocked = NSClassFromString(@"SGWireGuardBlockedProtocol");
    if (![session.configuration.protocolClasses containsObject:blocked] ||
        ![session.configuration.protocolClasses containsObject:SGUnrelatedProtocol.class] ||
        ![session.configuration.HTTPAdditionalHeaders[@"X-Fixture"] isEqualToString:@"preserved"] ||
        ![NSURLSession.sharedSession.configuration.protocolClasses containsObject:blocked] ||
        ![SGWireGuardProxyCounters()[@"blockedConfigurations"] unsignedLongLongValue]) {
        fail(@"session, shared-session or configuration preservation check failed"); return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://example.invalid/no-direct-connection"]];
    request.assumesHTTP3Capable = YES;
    if (request.assumesHTTP3Capable) { fail(@"HTTP/3 was not disabled"); return; }
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (![error.domain isEqualToString:NSURLErrorDomain] || error.code != NSURLErrorNotConnectedToInternet) {
            fail(@"missing tunnel was not blocked before a network connection"); return;
        }
        [session finishTasksAndInvalidate];
        printf("PASS audio source presentations: add source, import picker, result alert, playback details, main-thread dispatch\n");
        printf("PASS unavailable WireGuard: session factories, shared session, preserved config, HTTP/3 disabled, HTTP request blocked\n");
        fflush(stdout); exit(0);
    }] resume];
}
static void waitFor(BOOL (^predicate)(void), void (^done)(void), NSUInteger tries) {
    if (predicate()) { done(); return; }
    if (!tries) { fail(@"expected controller did not become visibly presented"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ waitFor(predicate, done, tries - 1); });
}
@interface SGPresentationApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UINavigationController *nav;
- (void)step:(NSUInteger)index;
@end
@implementation SGPresentationApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    progress(@"didFinishLaunching");
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.nav = [[UINavigationController alloc] initWithRootViewController:SGAudioSourcesPage()];
    self.window.rootViewController = self.nav;
    [self.window makeKeyAndVisible];
    waitFor(^BOOL { return self.nav.view.window != nil; }, ^{ [self step:0]; }, 200);
    return YES;
}
- (void)step:(NSUInteger)index {
    progress([NSString stringWithFormat:@"step %lu", (unsigned long)index]);
    if (index == 7) {
        checkBlockedTransport(); return;
    }
    if (index == 6) {
        // Also prove the helper accepts a request arriving from a worker thread.
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Worker request" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ SGShowAudioController(alert); });
    } else if (index == 5) {
        UIButton *details = (UIButton *)identified(self.nav.presentedViewController.view, @"vitrine.audio-quality.details");
        if (!details) { fail(@"quality popover details action missing"); return; }
        [details sendActionsForControlEvents:UIControlEventTouchUpInside];
    } else if (index == 4) {
        SGPresentationPreparedInfo = @{@"sourceName": @"Fixture", @"declared": @{@"sampleRate": @96000, @"bitDepth": @24}};
        if (![SGPlaybackQualityInfo()[@"label"] isEqualToString:@"Spotify"] ||
            ![SGPlaybackQualityInfo()[@"sourceRate"] isEqualToString:@"확인 불가"]) {
            fail(@"prepared provider metadata must not create a lossless badge"); return;
        }
        SGPresentationExternal = YES;
        SGPresentationSourceInfo = @{@"rate": @48000, @"bits": @24, @"codec": @"FLAC", @"channels": @2};
        if (![SGPlaybackQualityInfo()[@"sourceRate"] isEqualToString:@"48 kHz"] ||
            ![SGPlaybackQualityInfo()[@"label"] isEqualToString:@"무손실"]) {
            fail(@"quality badge must use decoder measurement instead of the 96 kHz provider claim"); return;
        }
        UIViewController *unit = [_TtC20NowPlaying_ModesImpl19DurationElementUnit new];
        [self.nav pushViewController:unit animated:NO];
        [unit.view setNeedsLayout]; [unit.view layoutIfNeeded];
        waitFor(^BOOL { return identified(unit.view, @"vitrine.playback-quality").window != nil; }, ^{
            UIButton *badge = (UIButton *)identified(unit.view, @"vitrine.playback-quality");
            UIView *elapsed = identified(unit.view, @"now-playing-time-take-label-internal");
            UIView *remaining = identified(unit.view, @"now-playing-time-remaning-label-internal");
            if (badge.hidden || ![badge.currentTitle isEqualToString:@"무손실"] ||
                CGRectIntersectsRect(badge.frame, elapsed.frame) || CGRectIntersectsRect(badge.frame, remaining.frame)) {
                fail(@"quality badge hidden, incorrect, or overlapping timestamps"); return;
            }
            [badge sendActionsForControlEvents:UIControlEventTouchUpInside];
        }, 200);
    } else if (index == 3) {
        SGShowPlaybackDetails();
    } else {
        // Do not replace the navigation stack during the previous modal's dismissal.
        // The WireGuard page only supplies the actual action rows for these two steps.
        if (index == 1) (void)SGWireGuardSettingsPage();
        NSString *title = @[@"Add source", @"Import .conf file", @"Delete saved profile"][index];
        SGModRow *found = nil;
        for (SGModRow *row in SGPresentationRows) if ([row.title isEqualToString:title]) found = row;
        if (!found.action) { fail(@"missing production row action"); return; }
        found.action();
    }
    waitFor(^BOOL {
        UIViewController *shown = self.nav.presentedViewController;
        if (!shown.viewIfLoaded.window || shown.isBeingPresented || shown.isBeingDismissed || shown.transitionCoordinator) return NO;
        // A just-dismissed controller can remain attached until the next run-loop turn.
        // Wait for this step's expected controller, not the previous step's modal.
        if (index == 0) return [shown isKindOfClass:UIAlertController.class] && [shown.title isEqualToString:@"Add lossless source"];
        if (index == 1) return [shown isKindOfClass:UIDocumentPickerViewController.class];
        if (index == 2) return [shown isKindOfClass:UIAlertController.class] && [shown.title isEqualToString:@"WireGuard"];
        if (index == 3) return [shown isKindOfClass:UINavigationController.class] && [((UINavigationController *)shown).topViewController.title isEqualToString:@"Playback details"];
        if (index == 4) return [shown.view.accessibilityIdentifier isEqualToString:@"vitrine.audio-quality.popover"];
        if (index == 5) return [shown isKindOfClass:UINavigationController.class] && [((UINavigationController *)shown).topViewController.title isEqualToString:@"Playback details"];
        return [shown isKindOfClass:UIAlertController.class] && [shown.title isEqualToString:@"Worker request"];
    }, ^{
        UIViewController *shown = self.nav.presentedViewController;
        if (shown.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) fail(@"missing dark style");
        if (index == 0 && (![shown isKindOfClass:UIAlertController.class] || ![shown.title isEqualToString:@"Add lossless source"] || [(UIAlertController *)shown textFields].count != 1)) fail(@"add-source editor missing");
        if (index == 1 && ![shown isKindOfClass:UIDocumentPickerViewController.class]) fail(@"document picker missing");
        if (index == 2 && (![shown isKindOfClass:UIAlertController.class] || ![shown.title isEqualToString:@"WireGuard"])) fail(@"result message missing");
        if (index == 3 && (![shown isKindOfClass:UINavigationController.class] || ![((UINavigationController *)shown).topViewController.title isEqualToString:@"Playback details"])) fail(@"playback details missing");
        if (index == 4) { [self step:5]; return; }
        if (index == 5) {
            SGPresentationExternal = NO; SGPresentationSourceInfo = nil; SGPresentationPreparedInfo = nil;
            printf("PASS playback quality badge and popover\n"); fflush(stdout);
        }
        // Queue the next production action while this controller is dismissing.
        // Its presentation must wait for the real UIKit transition to complete.
        if (index == 1) {
            UIDocumentPickerViewController *picker = (id)shown;
            [picker.delegate documentPickerWasCancelled:picker];
        }
        [shown dismissViewControllerAnimated:YES completion:nil];
        [self step:index + 1];
    }, 200);
}
@end
int main(int argc, char **argv) { @autoreleasepool {
    NSSetUncaughtExceptionHandler(uncaught);
    progress(@"entered main");
    return UIApplicationMain(argc, argv, nil, @"SGPresentationApp");
} }
