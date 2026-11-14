// Quality pill in the verified DurationElementUnit, between the elapsed/remaining labels.
// The badge stays within that row and never changes Spotify's stack or seek-bar geometry.
#import "Core/SGCore.h"
#import "Shared/AudioSources/SGPlaybackQuality.h"
#import <objc/runtime.h>

@interface SGPlaybackQualityBadge : NSObject
@property(nonatomic, weak) UIView *host;
@property(nonatomic, strong) UIButton *button;
@property(nonatomic, strong) NSTimer *timer;
- (void)refresh;
- (void)pause;
@end
@implementation SGPlaybackQualityBadge
- (void)dealloc { [_timer invalidate]; }
- (void)pause { [self.timer invalidate]; self.timer = nil; }
- (void)tapped { SGShowPlaybackQuality(self.button); }
- (void)refresh {
    UIView *host = self.host;
    if (!host.window) { [self pause]; self.button.hidden = YES; return; }
    if (!self.timer) {
        __weak typeof(self) weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [weakSelf refresh]; }];
        self.timer.tolerance = 0.2;
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
    __block UILabel *elapsed = nil, *remaining = nil;
    __block UISlider *slider = nil;
    SGForEachView(host, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class]) {
            if ([view.accessibilityIdentifier hasPrefix:@"now-playing-time-take-label"]) elapsed = (UILabel *)view;
            if ([view.accessibilityIdentifier hasPrefix:@"now-playing-time-remaning-label"]) remaining = (UILabel *)view;
        }
        if ([view isKindOfClass:UISlider.class]) slider = (UISlider *)view;
    });
    if (!elapsed || !remaining || !slider) { self.button.hidden = YES; return; }
    CGRect left = [elapsed convertRect:elapsed.bounds toView:host];
    CGRect right = [remaining convertRect:remaining.bounds toView:host];
    if (CGRectGetMinX(left) > CGRectGetMinX(right)) { CGRect swap = left; left = right; right = swap; }
    CGFloat available = CGRectGetMinX(right) - CGRectGetMaxX(left) - 16;
    CGRect track = [slider convertRect:[slider trackRectForBounds:slider.bounds] toView:host];
    CGFloat top = MAX(CGRectGetMinY(host.bounds), CGRectGetMaxY(track) + 2);
    CGFloat height = MIN(22, CGRectGetMaxY(host.bounds) - top);
    if (available < 44 || height < 16) { self.button.hidden = YES; return; }
    if (!self.button) {
        self.button = [UIButton buttonWithType:UIButtonTypeSystem];
        self.button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        self.button.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.button.titleLabel.minimumScaleFactor = 0.75;
        [self.button setTitleColor:[UIColor colorWithWhite:1 alpha:0.75] forState:UIControlStateNormal];
        self.button.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        self.button.layer.cornerCurve = kCACornerCurveContinuous;
        self.button.accessibilityIdentifier = @"vitrine.playback-quality";
        self.button.accessibilityHint = @"오디오 품질 정보 열기";
        [self.button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:self.button];
    }
    NSDictionary *info = SGPlaybackQualityInfo();
    NSString *title = info[@"label"];
    [self.button setTitle:title forState:UIControlStateNormal];
    self.button.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title, info[@"sourceRate"]];
    CGFloat wanted = ceil([title sizeWithAttributes:@{NSFontAttributeName:self.button.titleLabel.font}].width) + 20;
    CGFloat width = MIN(available, MAX(44, wanted));
    CGFloat centre = CGRectGetMidX(host.bounds);
    CGFloat x = MAX(CGRectGetMaxX(left) + 8, MIN(centre - width / 2, CGRectGetMinX(right) - 8 - width));
    CGFloat y = MAX(top, MIN(CGRectGetMidY(left) - height / 2, CGRectGetMaxY(host.bounds) - height));
    self.button.frame = CGRectMake(x, y, width, height);
    self.button.layer.cornerRadius = height / 2;
    self.button.hidden = NO;
}
@end

static char kQualityKey;
static SGPlaybackQualityBadge *qualityFor(UIViewController *unit) {
    SGPlaybackQualityBadge *badge = objc_getAssociatedObject(unit, &kQualityKey);
    if (!badge) {
        badge = [SGPlaybackQualityBadge new];
        objc_setAssociatedObject(unit, &kQualityKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    badge.host = unit.viewIfLoaded;
    return badge;
}
%hook _TtC20NowPlaying_ModesImpl19DurationElementUnit
- (void)viewDidLayoutSubviews { %orig; [qualityFor((UIViewController *)self) refresh]; }
- (void)viewDidAppear:(BOOL)animated { %orig; [qualityFor((UIViewController *)self) refresh]; }
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SGPlaybackQualityBadge *badge = objc_getAssociatedObject(self, &kQualityKey);
    [badge pause];
}
%end
%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC20NowPlaying_ModesImpl19DurationElementUnit"]);
}
