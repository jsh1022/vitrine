// Spotify's inline preview does not consume Vitrine's cached source lines or corrected clock.
// Keep its layout and visibility policy, but refresh its text from the shared timed lyrics engine.
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"

@interface SGRInlineLyrics : NSObject
@property(nonatomic, weak) UIView *host;
@property(nonatomic, strong) NSTimer *timer;
- (void)refresh;
@end
@implementation SGRInlineLyrics
- (void)dealloc { [_timer invalidate]; }
- (void)refresh {
    UIView *host = self.host;
    if (!host.window) { [self.timer invalidate]; self.timer = nil; return; }
    if (!self.timer) {
        __weak typeof(self) weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) { [weakSelf refresh]; }];
        self.timer.tolerance = 0.02;
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
    NSString *track = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = track.length ? SGKaraokeLinesForTrack(track) : nil;
    if (!lines.count) return;
    NSInteger position = SGKaraokePositionMs();
    NSInteger index = position < 0 ? -1 : SGKaraokeLeadLine(lines, position - SGKaraokeDelayMs());
    NSString *text = index >= 0 && index < (NSInteger)lines.count ? SGKaraokeLineText(lines[index]) : @"";
    // Untimed lyrics cannot be synchronized; never present them as the current line.
    if (index >= 0 && index < (NSInteger)lines.count && lines[index].timing == SGKaraokeTimingNone) text = @"";
    SGForEachView(host, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)view;
        if (![label.text isEqualToString:text]) label.text = text;
    });
}
@end
static char kInlineKey;
static void refreshInline(UIView *host) {
    SGRInlineLyrics *reader = objc_getAssociatedObject(host, &kInlineKey);
    if (!reader) {
        reader = [SGRInlineLyrics new]; reader.host = host;
        objc_setAssociatedObject(host, &kInlineKey, reader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [reader refresh];
}
%hook _TtC22Lyrics_NPVContainerKit19LyricsContainerView
- (void)layoutSubviews { %orig; refreshInline((UIView *)self); }
- (void)didMoveToWindow { %orig; refreshInline((UIView *)self); }
%end
%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[@"_TtC22Lyrics_NPVContainerKit19LyricsContainerView"]);
}
