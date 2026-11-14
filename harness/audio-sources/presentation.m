#import <UIKit/UIKit.h>
#import "Settings/SGModPage.h"
#import "Shared/AudioSources/SGAddons.h"
#import "Shared/AudioSources/SGAudioPresentation.h"
#import "Shared/AudioSources/SGWireGuard.h"

extern NSArray<SGModRow *> *SGPresentationRows;
static void fail(NSString *reason) {
    fprintf(stderr, "FAIL audio source presentations: %s\n", reason.UTF8String);
    fflush(stderr); exit(1);
}
@interface SGUnrelatedProtocol : NSURLProtocol
@end
@implementation SGUnrelatedProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return NO; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
@end
static void checkBlockedTransport(void) {
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
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.nav = [[UINavigationController alloc] initWithRootViewController:SGAudioSourcesPage()];
    self.window.rootViewController = self.nav;
    [self.window makeKeyAndVisible];
    waitFor(^BOOL { return self.nav.view.window != nil; }, ^{ [self step:0]; }, 200);
    return YES;
}
- (void)step:(NSUInteger)index {
    if (index == 5) {
        checkBlockedTransport(); return;
    }
    if (index == 4) {
        // Also prove the helper accepts a request arriving from a worker thread.
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Worker request" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ SGShowAudioController(alert); });
    } else if (index == 3) {
        SGShowPlaybackDetails();
    } else {
        if (index == 1) [self.nav setViewControllers:@[SGWireGuardSettingsPage()] animated:NO];
        NSString *title = @[@"Add source", @"Import .conf file", @"Delete saved profile"][index];
        SGModRow *found = nil;
        for (SGModRow *row in SGPresentationRows) if ([row.title isEqualToString:title]) found = row;
        if (!found.action) { fail(@"missing production row action"); return; }
        found.action();
    }
    waitFor(^BOOL {
        UIViewController *shown = self.nav.presentedViewController;
        return shown.viewIfLoaded.window && !shown.isBeingPresented && !shown.isBeingDismissed && !shown.transitionCoordinator;
    }, ^{
        UIViewController *shown = self.nav.presentedViewController;
        if (shown.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) fail(@"missing dark style");
        if (index == 0 && (![shown isKindOfClass:UIAlertController.class] || ![shown.title isEqualToString:@"Add lossless source"] || [(UIAlertController *)shown textFields].count != 1)) fail(@"add-source editor missing");
        if (index == 1 && ![shown isKindOfClass:UIDocumentPickerViewController.class]) fail(@"document picker missing");
        if (index == 2 && (![shown isKindOfClass:UIAlertController.class] || ![shown.title isEqualToString:@"WireGuard"])) fail(@"result message missing");
        if (index == 3 && (![shown isKindOfClass:UINavigationController.class] || ![((UINavigationController *)shown).topViewController.title isEqualToString:@"Playback details"])) fail(@"playback details missing");
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
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"SGPresentationApp"); } }
