#import "SGHostedLosslessPage.h"
#import "SGHostedLossless.h"
#import "SGHostedAuthPolicy.h"
#import "SGWireGuard.h"
#import "Core/SGPrefs.h"
#import <WebKit/WebKit.h>

// WKUserContentController retains its handler; the proxy prevents a controller/WebView retain cycle.
@interface SGHostedGrantBridge : NSObject <WKScriptMessageHandler>
@property(nonatomic,weak) id<WKScriptMessageHandler> owner;
@end
@implementation SGHostedGrantBridge
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.owner userContentController:controller didReceiveScriptMessage:message];
}
@end

@interface SGHostedAuthController : UIViewController <WKNavigationDelegate, WKScriptMessageHandler>
@property(nonatomic,copy) NSString *provider;
@property(nonatomic,copy) void (^finished)(BOOL);
@property(nonatomic) WKWebView *web;
@property(nonatomic) UILabel *status;
@property(nonatomic) BOOL exchanging, completed, challengeLoaded;
@property(nonatomic) NSUInteger attempt;
@end
@implementation SGHostedAuthController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=[NSString stringWithFormat:@"%@ 인증", SGHostedProviderName(self.provider)];
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark; self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"닫기" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"다시 시도" style:UIBarButtonItemStylePlain target:self action:@selector(startAttempt)];
    self.status=[UILabel new]; self.status.numberOfLines=0; self.status.textColor=UIColor.secondaryLabelColor;
    self.status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.status.translatesAutoresizingMaskIntoConstraints=NO; [self.view addSubview:self.status];
    [NSLayoutConstraint activateConstraints:@[[self.status.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.status.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16], [self.status.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16]]];
    [self startAttempt];
}
- (void)stopWeb {
    [self.web stopLoading]; self.web.navigationDelegate=nil;
    [self.web.configuration.userContentController removeScriptMessageHandlerForName:@"mornyeGrant"];
    [self.web removeFromSuperview]; self.web=nil;
}
- (void)startAttempt {
    if (self.completed || self.exchanging) return;
    SGHostedCancelAuthentication(self.provider);
    NSUInteger attempt=++self.attempt;
    [self stopWeb]; self.challengeLoaded=NO;
    self.status.text=@"인증 서버에 연결 중입니다. 인증 정보는 이 기기의 Keychain에 저장합니다.";
    // WebKit does not inherit URLSession's app-local tunnel. Do not silently go direct.
    if (SGFlag(SGKeySourceWireGuard,NO) || SGWireGuardAppProxyActive()) {
        self.status.text=@"현재 웹 인증 화면은 앱 내부 WireGuard를 지원하지 않습니다. 인증하려면 WireGuard를 끈 뒤 다시 열어 주세요. 소스 요청은 기존 네트워크 정책을 따릅니다."; return;
    }
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    config.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;
    config.defaultWebpagePreferences.allowsContentJavaScript=YES;
    SGHostedGrantBridge *bridge=[SGHostedGrantBridge new]; bridge.owner=self;
    [config.userContentController addScriptMessageHandler:bridge name:@"mornyeGrant"];
    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:SGHostedAuthBridgeScript()
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    self.web=[[WKWebView alloc] initWithFrame:CGRectZero configuration:config]; self.web.navigationDelegate=self;
    // Keep WebKit's actual default user agent stable throughout the challenge.
    self.web.overrideUserInterfaceStyle=UIUserInterfaceStyleDark; self.web.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:self.web];
    [NSLayoutConstraint activateConstraints:@[[self.web.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:12],
        [self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.web.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]]];
    __weak SGHostedAuthController *weak=self;
    SGHostedBeginAuthentication(self.provider, ^(NSURL *challenge, NSString *error) {
        SGHostedAuthController *owner=weak; if (!owner || owner.completed || owner.attempt!=attempt) return;
        if (error) { owner.status.text=error; return; }
        if (!challenge) { [owner succeed]; return; }
        owner.status.text=@"웹 인증을 완료해 주세요. 확인이 계속되면 ‘다시 시도’로 새 인증을 시작할 수 있습니다.";
        [owner.web loadRequest:[NSURLRequest requestWithURL:challenge]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            SGHostedAuthController *current=weak;
            if (current && !current.completed && !current.exchanging && current.attempt==attempt)
                current.status.text=@"웹 인증이 오래 걸리고 있습니다. ‘다시 시도’로 새 인증을 시작하세요. 계속되면 네트워크를 바꿔 확인해 주세요.";
        });
    });
}
- (void)succeed {
    if (self.completed) return;
    self.completed=YES;
    void (^done)(BOOL)=self.finished; self.finished=nil;
    [self stopWeb];
    [self dismissViewControllerAnimated:YES completion:^{ if(done)done(YES); }];
}
- (void)close {
    SGHostedCancelAuthentication(self.provider);
    self.completed=YES; self.finished=nil; ++self.attempt; [self stopWeb];
    [self dismissViewControllerAnimated:YES completion:nil];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (!self.view.window) { SGHostedCancelAuthentication(self.provider); self.completed=YES; self.finished=nil; ++self.attempt; [self stopWeb]; }
}
- (void)webView:(WKWebView *)web didCommitNavigation:(WKNavigation *)navigation {
    if (web==self.web && SGHostedAuthBrokerURL(web.URL)) self.challengeLoaded=YES;
}
- (void)acceptGrantValue:(NSString *)value {
    if (!self.challengeLoaded || self.exchanging || self.completed || !SGHostedAuthBrokerURL(self.web.URL)) return;
    NSString *grant=SGHostedAuthGrant(value);
    if (!grant.length) return;
    self.exchanging=YES; self.navigationItem.rightBarButtonItem.enabled=NO;
    self.status.text=@"인증 결과를 확인하고 세션을 저장하는 중입니다.";
    NSUInteger attempt=self.attempt;
    __weak SGHostedAuthController *weak=self;
    SGHostedCompleteAuthentication(self.provider,grant,^(NSString *error) {
        SGHostedAuthController *owner=weak; if (!owner || owner.completed || owner.attempt!=attempt) return;
        owner.exchanging=NO; owner.navigationItem.rightBarButtonItem.enabled=YES;
        if (error) owner.status.text=error; else [owner succeed];
    });
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    WKSecurityOrigin *origin=message.frameInfo.securityOrigin;
    if (message.webView!=self.web || !message.frameInfo.isMainFrame ||
        ![origin.protocol isEqual:@"https"] || ![origin.host.lowercaseString isEqual:@"api.zarz.moe"] ||
        (origin.port!=0 && origin.port!=443) || ![message.body isKindOfClass:NSString.class]) return;
    [self acceptGrantValue:message.body];
}
- (void)webView:(WKWebView *)web decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decision {
    if (web!=self.web || self.completed) { decision(WKNavigationActionPolicyCancel); return; }
    NSURL *url=action.request.URL;
    if (SGHostedAuthGrant(url.absoluteString)) {
        decision(WKNavigationActionPolicyCancel);
        if (action.targetFrame.isMainFrame) [self acceptGrantValue:url.absoluteString];
        return;
    }
    decision(SGHostedAuthNavigationAllowed(url,action.targetFrame.isMainFrame) ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)web didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (web!=self.web || self.completed) return;
    // Unsupported app-scheme redirects may surface only as failed loads in WebKit.
    NSString *failing=error.userInfo[NSURLErrorFailingURLStringErrorKey];
    if ([failing isKindOfClass:NSString.class] && SGHostedAuthGrant(failing)) [self acceptGrantValue:failing];
    else if (error.code!=NSURLErrorCancelled) self.status.text=@"인증 웹 페이지를 열지 못했습니다. ‘다시 시도’로 새 인증을 시작하세요.";
}
@end
UIViewController *SGHostedLosslessAuthPage(NSString *provider, void (^completion)(BOOL)) {
    SGHostedAuthController *page=[SGHostedAuthController new]; page.provider=provider; page.finished=completion;
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:page];
    nav.overrideUserInterfaceStyle=UIUserInterfaceStyleDark; return nav;
}
