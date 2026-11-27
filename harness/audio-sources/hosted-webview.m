#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import "Shared/AudioSources/SGHostedLosslessPage.h"
#import "Shared/AudioSources/SGHostedLossless.h"
#import "Shared/AudioSources/SGWireGuard.h"
#import "Core/SGPrefs.h"

static NSUInteger completedCalls;
static NSString *receivedGrant;
static NSString *failure;
static UIWindow *window;
NSString *SGHostedProviderName(NSString *provider) { return [provider isEqual:@"qobuz"] ? @"Qobuz" : provider; }
void SGHostedBeginAuthentication(NSString *provider, void (^completion)(NSURL *, NSString *)) { (void)provider; (void)completion; }
void SGHostedCancelAuthentication(NSString *provider) { (void)provider; }
void SGHostedCompleteAuthentication(NSString *provider, NSString *grant, void (^completion)(NSString *)) {
    (void)provider; completedCalls++; receivedGrant=[grant copy]; completion(@"fixture hold");
}
BOOL SGFlag(NSString *key, BOOL fallback) { (void)key; return fallback; }
BOOL SGWireGuardAppProxyActive(void) { return NO; }

static void finish(void) {
    NSString *run=NSProcessInfo.processInfo.environment[@"SG_HOSTED_WEBVIEW_RUN_ID"];
    NSURL *docs=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSDictionary *receipt=@{@"run":run ?: @"",@"passed":failure ? @NO : @YES,@"calls":@(completedCalls),@"grant":receivedGrant ?: @"",@"failure":failure ?: @""};
    NSData *data=[NSJSONSerialization dataWithJSONObject:receipt options:0 error:NULL];
    [data writeToURL:[docs URLByAppendingPathComponent:@"hosted-webview-result.json"] options:NSDataWritingAtomic error:NULL];
    if (failure) NSLog(@"FAIL hosted WKWebView: %@",failure); else NSLog(@"PASS hosted WKWebView bridge delivered grant");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ exit(failure ? 1 : 0); });
}
@interface HostedWebViewApp : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation HostedWebViewApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; window=self.window;
    UIViewController *root=[UIViewController new]; root.view.backgroundColor=UIColor.systemBackgroundColor;
    self.window.rootViewController=root; [self.window makeKeyAndVisible];
    UIViewController *auth=SGHostedLosslessAuthPage(@"qobuz",nil);
    [root presentViewController:auth animated:NO completion:^{
        dispatch_async(dispatch_get_main_queue(),^{
            @try {
                UIViewController *page=[auth valueForKey:@"topViewController"];
                WKWebView *web=[page valueForKey:@"web"];
                if (!web) { failure=@"production authentication WKWebView was not created"; finish(); return; }
                NSString *html=@"<!doctype html><meta charset='utf-8'><iframe id='blank' src='about:blank'></iframe><iframe id='srcdoc' srcdoc='<p id=ready>srcdoc fixture</p>'></iframe><script>let sent=false;const timer=setInterval(()=>{const a=document.getElementById('blank').contentDocument,b=document.getElementById('srcdoc').contentDocument;if(!sent&&a&&b&&a.URL==='about:blank'&&a.readyState==='complete'&&b.URL==='about:srcdoc'&&b.readyState==='complete'&&b.getElementById('ready')){sent=true;clearInterval(timer);window.MornyeGrant.postMessage('gr_fixture')}},100);</script>";
                [web loadHTMLString:html baseURL:[NSURL URLWithString:@"https://api.zarz.moe/v2/challenge-fixture"]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                    NSLog(@"fixture URL=%@ committed=%@",web.URL,[page valueForKey:@"challengeLoaded"]);
                    [web evaluateJavaScript:@"JSON.stringify({url:document.URL,ready:document.readyState,bridge:typeof window.MornyeGrant,frames:Array.from(document.querySelectorAll('iframe')).map(f=>({url:f.contentDocument&&f.contentDocument.URL,ready:f.contentDocument&&f.contentDocument.readyState}))})" completionHandler:^(id result,NSError *error){NSLog(@"fixture DOM=%@ error=%@",result,error.localizedDescription);}];
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{
                    if (!completedCalls) failure=@"no grant bridge callback within 20 seconds (including baseURL origin and child-frame loads)";
                    else if (completedCalls!=1 || ![receivedGrant isEqual:@"gr_fixture"]) failure=@"grant exchange stub did not receive exactly one expected grant";
                    finish();
                });
            } @catch (NSException *exception) { failure=[NSString stringWithFormat:@"%@ %@",exception.name,exception.reason]; finish(); }
        });
    }];
    return YES;
}
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(HostedWebViewApp.class)); } }
