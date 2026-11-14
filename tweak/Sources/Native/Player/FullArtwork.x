// Native player's optional full-screen moving artwork and static-cover fallback.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "NowPlaying.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SGLastTrack.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import <AVFoundation/AVFoundation.h>

@class SGNativeFullArtwork;
static __weak SGNativeFullArtwork *sg_fullArtwork;
static NSHashTable<UIView *> *sg_frontArtwork;
static char kFullArtworkKey, kOriginalAlphaKey, kVideoReady;
static void updateFrontArtwork(BOOL showing) {
    for (UIView *view in sg_frontArtwork.allObjects) {
        NSNumber *before = objc_getAssociatedObject(view, &kOriginalAlphaKey);
        if (showing) {
            if (!before) objc_setAssociatedObject(view, &kOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            view.alpha = 0;
        } else if (before) {
            view.alpha = before.doubleValue;
            objc_setAssociatedObject(view, &kOriginalAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}
@interface SGNativeFullArtwork : UIView <SGPlayerStateObserver>
- (void)refresh;
@end
@implementation SGNativeFullArtwork {
    UIImageView *_picture;
    CAGradientLayer *_shade;
    AVPlayerLayer *_video;
    AVQueuePlayer *_player;
    AVPlayerLooper *_looper;
    SGMotionFollower *_follower;
    NSString *_track, *_artworkURL;
    NSURL *_file;
    NSMutableArray *_tokens;
    BOOL _staticOn, _fillOn;
    NSUInteger _videoTurn;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityIdentifier = @"vitrine.full-artwork.native";
    _picture = [[UIImageView alloc] initWithFrame:self.bounds];
    _picture.contentMode = UIViewContentModeScaleAspectFill; _picture.clipsToBounds = YES;
    [self addSubview:_picture]; _video = [AVPlayerLayer layer];
    _video.videoGravity = AVLayerVideoGravityResizeAspectFill; [_picture.layer addSublayer:_video];
    [_video addObserver:self forKeyPath:@"readyForDisplay" options:NSKeyValueObservingOptionNew context:&kVideoReady];
    _shade = [CAGradientLayer layer];
    _shade.colors = @[(id)[UIColor colorWithWhite:0 alpha:0.12].CGColor,
                      (id)[UIColor colorWithWhite:0 alpha:0.20].CGColor,
                      (id)[UIColor colorWithWhite:0 alpha:0.68].CGColor];
    _shade.locations = @[@0, @0.5, @1]; [self.layer addSublayer:_shade];
    __weak typeof(self) weakSelf = self;
    _follower = [[SGMotionFollower alloc] initWithBegin:^BOOL(NSString *uri, SPTPlayerState *state) {
        SGNativeFullArtwork *view = weakSelf;
        [view refresh];
        return view.window && SGFlag(SGKeyPlayerFillArtwork, NO);
    } found:^(NSString *uri, NSURL *file) {
        SGNativeFullArtwork *view = weakSelf;
        if (!view) return;
        [view refresh];
        if (![view->_track isEqualToString:uri] || !SGFlag(SGKeyPlayerFillArtwork, NO)) return;
        if (![view->_file isEqual:file] || (file && !view->_player)) {
            [view->_looper disableLooping]; [view->_player pause];
            view->_file = file;
            view->_player = file ? [AVQueuePlayer new] : nil;
            view->_player.muted = YES; view->_player.preventsDisplaySleepDuringVideoPlayback = NO;
            view->_looper = file ? [AVPlayerLooper playerLooperWithPlayer:view->_player templateItem:[AVPlayerItem playerItemWithURL:file]] : nil;
            view->_video.player = view->_player;
            NSUInteger turn = ++view->_videoTurn;
            if (file) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                SGNativeFullArtwork *current = weakSelf;
                if (!current || current->_videoTurn != turn || current->_video.readyForDisplay) return;
                if (!current.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
                [current->_looper disableLooping]; [current->_player pause];
                current->_looper = nil; current->_player = nil; current->_video.player = nil;
                [current refresh];
            });
        }
        [view refresh];
    }];
    _tokens = [NSMutableArray array];
    for (NSNotificationName name in @[NSUserDefaultsDidChangeNotification, UIApplicationDidBecomeActiveNotification,
                                      UIApplicationWillResignActiveNotification, UIApplicationDidEnterBackgroundNotification, UIAccessibilityReduceMotionStatusDidChangeNotification,
                                      NSProcessInfoPowerStateDidChangeNotification]) {
        [_tokens addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
        }]];
    }
    SGAddPlayerStateObserver(self); return self;
}
- (void)dealloc {
    [_video removeObserver:self forKeyPath:@"readyForDisplay" context:&kVideoReady];
    [_looper disableLooping]; [_player pause];
    for (id token in _tokens) [NSNotificationCenter.defaultCenter removeObserver:token];
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &kVideoReady) { [super observeValueForKeyPath:keyPath ofObject:object change:change context:context]; return; }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
}
- (void)playerStateDidChange:(SPTPlayerState *)state { [self refresh]; }
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) sg_fullArtwork = self;
    [self refresh]; if (self.window) [_follower restart];
}
- (void)refresh {
    BOOL staticOn = SGFlag(SGKeyPlayerStaticCover, NO), fillOn = SGFlag(SGKeyPlayerFillArtwork, NO);
    BOOL changed = staticOn != _staticOn || fillOn != _fillOn;
    _staticOn = staticOn; _fillOn = fillOn;
    SGShownTrack *track = SGShownTrackNow();
    NSString *uri = track.current ? track.uri : nil;
    if (![_track isEqualToString:uri]) {
        _track = [uri copy]; _artworkURL = nil; _picture.image = nil; _file = nil; ++_videoTurn;
        [_looper disableLooping]; [_player pause]; _looper = nil; _player = nil; _video.player = nil;
    }
    if (changed) {
        _artworkURL = nil;
        if (!fillOn) { ++_videoTurn; [_looper disableLooping]; [_player pause]; _looper = nil; _player = nil; _file = nil; _video.player = nil; }
        // Queue a restart so the follower's begin callback cannot re-enter its own walk.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            SGNativeFullArtwork *view = weakSelf;
            if (view) [view->_follower restart];
        });
    }
    NSString *url = track.artworkURL.absoluteString;
    if ((staticOn || fillOn) && uri && url && ![_artworkURL isEqualToString:url]) {
        _artworkURL = [url copy]; NSString *requested = [uri copy];
        __weak typeof(self) weakSelf = self;
        SGShownTrackArtwork(track, ^(UIImage *image) {
            SGNativeFullArtwork *view = weakSelf;
            if (!view) return;
            if (![view->_track isEqualToString:requested]) return;
            view->_picture.image = image; [view refresh];
        });
    }
    BOOL active = self.window && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL animate = active && fillOn && !SGPlayerState().isPaused && !UIAccessibilityIsReduceMotionEnabled() && !NSProcessInfo.processInfo.lowPowerModeEnabled;
    // Decode the first video frame even when motion is reduced, then leave that frame still.
    if (active && fillOn && (animate || !_video.readyForDisplay)) [_player play]; else [_player pause];
    BOOL videoReady = fillOn && _video.readyForDisplay;
    BOOL stillReady = staticOn && _picture.image && (fillOn || !track.canvasURL);
    BOOL showing = self.window && uri && (videoReady || stillReady);
    self.hidden = !showing;
    if (sg_fullArtwork == self) updateFrontArtwork(showing);
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = MAX(self.bounds.size.height, self.window.bounds.size.height);
    _picture.frame = CGRectMake(0, 0, self.bounds.size.width, height);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _video.frame = _picture.bounds; _shade.frame = _picture.frame; [CATransaction commit];
}
@end

UIViewController *SGNativeArtworkSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Artwork background" intro:@"Choose how artwork fills the player."
        sections:@[SGSection(@"Background", @[
            SGOptionRow(@"Blurred artwork background", nil, SGKeyPlayerBackdrop),
            SGOptionRow(@"Static cover fallback", @"Use a full-screen album cover when motion artwork is unavailable", SGKeyPlayerStaticCover),
            SGOptionRow(@"Fill artwork to bottom", @"Show moving artwork across the full screen behind the controls", SGKeyPlayerFillArtwork),
        ])] footer:@"Full-screen artwork keeps its proportions and may crop the sides. A dark gradient keeps text readable. Missing motion artwork can use the album cover when Static cover fallback is enabled."];
}

static void rememberFront(UIView *view) {
    if (view.bounds.size.width < 200) return;
    BOOL onPlayer = NO;
    for (UIResponder *responder = view; responder; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class] && [NSStringFromClass(responder.class) containsString:@"NowPlaying_"]) { onPlayer = YES; break; }
        if ([responder isKindOfClass:UIView.class] && [((UIView *)responder).accessibilityIdentifier isEqualToString:@"scrolling_npv_collection_view_accessibility_identifier"]) { onPlayer = YES; break; }
    }
    if (!onPlayer) return;
    if (!sg_frontArtwork) sg_frontArtwork = [NSHashTable weakObjectsHashTable];
    [sg_frontArtwork addObject:view];
    [sg_fullArtwork refresh];
}
%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *plane = ((UIViewController *)self).viewIfLoaded;
    if (!plane || plane.bounds.size.height < 200) return;
    SGNativeFullArtwork *view = objc_getAssociatedObject(plane, &kFullArtworkKey);
    if (!view && (SGFlag(SGKeyPlayerStaticCover, NO) || SGFlag(SGKeyPlayerFillArtwork, NO))) {
        view = [[SGNativeFullArtwork alloc] initWithFrame:plane.bounds];
        objc_setAssociatedObject(plane, &kFullArtworkKey, view, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!view) return;
    if (plane.window) sg_fullArtwork = view;
    if (view.superview != plane) [plane addSubview:view];
    else [plane bringSubviewToFront:view];
    view.frame = plane.bounds; [view refresh];
}
%end
%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews { %orig; rememberFront((UIView *)self); }
%end
%hook _TtC17Canvas_PlayerImpl16CanvasPlayerView
- (void)layoutSubviews { %orig; rememberFront((UIView *)self); }
%end
%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController", @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView"]);
}
