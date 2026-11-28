#import "SGAddons.h"
#import "SGAudioPresentation.h"
#import "Core/SGGlass.h"
#import "Settings/SGPageStyle.h"
#import <UIKit/UIKit.h>

@interface SGAddonExpiryNavigationController : UINavigationController
- (void)closeExpirySources;
@end
@implementation SGAddonExpiryNavigationController
- (void)closeExpirySources { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

static BOOL SGAddonExpiryNoticePending;
static BOOL SGAddonExpiryNoticeHandledActivation;
static NSUInteger SGAddonExpiryGeneration;
static __weak UIAlertController *SGAddonExpiryAlert;
static __weak UIViewController *SGAddonExpiryStableOwner;
static __weak UIWindow *SGAddonExpiryStableWindow;
static CFAbsoluteTime SGAddonExpiryStableSince;
static void SGAddonExpiryActivation(void);
static void SGAddonExpiryTryPresent(NSUInteger attempt, NSUInteger generation);

static void SGAddonExpiryChosen(void) {
    SGAddonExpiryNoticePending = NO;
    SGAddonExpiryGeneration++;
    SGAddonExpiryAlert = nil;
    SGAddonExpiryStableOwner = nil;
    SGAddonExpiryStableWindow = nil;
}

static void SGAddonExpiryMonitor(NSUInteger generation) {
    if (!SGAddonExpiryNoticePending || generation != SGAddonExpiryGeneration) return;
    UIAlertController *alert = SGAddonExpiryAlert;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        (!alert || !alert.presentingViewController || !alert.viewIfLoaded.window || alert.isBeingDismissed)) {
        // A launch/root transition can dismiss every modal without invoking an action.
        // That is not an acknowledgement: find the new stable presenter and try again.
        SGAddonExpiryAlert = nil;
        SGAddonExpiryStableOwner = nil;
        SGAddonExpiryStableWindow = nil;
        SGAddonExpiryTryPresent(0, generation);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        SGAddonExpiryMonitor(generation);
    });
}

static BOOL SGAddonExpiryPresenterReady(UIViewController **result) {
    UIApplication *application = UIApplication.sharedApplication;
    if (application.applicationState != UIApplicationStateActive) return NO;
    UIViewController *top = SGTopController();
    if (!top || !top.viewIfLoaded.window) return NO;
    // SGTopController returns the deepest presented child; inspect its containers too,
    // since a source page may be inside a modal navigation controller.
    for (UIViewController *controller = top; controller; controller = controller.parentViewController) {
        if (controller.isBeingPresented || controller.isBeingDismissed || controller.transitionCoordinator ||
            controller.presentedViewController || controller.presentingViewController) return NO;
    }
    *result = top;
    return YES;
}

static void SGAddonExpiryTryPresent(NSUInteger attempt, NSUInteger generation) {
    if (!SGAddonExpiryNoticePending || !SGAddonExpiryNoticeHandledActivation || generation != SGAddonExpiryGeneration) return;
    UIViewController *owner = nil;
    if (!SGAddonExpiryPresenterReady(&owner)) {
        SGAddonExpiryStableOwner = nil;
        SGAddonExpiryStableWindow = nil;
        if (attempt < 40 && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                SGAddonExpiryTryPresent(attempt + 1, generation);
            });
        } else {
            SGAddonExpiryNoticePending = NO;
        }
        return;
    }

    UIWindow *window = owner.viewIfLoaded.window;
    if (SGAddonExpiryStableOwner != owner || SGAddonExpiryStableWindow != window) {
        SGAddonExpiryStableOwner = owner;
        SGAddonExpiryStableWindow = window;
        SGAddonExpiryStableSince = CFAbsoluteTimeGetCurrent();
    }
    // An active window can still be Spotify's temporary launch root. Let it settle.
    if (CFAbsoluteTimeGetCurrent() - SGAddonExpiryStableSince < 2) {
        if (attempt < 40) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            SGAddonExpiryTryPresent(attempt + 1, generation);
        });
        else SGAddonExpiryNoticePending = NO;
        return;
    }

    NSArray<NSString *> *names = SGAddonExpiredSourceNames();
    if (!names.count) { SGAddonExpiryNoticePending = NO; return; }
    NSString *message = [NSString stringWithFormat:@"다음 소스의 인증이 만료되었습니다.\n%@\n인증을 갱신하려면 소스 관리로 이동하세요.", [names componentsJoinedByString:@"\n"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"소스 인증이 만료되었습니다" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"나중에" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        SGAddonExpiryChosen();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"이동" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        SGAddonExpiryChosen();
        UIViewController *page = SGAddonSourcesPage();
        SGAddonExpiryNavigationController *navigation = [[SGAddonExpiryNavigationController alloc] initWithRootViewController:page];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        page.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"닫기" style:UIBarButtonItemStylePlain target:navigation action:@selector(closeExpirySources)];
        SGShowAudioController(navigation);
    }]];
    SGPresentDark(alert);
    SGAddonExpiryAlert = alert;
    [owner presentViewController:alert animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        SGAddonExpiryMonitor(generation);
    });
}

%ctor {
    // The launch and each later activation have one bounded opportunity to show the notice.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ SGAddonExpiryActivation(); });
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SGAddonExpiryGeneration++;
            SGAddonExpiryNoticePending = NO;
            SGAddonExpiryNoticeHandledActivation = NO;
            SGAddonExpiryStableOwner = nil;
            SGAddonExpiryStableWindow = nil;
        });
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ SGAddonExpiryActivation(); });
}

static void SGAddonExpiryActivation(void) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || SGAddonExpiryNoticeHandledActivation) return;
    SGAddonExpiryNoticeHandledActivation = YES;
    SGAddonExpiryNoticePending = YES;
    NSUInteger generation = ++SGAddonExpiryGeneration;
    // An unanswered alert may have remained presented while the app was in background.
    if (SGAddonExpiryAlert.presentingViewController && SGAddonExpiryAlert.viewIfLoaded.window) {
        SGAddonExpiryMonitor(generation);
        return;
    }
    SGAddonExpiryTryPresent(0, generation);
}
