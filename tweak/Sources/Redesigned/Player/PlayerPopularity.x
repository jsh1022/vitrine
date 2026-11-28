// The track's popularity replaces the playlist/source label in the player's header.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SGTrackPopularity.h"
#import "Redesigned/Kit/SGRTrackPopularity.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"

static char kPopularityBadgeKey, kSourceAlphaKey;
static __weak UIView *sg_popularityHost;
static NSHashTable<UILabel *> *sg_sourceLabels;
static NSString *sg_popularityTrack;
static NSUInteger sg_popularityGeneration;
static NSNumber *sg_popularityValue;
static id<SGPlayerStateObserver> sg_popularityWatcher;

static BOOL popularityEnabled(void) { return SGFlag(SGRKeyPlayerPopularity, YES); }

@interface SGRPopularityBadge : UIView
@property (nonatomic, strong) UIImageView *flame;
@property (nonatomic, strong) UILabel *number;
@end

@implementation SGRPopularityBadge
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = YES;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.18];
    if (UIAccessibilityIsReduceTransparencyEnabled()) self.backgroundColor = [UIColor colorWithWhite:0.10 alpha:1];
    self.layer.cornerRadius = 11;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    _flame = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"flame.fill"]];
    _flame.tintColor = [UIColor.whiteColor colorWithAlphaComponent:0.85];
    _flame.contentMode = UIViewContentModeScaleAspectFit;
    _flame.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightMedium];
    [self addSubview:_flame];
    _number = [UILabel new];
    _number.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    _number.textColor = [UIColor.whiteColor colorWithAlphaComponent:0.85];
    [self addSubview:_number];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.flame.frame = CGRectMake(7, 5, 12, 12);
    CGFloat numberWidth = ceil([self.number sizeThatFits:CGSizeMake(CGFLOAT_MAX, 22)].width);
    self.number.frame = CGRectMake(23, 0, numberWidth, 22);
}
@end

static SGRPopularityBadge *badgeFor(UIView *host) {
    SGRPopularityBadge *badge = objc_getAssociatedObject(host, &kPopularityBadgeKey);
    if (!badge) {
        badge = [[SGRPopularityBadge alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(host, &kPopularityBadgeKey, badge, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:badge];
    }
    return badge;
}

static void restoreSourceLabels(void) {
    for (UILabel *label in sg_sourceLabels) {
        NSNumber *alpha = objc_getAssociatedObject(label, &kSourceAlphaKey);
        if (alpha) label.alpha = alpha.doubleValue;
    }
    [sg_sourceLabels removeAllObjects];
}

static void collectCenterLabels(UIView *root, UIView *host, CGFloat left, CGFloat right, NSMutableArray<UILabel *> *labels) {
    if ([root isKindOfClass:SGRPopularityBadge.class]) return;
    if ([root isKindOfClass:UILabel.class]) {
        CGRect frame = [root convertRect:root.bounds toView:host];
        CGFloat center = CGRectGetMidX(frame);
        if (center >= left && center <= right && ((UILabel *)root).text.length) [labels addObject:(UILabel *)root];
    }
    for (UIView *child in root.subviews) collectCenterLabels(child, host, left, right, labels);
}

static void layoutPopularityBadge(void) {
    UIView *host = sg_popularityHost;
    if (!host) return;
    SGRPopularityBadge *badge = badgeFor(host);
    restoreSourceLabels();

    UIView *close = SGRFindByIdentifier(host, @"now-playing-minimize-button", NULL);
    if (!close) close = SGRFindByIdentifier(host, @"mobile-nowplaying-close-button", NULL);
    UIView *more = SGRFindByIdentifier(host, @"Context menu", NULL);
    CGFloat left = close ? CGRectGetMaxX([close convertRect:close.bounds toView:host]) : 0;
    CGFloat right = more ? CGRectGetMinX([more convertRect:more.bounds toView:host]) : CGRectGetMaxX(host.bounds);
    if (popularityEnabled()) {
        if (!sg_sourceLabels) sg_sourceLabels = [NSHashTable weakObjectsHashTable];
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        collectCenterLabels(host, host, left, right, labels);
        for (UILabel *label in labels) {
            objc_setAssociatedObject(label, &kSourceAlphaKey, @(label.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [sg_sourceLabels addObject:label];
            label.alpha = 0; // Keep its hit-test hierarchy and Spotify's surrounding stack untouched.
        }
    }

    NSNumber *value = sg_popularityValue;
    badge.number.text = value ? value.stringValue : nil;
    badge.accessibilityLabel = value ? [NSString stringWithFormat:@"인기도 %@", value] : nil;
    CGFloat width = 7 + 12 + 4 + ceil([badge.number sizeThatFits:CGSizeMake(CGFLOAT_MAX, 22)].width) + 7;
    CGFloat x = (CGRectGetWidth(host.bounds) - width) / 2;
    CGFloat y = (CGRectGetHeight(host.bounds) - 22) / 2;
    BOOL fits = popularityEnabled() && value && left <= x && x + width <= right && y >= CGRectGetMinY(host.bounds) && y + 22 <= CGRectGetMaxY(host.bounds);
    badge.frame = CGRectMake(x, y, width, 22);
    badge.hidden = !fits;
    if (!SGRPlayerLyricsFadeView(badge, fits)) badge.alpha = 1;
}

static BOOL validSpotifyTrackURI(NSString *uri) {
    return [uri hasPrefix:@"spotify:track:"] && uri.length > [@"spotify:track:" length];
}

static void requestPopularityForCurrentTrack(void) {
    if (!popularityEnabled()) return;
    NSString *uri = SGURIString(SGPlayerState().track.URI);
    if (!validSpotifyTrackURI(uri)) return;
    sg_popularityTrack = [uri copy];
    sg_popularityValue = nil;
    NSUInteger generation = ++sg_popularityGeneration;
    layoutPopularityBadge();
    SGTrackPopularityRequest(uri, ^(NSNumber *value) {
        if (generation != sg_popularityGeneration || ![sg_popularityTrack isEqualToString:uri] || !popularityEnabled()) return;
        sg_popularityValue = value;
        layoutPopularityBadge();
    });
}

void SGRPlayerPopularitySettingsChanged(void) {
    dispatch_block_t update = ^{
        if (!popularityEnabled()) {
            ++sg_popularityGeneration;
            sg_popularityValue = nil;
            SGTrackPopularityCancel();
            layoutPopularityBadge();
        } else {
            requestPopularityForCurrentTrack();
        }
        SGRTrackPopularityRowsChanged();
    };
    if (NSThread.isMainThread) update();
    else dispatch_async(dispatch_get_main_queue(), update);
}

@interface SGRPlayerPopularityWatcher : NSObject <SGPlayerStateObserver>
@end
@implementation SGRPlayerPopularityWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    NSString *uri = SGURIString(state.track.URI);
    if ((uri == sg_popularityTrack) || [uri isEqualToString:sg_popularityTrack]) return;
    sg_popularityTrack = [uri copy];
    sg_popularityValue = nil;
    NSUInteger generation = ++sg_popularityGeneration;
    layoutPopularityBadge();
    if (!popularityEnabled() || !validSpotifyTrackURI(uri)) return;
    SGTrackPopularityRequest(uri, ^(NSNumber *value) {
        if (generation != sg_popularityGeneration || ![sg_popularityTrack isEqualToString:uri] || !popularityEnabled()) return;
        sg_popularityValue = value;
        layoutPopularityBadge();
    });
}
@end

%hook _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLayoutSubviews {
    %orig;
    sg_popularityHost = ((UIViewController *)self).viewIfLoaded;
    layoutPopularityBadge();
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    sg_popularityWatcher = [SGRPlayerPopularityWatcher new];
    SGAddPlayerStateObserver(sg_popularityWatcher);
    SPTPlayerState *state = SGPlayerState();
    if (state && popularityEnabled()) [sg_popularityWatcher playerStateDidChange:state];
}
