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
static void SGAddonExpiryActivation(void);

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
        if (attempt < 40 && UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                SGAddonExpiryTryPresent(attempt + 1, generation);
            });
        } else {
            SGAddonExpiryNoticePending = NO;
        }
        return;
    }

    NSArray<NSString *> *names = SGAddonExpiredSourceNames();
    if (!names.count) { SGAddonExpiryNoticePending = NO; return; }
    NSString *message = [NSString stringWithFormat:@"다음 소스의 인증이 만료되었습니다.\n%@\n인증을 갱신하려면 소스 관리로 이동하세요.", [names componentsJoinedByString:@"\n"]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"소스 인증이 만료되었습니다" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"나중에" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        SGAddonExpiryNoticePending = NO;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"이동" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        SGAddonExpiryNoticePending = NO;
        UIViewController *page = SGAddonSourcesPage();
        SGAddonExpiryNavigationController *navigation = [[SGAddonExpiryNavigationController alloc] initWithRootViewController:page];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        page.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"닫기" style:UIBarButtonItemStylePlain target:navigation action:@selector(closeExpirySources)];
        SGShowAudioController(navigation);
    }]];
    SGPresentDark(alert);
    [owner presentViewController:alert animated:YES completion:nil];
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
        });
    }];
    dispatch_async(dispatch_get_main_queue(), ^{ SGAddonExpiryActivation(); });
}

static void SGAddonExpiryActivation(void) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || SGAddonExpiryNoticeHandledActivation) return;
    SGAddonExpiryNoticeHandledActivation = YES;
    SGAddonExpiryNoticePending = YES;
    NSUInteger generation = ++SGAddonExpiryGeneration;
    SGAddonExpiryTryPresent(0, generation);
}
