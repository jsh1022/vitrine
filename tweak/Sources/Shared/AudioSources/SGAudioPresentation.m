#import "SGAudioPresentation.h"
#import "Core/SGGlass.h"
#import "Core/SGLog.h"
#import "Settings/SGPageStyle.h"

static void presentWhenReady(UIViewController *controller, NSUInteger attempt) {
    UIViewController *owner = SGTopController();
    if (!owner || !owner.viewIfLoaded.window || owner.isBeingPresented || owner.isBeingDismissed || owner.transitionCoordinator) {
        if (attempt < 40) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                presentWhenReady(controller, attempt + 1);
            });
        } else {
            SGLog(@"%@", @"audio sources: no stable visible presenter");
        }
        return;
    }
    SGPresentDark(controller);
    [owner presentViewController:controller animated:YES completion:nil];
}

void SGShowAudioController(UIViewController *controller) {
    dispatch_async(dispatch_get_main_queue(), ^{ presentWhenReady(controller, 0); });
}
