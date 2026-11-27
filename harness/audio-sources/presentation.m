#import <UIKit/UIKit.h>
#import "Settings/SGModPage.h"
#import "Shared/AudioSources/SGAddons.h"
#import "Shared/AudioSources/SGHostedLossless.h"
#import "Shared/AudioSources/SGAudioPresentation.h"
#import "Shared/AudioSources/SGWireGuard.h"
#import "Shared/AudioSources/SGPlaybackQuality.h"
#import "Core/SGViewTree.h"

extern NSArray<SGModRow *> *SGPresentationRows;
extern NSArray<NSString *> *SGPresentationExpiredSources;
extern BOOL SGPresentationExternal, SGPresentationNativePCM;
extern NSDictionary *SGPresentationSourceInfo, *SGPresentationPreparedInfo;
extern SGAddonPreparationState SGPresentationPreparation;
extern BOOL SGPresentationStaticCover;
extern UIImage *SGPresentationArtwork;

@interface _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController : UIViewController
@end
@implementation _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
@end
@interface _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView : UIView
@end
@implementation _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
@end
@interface _TtC17Canvas_PlayerImpl16CanvasPlayerView : UIView
@end
@implementation _TtC17Canvas_PlayerImpl16CanvasPlayerView
@end

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
    _slider.accessibilityIdentifier = @"fixture.seek-slider";
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

#import "Shared/Lyrics/Lyrics.h"
extern NSString *SGPresentationLyricsTrack;
extern NSArray<SGKaraokeLine *> *SGPresentationLyrics;
extern NSInteger SGPresentationLyricsPosition, SGPresentationLyricsDelay;
@interface _TtC22Lyrics_NPVContainerKit19LyricsContainerView : UIView
@end
@implementation _TtC22Lyrics_NPVContainerKit19LyricsContainerView
- (void)layoutSubviews { [super layoutSubviews]; }
- (void)didMoveToWindow { [super didMoveToWindow]; }
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
// simctl can close its console relay before a successful process's last output arrives.
// Keep an atomic, per-launch receipt; only milestones actually reached are recorded.
static NSMutableArray<NSString *> *sg_passed;
static void passed(NSString *line) {
    NSCAssert(NSThread.isMainThread, @"Test milestones must run on main");
    if (!sg_passed) sg_passed = [NSMutableArray array];
    [sg_passed addObject:line];
    printf("%s\n", line.UTF8String); fflush(stdout);
}
static void finish(void) {
    NSString *run = NSProcessInfo.processInfo.environment[@"SG_PRESENTATION_RUN_ID"];
    if (!run.length) { fail(@"missing per-launch result identity"); return; }
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        fail([NSString stringWithFormat:@"cannot create result directory: %@", error]); return;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"run": run, @"passed": @YES, @"markers": sg_passed ?: @[]} options:0 error:&error];
    if (!data || ![data writeToURL:[directory URLByAppendingPathComponent:@"presentation-result.json"] options:NSDataWritingAtomic error:&error]) {
        fail([NSString stringWithFormat:@"cannot persist test result: %@", error]); return;
    }
    fflush(stdout); fflush(stderr);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ exit(0); });
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
    if (stages.count != 5 || ![stages[0][@"title"] isEqual:@"곡 정보"] || ![stages[4][@"title"] isEqual:@"출력 기기"] ||
        ![pipeline[@"statsLine"] isEqual:@"선택한 소스의 디코더 측정값 없음"]) {
        fail(@"pipeline must contain five stages without inventing unknown source measurements"); return;
    }
    SGPresentationNativePCM = YES;
    NSDictionary *native = SGAudioPipelineSnapshot();
    NSArray *nativeRows = native[@"stages"][0][@"rows"];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSDictionary *row in nativeRows) values[row[@"label"]] = row[@"value"];
    if (![native[@"statsLine"] containsString:@"Spotify 출력 PCM"] ||
        ![native[@"statsLine"] containsString:@"44.1 kHz"] ||
        ![values[@"형식"] isEqual:@"—"] || ![values[@"비트 깊이"] isEqual:@"—"] ||
        ![values[@"비트레이트"] isEqual:@"—"] || ![values[@"샘플레이트"] isEqual:@"—"] ||
        ![values[@"Spotify 품질 설정"] containsString:@"실제 비트레이트 아님"]) {
        fail(@"Spotify output PCM and configured levels must never become compressed-source measurements"); return;
    }
    SGPresentationNativePCM = NO;
    passed(@"PASS Spotify PCM measurement and configured-quality separation without guessed codec or bitrate");
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
        dispatch_async(dispatch_get_main_queue(), ^{
            passed(@"PASS audio source presentations: add source, import picker, result alert, playback details, main-thread dispatch");
            passed(@"PASS unavailable WireGuard: session factories, shared session, preserved config, HTTP/3 disabled, HTTP request blocked");
            finish();
        });
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
- (void)checkExpiryNotice {
    SGPresentationExpiredSources=@[@"Qobuz"];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    waitFor(^BOOL {
        UIViewController *shown=self.nav.presentedViewController;
        return [shown isKindOfClass:UIAlertController.class] && !shown.isBeingPresented && !shown.transitionCoordinator;
    },^{
        UIAlertController *alert=(id)self.nav.presentedViewController;
        if(![alert.title isEqual:@"소스 인증이 만료되었습니다"] || ![alert.message containsString:@"Qobuz"] || alert.actions.count!=2 || alert.overrideUserInterfaceStyle!=UIUserInterfaceStyleDark) {fail(@"expiry notice content or dark appearance missing");return;}
        UIAlertAction *move=nil; for(UIAlertAction *action in alert.actions) if([action.title isEqual:@"이동"])move=action;
        if(!move) {fail(@"expiry notice navigation action missing");return;}
        void (^handler)(UIAlertAction *)=[move valueForKey:@"handler"];
        if(!handler){fail(@"expiry navigation action has no handler");return;}
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
        if(self.nav.presentedViewController!=alert || alert.presentedViewController) {fail(@"duplicate expiry notice");return;}
        [alert dismissViewControllerAnimated:YES completion:^{
            handler(move);
            waitFor(^BOOL {
                UINavigationController *shown=(id)self.nav.presentedViewController;
                return [shown isKindOfClass:UINavigationController.class] && [shown.topViewController.title isEqual:@"음원을 찾는 순서"] && !shown.isBeingPresented && !shown.transitionCoordinator;
            },^{
                UINavigationController *shown=(id)self.nav.presentedViewController;
                if(shown.overrideUserInterfaceStyle!=UIUserInterfaceStyleDark || ![shown.topViewController.navigationItem.leftBarButtonItem.title isEqual:@"닫기"]) {fail(@"source management sheet needs dark appearance and dismissal");return;}
                [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
                [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,400*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                    if(shown.presentedViewController) {fail(@"expiry notice interrupted existing source management sheet");return;}
                    SGPresentationExpiredSources=nil;
                    [shown dismissViewControllerAnimated:YES completion:^{
                        passed(@"PASS source expiry notice: local names, duplicate suppression, direct management navigation and modal protection");
                        checkBlockedTransport();
                    }];
                });
            },200);
        }];
    },200);
}
- (void)step:(NSUInteger)index {
    progress([NSString stringWithFormat:@"step %lu", (unsigned long)index]);
    if (index == 8) {
        [self checkExpiryNotice]; return;
    }
    if (index == 7) {
        SGPresentationArtwork = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8, 8)] imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [UIColor.redColor setFill]; UIRectFill(CGRectMake(0, 0, 8, 8));
        }];
        SGPresentationStaticCover = YES;
        UIViewController *screen = [UIViewController new];
        Class renderer = NSClassFromString(@"SGNativeFullArtwork");
        if (!renderer) { fail(@"full-screen artwork renderer missing"); return; }
        UIView *cover = [[renderer alloc] initWithFrame:CGRectMake(0, 0, self.window.bounds.size.width, self.window.bounds.size.height / 2)];
        [screen.view addSubview:cover]; [self.nav pushViewController:screen animated:NO];
        [cover setNeedsLayout]; [cover layoutIfNeeded];
        waitFor(^BOOL { return cover.window && !cover.hidden; }, ^{
            UIImageView *picture = nil;
            for (UIView *child in cover.subviews) if ([child isKindOfClass:UIImageView.class]) picture = (UIImageView *)child;
            UIView *blurImage = identified(cover, @"vitrine.static-cover.blur-image");
            CGFloat expectedHeight = MIN(MAX(cover.bounds.size.height, self.window.bounds.size.height), cover.bounds.size.width * 4.0 / 3.0);
            if (!picture.image || fabs(picture.frame.size.height - expectedHeight) > 1 ||
                blurImage.frame.size.height < self.window.bounds.size.height || !picture.layer.mask ||
                picture.contentMode != UIViewContentModeScaleAspectFill || cover.userInteractionEnabled) {
                fail(@"static artwork must keep portrait framing with a full-screen blurred continuation"); return;
            }
            SGPresentationStaticCover = NO;
            [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:nil];
            waitFor(^BOOL { return cover.hidden; }, ^{
                [cover removeFromSuperview]; SGPresentationArtwork = nil;
                passed(@"PASS full-screen static artwork and live option removal");
                [self step:8];
            }, 200);
        }, 200);
        return;
    }
    if (index == 6) {
        // Also prove the helper accepts a request arriving from a worker thread.
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Worker request" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ SGShowAudioController(alert); });
    } else if (index == 5) {
        UIButton *details = (UIButton *)identified(self.nav.presentedViewController.view, @"vitrine.audio-quality.details");
        if (!details) { fail(@"quality popover details action missing"); return; }
        [details sendActionsForControlEvents:UIControlEventTouchUpInside];
    } else if (index == 4) {
        UIView *preview = [[_TtC22Lyrics_NPVContainerKit19LyricsContainerView alloc] initWithFrame:CGRectMake(0, 0, 300, 30)];
        UILabel *line = [[UILabel alloc] initWithFrame:preview.bounds];
        [preview addSubview:line]; [self.window addSubview:preview];
        SGPresentationLyrics = SGKaraokeEstimatedLines(@[@1000, @3000], @[@"첫 줄", @"다음 줄"]);
        SGPresentationLyricsPosition = 3200; SGPresentationLyricsDelay = 0;
        [preview setNeedsLayout]; [preview layoutIfNeeded];
        if (![line.text isEqual:@"다음 줄"]) { fail(@"inline lyric does not follow playback position"); return; }
        SGPresentationLyricsDelay = 500;
        [preview setNeedsLayout]; [preview layoutIfNeeded];
        if (![line.text isEqual:@"첫 줄"]) { fail(@"inline lyric does not respect user delay"); return; }
        SGPresentationLyricsPosition = 500;
        [preview setNeedsLayout]; [preview layoutIfNeeded];
        if (line.text.length) { fail(@"inline lyric must clear before the first timed line"); return; }
        SGPresentationLyricsPosition = 3200; SGPresentationLyricsDelay = 0;
        [preview setNeedsLayout]; [preview layoutIfNeeded];
        SGPresentationLyricsTrack = @"next"; SGPresentationLyrics = nil;
        [preview setNeedsLayout]; [preview layoutIfNeeded];
        if (line.text.length) { fail(@"previous song inline lyric leaked into the next song"); return; }
        [preview removeFromSuperview];
        passed(@"PASS inline lyric position, delay, seek and track replacement");
        SGPresentationPreparedInfo = @{@"sourceName": @"Fixture", @"declared": @{@"sampleRate": @96000, @"bitDepth": @24}};
        if (![SGPlaybackQualityInfo()[@"label"] isEqualToString:@"기본"] ||
            ![SGPlaybackQualityInfo()[@"sourceRate"] isEqualToString:@"확인 불가"]) {
            fail(@"prepared provider metadata must not create a lossless badge"); return;
        }
        SGPresentationPreparation = SGAddonPreparationSearching;
        if (![SGPlaybackQualityInfo()[@"label"] isEqualToString:@"기본"]) { fail(@"searching must retain the default visible label"); return; }
        SGPresentationPreparation = SGAddonPreparationUnavailable;
        if (![SGPlaybackQualityInfo()[@"label"] isEqualToString:@"기본"]) { fail(@"unavailable source must show the default label"); return; }
        SGPresentationExternal = YES;
        SGPresentationSourceInfo = @{@"rate": @44100, @"bits": @16, @"codec": @"FLAC", @"channels": @2};
        if (![SGPlaybackQualityInfo()[@"label"] isEqualToString:@"무손실"]) { fail(@"CD lossless must not use the provider's hi-res claim"); return; }
        SGPresentationSourceInfo = @{@"rate": @48000, @"bits": @24, @"codec": @"FLAC", @"channels": @2};
        if (![SGPlaybackQualityInfo()[@"sourceRate"] isEqualToString:@"48 kHz"] ||
            ![SGPlaybackQualityInfo()[@"label"] isEqualToString:@"고해상도 무손실"]) {
            fail(@"quality badge must use decoder measurement instead of the 96 kHz provider claim"); return;
        }
        UIViewController *unit = [_TtC20NowPlaying_ModesImpl19DurationElementUnit new];
        UIViewController *screen = [UIViewController new];
        screen.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        screen.view.backgroundColor = UIColor.blackColor;
        UIScrollView *list = [[UIScrollView alloc] initWithFrame:screen.view.bounds];
        list.accessibilityIdentifier = @"scrolling_npv_collection_view_accessibility_identifier";
        list.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        list.contentSize = list.bounds.size; [screen.view addSubview:list];
        [screen addChildViewController:unit]; [list addSubview:unit.view]; [unit didMoveToParentViewController:screen];
        unit.view.frame = CGRectMake(20, 180, screen.view.bounds.size.width - 40, 48);
        unit.view.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self.nav pushViewController:screen animated:NO];
        [unit.view setNeedsLayout]; [unit.view layoutIfNeeded];
        waitFor(^BOOL {
            return !self.nav.presentedViewController && !self.nav.transitionCoordinator
                && identified(screen.view, @"vitrine.playback-quality").window != nil;
        }, ^{
            UIButton *badge = (UIButton *)identified(screen.view, @"vitrine.playback-quality");
            UIView *elapsed = identified(unit.view, @"now-playing-time-take-label-internal");
            UIView *remaining = identified(unit.view, @"now-playing-time-remaning-label-internal");
            CGRect left = [elapsed convertRect:elapsed.bounds toView:list], right = [remaining convertRect:remaining.bounds toView:list];
            UIView *slider = identified(unit.view, @"fixture.seek-slider");
            CGRect seek = [slider convertRect:slider.bounds toView:list];
            if (CGRectIntersectsRect(badge.frame, seek)) { fail(@"quality hit target overlaps the seek slider"); return; }
            if (badge.hidden || ![badge.currentTitle isEqualToString:@"고해상도 무손실"] ||
                CGRectIntersectsRect(badge.frame, left) || CGRectIntersectsRect(badge.frame, right)) {
                fail(@"quality badge hidden, incorrect, or overlapping timestamps"); return;
            }
            if (badge.superview != list || badge.bounds.size.height < 36 || CGColorGetAlpha(badge.backgroundColor.CGColor) != 0 || badge.layer.borderWidth != 0) {
                fail(@"text-only quality control must have an unclipped large hit target"); return;
            }
            CGPoint inside = CGPointMake(CGRectGetMidX(badge.bounds), CGRectGetMaxY(badge.bounds) - 2);
            UIView *hit = [self.window hitTest:[badge convertPoint:inside toView:self.window] withEvent:nil];
            BOOL singleTap = NO;
            for (UIGestureRecognizer *gesture in badge.gestureRecognizers)
                if ([gesture isKindOfClass:UITapGestureRecognizer.class] && ((UITapGestureRecognizer *)gesture).numberOfTapsRequired == 1) singleTap = YES;
            if (![hit isDescendantOfView:badge] || !singleTap) { fail(@"quality control must accept an ordinary tap outside the scrub unit bounds"); return; }
            [badge sendActionsForControlEvents:UIControlEventTouchUpInside];
        }, 200);
    } else if (index == 0) {
        SGModRow *parallelQuality = nil;
        for (SGModRow *row in SGPresentationRows) if ([row.title isEqual:@"동시 조회 · 최고 음질 우선"]) parallelQuality = row;
        if (!parallelQuality || ![parallelQuality.key isEqual:SGKeyAddonParallelQuality] || parallelQuality.defaultOn || !parallelQuality.changed) {
            fail(@"parallel quality lookup must exist, use its preference key and default off"); return;
        }
        SGModRow *entry = nil;
        for (SGModRow *row in SGPresentationRows) if ([row.title isEqual:@"음원을 찾는 순서"]) entry = row;
        if (!entry.page) { fail(@"missing source-management page entry"); return; }
        UIViewController *controller = entry.page();
        if (![controller isKindOfClass:UITableViewController.class]) { fail(@"source management must be the real table controller"); return; }
        [self.nav pushViewController:controller animated:NO];
        UITableView *table = ((UITableViewController *)controller).tableView;
        [table layoutIfNeeded];
        NSIndexPath *add = [NSIndexPath indexPathForRow:0 inSection:1];
        if (![controller.title isEqual:@"음원을 찾는 순서"] || [table.dataSource numberOfSectionsInTableView:table] != 2 ||
            [table.dataSource tableView:table numberOfRowsInSection:1] != 4) {
            fail(@"source-management add section missing"); return;
        }
        UITableViewCell *cell = [table.dataSource tableView:table cellForRowAtIndexPath:add];
        UIListContentConfiguration *content = (id)cell.contentConfiguration;
        if (![content isKindOfClass:UIListContentConfiguration.class] || ![content.text isEqual:@"추가 음원 서비스 연결"]) {
            fail(@"production add-source row missing"); return;
        }
        NSArray<NSString *> *providers = SGHostedProviderIdentifiers();
        if (providers.count != 3) { fail(@"hosted provider list must contain three providers"); return; }
        for (NSInteger i=1;i<=3;i++) {
            UITableViewCell *builtin=[table.dataSource tableView:table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:1]];
            UIListContentConfiguration *configuration=(UIListContentConfiguration *)builtin.contentConfiguration;
            NSString *expected=[NSString stringWithFormat:@"내장 %@ 추가", SGHostedProviderName(providers[(NSUInteger)i-1])];
            if (![configuration isKindOfClass:UIListContentConfiguration.class] || ![configuration.text isEqual:expected]) { fail(@"built-in source add row missing"); return; }
        }
        if (![table.delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) { fail(@"source-management row action missing"); return; }
        [table.delegate tableView:table didSelectRowAtIndexPath:add];
    } else if (index == 3) {
        SGShowPlaybackDetails();
    } else {
        // Do not replace the navigation stack during the previous modal's dismissal.
        // The WireGuard page only supplies the actual action rows for these two steps.
        if (index == 1) (void)SGWireGuardSettingsPage();
        NSString *title = @[@"추가 음원 서비스 연결", @".conf 파일 가져오기", @"저장된 프로필 삭제"][index];
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
        if (index == 0) return [shown isKindOfClass:UIAlertController.class] && [shown.title isEqualToString:@"추가 음원 서비스 연결"];
        if (index == 1) return [shown isKindOfClass:UIDocumentPickerViewController.class];
        if (index == 2) return [shown isKindOfClass:UIAlertController.class] && [shown.title isEqualToString:@"WireGuard"];
        if (index == 3) return [shown isKindOfClass:UINavigationController.class] && [((UINavigationController *)shown).topViewController.title isEqualToString:@"상세 재생 정보"];
        if (index == 4) return [shown.view.accessibilityIdentifier isEqualToString:@"vitrine.audio-quality.popover"];
        if (index == 5) return [shown isKindOfClass:UINavigationController.class] && [((UINavigationController *)shown).topViewController.title isEqualToString:@"상세 재생 정보"];
        return [shown isKindOfClass:UIAlertController.class] && [shown.title isEqualToString:@"Worker request"];
    }, ^{
        UIViewController *shown = self.nav.presentedViewController;
        if (shown.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) fail(@"missing dark style");
        if (index == 0 && (![shown isKindOfClass:UIAlertController.class] || ![shown.title isEqualToString:@"추가 음원 서비스 연결"] || [(UIAlertController *)shown textFields].count != 1)) fail(@"add-source editor missing");
        if (index == 1 && ![shown isKindOfClass:UIDocumentPickerViewController.class]) fail(@"document picker missing");
        if (index == 2 && (![shown isKindOfClass:UIAlertController.class] || ![shown.title isEqualToString:@"WireGuard"])) fail(@"result message missing");
        if (index == 3 && (![shown isKindOfClass:UINavigationController.class] || ![((UINavigationController *)shown).topViewController.title isEqualToString:@"상세 재생 정보"])) fail(@"playback details missing");
        if (index == 4) { [self step:5]; return; }
        if (index == 5) {
            SGPresentationExternal = NO; SGPresentationSourceInfo = nil; SGPresentationPreparedInfo = nil;
            SGPresentationPreparation = SGAddonPreparationIdle;
            passed(@"PASS playback quality badge and popover");
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
