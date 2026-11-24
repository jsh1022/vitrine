// Three-second text shine follows the supplied BitChord PlayerControls.swift (GPL-3.0).
// Text-only quality control; the overlay is outside the seek unit's gesture/hit-test bounds.
#import "Core/SGCore.h"
#import "Player.h"
#import "Shared/AudioSources/SGPlaybackQuality.h"
#import "Redesigned/Player/SGRLosslessIcon.h"
#import <objc/runtime.h>

@interface SGRPlaybackQualityControl : UIButton
@property(nonatomic) BOOL shines;
@property(nonatomic, strong) UILabel *highlightText;
@property(nonatomic, strong) CAGradientLayer *band;
@end
@implementation SGRPlaybackQualityControl
- (void)setShines:(BOOL)value {
    if (_shines == value) return;
    _shines = value;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat textWidth = MIN(MAX(0, self.bounds.size.width - 20), ceil([self.currentTitle sizeWithAttributes:@{NSFontAttributeName:self.titleLabel.font}].width));
    CGFloat left = (self.bounds.size.width - textWidth - 19) / 2;
    self.imageView.frame = CGRectMake(left, (self.bounds.size.height - 14) / 2 - 4, 14, 14);
    self.titleLabel.frame = CGRectMake(left + 19, 0, textWidth, self.bounds.size.height - 8);
    if (!self.highlightText) {
        self.highlightText = [UILabel new]; self.highlightText.userInteractionEnabled = NO;
        self.highlightText.textColor = UIColor.whiteColor; self.highlightText.textAlignment = NSTextAlignmentCenter;
        self.highlightText.adjustsFontSizeToFitWidth = YES; self.highlightText.minimumScaleFactor = 0.8;
        self.highlightText.isAccessibilityElement = NO;
        self.band = [CAGradientLayer layer];
        self.band.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.whiteColor.CGColor, (id)UIColor.clearColor.CGColor];
        self.band.startPoint = CGPointMake(0, 0.5); self.band.endPoint = CGPointMake(1, 0.5);
        self.highlightText.layer.mask = self.band;
        [self addSubview:self.highlightText];
    }
    BOOL changed = ![self.highlightText.text isEqualToString:self.currentTitle] || !CGRectEqualToRect(self.highlightText.frame, self.titleLabel.frame);
    self.highlightText.text = self.currentTitle; self.highlightText.font = self.titleLabel.font;
    self.highlightText.frame = self.titleLabel.frame; self.highlightText.hidden = !self.shines;
    if (!self.shines) { [self.band removeAllAnimations]; return; }
    if (changed || ![self.band animationForKey:@"quality-shine"]) {
        [self.band removeAllAnimations];
        CGFloat width = MAX(1, textWidth * 0.6);
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        self.band.frame = CGRectMake(-width, 0, width, self.highlightText.bounds.size.height);
        [CATransaction commit];
        CABasicAnimation *shine = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        shine.fromValue = @0; shine.toValue = @(textWidth + 2 * width); shine.duration = 3;
        shine.repeatCount = HUGE_VALF; shine.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [self.band addAnimation:shine forKey:@"quality-shine"];
    }
}
@end

@interface SGRPlaybackQualityBadge : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIView *host;
@property(nonatomic, strong) SGRPlaybackQualityControl *button;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) CFTimeInterval lastTap;
- (void)refresh;
- (void)pause;
@end
@implementation SGRPlaybackQualityBadge
- (void)dealloc { [_timer invalidate]; [_button removeFromSuperview]; }
- (void)pause { [self.timer invalidate]; self.timer = nil; self.button.shines = NO; [self.button.band removeAllAnimations]; self.button.highlightText.hidden = YES; self.button.hidden = YES; }
- (void)tapped {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastTap < 0.4) return;
    self.lastTap = now; SGShowPlaybackQuality(self.button);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    // Parent taps/holds wait for this ordinary one-finger tap; pans retain normal scrolling.
    return ( [other isKindOfClass:UITapGestureRecognizer.class] || [other isKindOfClass:UILongPressGestureRecognizer.class])
        && other.view && [self.button isDescendantOfView:other.view];
}
- (void)refresh {
    UIView *host = self.host;
    if (!host.window) { [self pause]; return; }
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
    UIView *overlay = host;
    for (UIView *view = host.superview; view; view = view.superview) {
        if ([view.accessibilityIdentifier isEqualToString:@"scrolling_npv_collection_view_accessibility_identifier"]) { overlay = view; break; }
    }
    CGRect left = [elapsed convertRect:elapsed.bounds toView:overlay];
    CGRect right = [remaining convertRect:remaining.bounds toView:overlay];
    if (CGRectGetMinX(left) > CGRectGetMinX(right)) { CGRect swap = left; left = right; right = swap; }
    CGFloat available = CGRectGetMinX(right) - CGRectGetMaxX(left) - 16;
    CGRect track = [slider convertRect:[slider trackRectForBounds:slider.bounds] toView:overlay];
    if (available < 64) { self.button.hidden = YES; return; }
    if (!self.button) {
        self.button = [[SGRPlaybackQualityControl alloc] initWithFrame:CGRectZero];
        self.button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        self.button.titleLabel.adjustsFontSizeToFitWidth = YES; self.button.titleLabel.minimumScaleFactor = 0.8;
        [self.button setTitleColor:[UIColor colorWithWhite:1 alpha:0.55] forState:UIControlStateNormal];
        self.button.tintColor = [UIColor colorWithWhite:1 alpha:0.65]; self.button.backgroundColor = UIColor.clearColor;
        self.button.accessibilityIdentifier = @"vitrine.playback-quality";
        self.button.accessibilityHint = @"한 번 탭하여 오디오 품질 정보 열기";
        [self.button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
        tap.delegate = self; tap.delaysTouchesBegan = NO; tap.delaysTouchesEnded = NO;
        [self.button addGestureRecognizer:tap];
    }
    if (self.button.superview != overlay) [overlay addSubview:self.button];
    [overlay bringSubviewToFront:self.button];
    NSDictionary *info = SGPlaybackQualityInfo();
    NSString *title = info[@"label"];
    [self.button setTitle:title forState:UIControlStateNormal];
    BOOL measuredLossless = [info[@"shines"] boolValue];
    UIImage *qualityImage = measuredLossless ? SGRLosslessIconImage() : [UIImage systemImageNamed:info[@"symbol"]];
    [self.button setImage:qualityImage forState:UIControlStateNormal];
    self.button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.button.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", title, info[@"sourceRate"]];
    CGFloat wanted = ceil([title sizeWithAttributes:@{NSFontAttributeName:self.button.titleLabel.font}].width) + 32;
    CGFloat width = MIN(available, MAX(96, wanted));
    CGFloat height = 36;
    CGFloat centre = CGRectGetMidX([host convertRect:host.bounds toView:overlay]);
    CGFloat x = MAX(CGRectGetMaxX(left) + 8, MIN(centre - width / 2, CGRectGetMinX(right) - 8 - width));
    CGFloat centreY = MAX(CGRectGetMidY(left), CGRectGetMaxY(track) + 24);
    CGRect sliderTouch = [slider convertRect:slider.bounds toView:overlay];
    centreY = MAX(centreY, CGRectGetMaxY(sliderTouch) + height / 2 + 2);
    self.button.frame = CGRectMake(x, centreY - height / 2, width, height);
    self.button.hidden = NO;
    if (!SGRPlayerLyricsFadeView(self.button,YES)) self.button.alpha=1;
    self.button.shines = [info[@"shines"] boolValue] && !UIAccessibilityIsReduceMotionEnabled()
        && !NSProcessInfo.processInfo.lowPowerModeEnabled && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    [self.button setNeedsLayout]; [self.button layoutIfNeeded];
}
@end

static char kQualityKey;
static SGRPlaybackQualityBadge *qualityFor(UIViewController *unit) {
    SGRPlaybackQualityBadge *badge = objc_getAssociatedObject(unit, &kQualityKey);
    if (!badge) { badge = [SGRPlaybackQualityBadge new]; objc_setAssociatedObject(unit, &kQualityKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    badge.host = unit.viewIfLoaded; return badge;
}
%hook _TtC20NowPlaying_ModesImpl19DurationElementUnit
- (void)viewDidLayoutSubviews { %orig; [qualityFor((UIViewController *)self) refresh]; }
- (void)viewDidAppear:(BOOL)animated { %orig; [qualityFor((UIViewController *)self) refresh]; }
- (void)viewDidDisappear:(BOOL)animated {
    %orig; SGRPlaybackQualityBadge *badge = objc_getAssociatedObject(self, &kQualityKey); [badge pause];
}
%end
%ctor {
    if (!SGRedesignedUI()) return;
    %init; SGRequireClasses(@[@"_TtC20NowPlaying_ModesImpl19DurationElementUnit"]);
}
