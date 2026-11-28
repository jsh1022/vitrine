// The redesign's Player page in Mod Settings (App/Pages.m opens it in place of the native look's).
//
// It leads with a card of the player as the now playing track shows on it: the background chosen on the
// page edge to edge, and over its foot the cover, the title and the artist (gliding when too long) and how
// far the track has played. The progress is where the track was when the page appeared. With no track, the
// card shows the last one played (Shared/Player/SGLastTrack.h), its cover fetched and its Canvas looked up
// as the playing one's would be, and with none ever played, Not Playing over a gradient of the accent.
//
// The background is the player's own: a field of the same kind (Still, Colors, Fluid), for Animated
// the clip the player is playing (SGRPlayerMotionPreview) in place of the field, or, while the player has
// none, the playing track's clip looked up for the card while it is on screen, Fluid until it comes in and
// for a track with none, as in the player; the clip crosses over the field as it arrives, its poster first
// while its video decodes. And for Visualizer the hills over Fluid held still (SGRPlayerVisualiserPreview),
// moving with the song. It moves under the field's own conditions (in a window, Spotify in front, Reduce
// Motion and Low Power Mode off). Under the card a segmented control picks the background, all five of
// them: the names are one word each, each segment as wide as its name, so they fit side by side at an iPhone's
// width, and every choice stays one tap away with the card showing it at once. A note under the control says what the
// choice does; it is given the room of the longest note, so the rows under it hold still as it changes.
//
// Under the header: the rows that follow the choice (Animated's sources and its Low Data Mode switch; Fluid's
// five sliders and their Reset, which the card and the player follow as they move, SGRFluid.h), the Mini
// player section (Redesigned/NowPlayingBar/NowPlayingBarSettings.m), then the sections either look shares.
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRFluid.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Player/SGLastTrack.h"
#import "Player.h"
#import "PlayerHistory.h"

// The card's height as a share of its width, kept between the two bounds.
static const CGFloat kCardAspect = 0.5, kCardMinHeight = 168, kCardMaxHeight = 220;
static const CGFloat kCardRadius = 26;   // continuous, the radius of the page's own cards and then some
static const CGFloat kCardPadding = 16, kCoverSide = 64;

// What each background does, in SGRPlayerBackgroundKind's order.
static NSArray<NSString *> *backgroundNotes(void) {
    return @[
        @"커버를 흐리게 표시하고 움직이지 않습니다.",
        @"커버의 색상이 천천히 움직입니다.",
        @"커버를 흐리게 표시하고 천천히 회전합니다. 일시정지하면 멈춥니다.",
        @"곡의 Canvas 또는 움직이는 앨범 커버를 사용합니다. 없으면 유동 배경을 표시합니다. 플레이어의 ⋯ 메뉴에서 유동 배경, 애니메이션, 시각화를 전환할 수 있습니다.",
        @"정지된 유동 배경 위에 커버 색상의 부드러운 물결로 소리를 표현합니다. 일시정지하면 잦아듭니다.",
    ];
}

@interface SGRPlayerShowcase : UIView <SGPlayerStateObserver>
- (void)reloadTrack;
- (void)reloadBackgroundAnimated:(BOOL)animated;
@end

@implementation SGRPlayerShowcase {
    SGRArtworkField *_field;
    UIView *_motion, *_visualiser;
    UIImageView *_cover;
    SGMarqueeLabel *_title, *_artist;
    UIView *_progress, *_progressFill;
    CGFloat _position;
    NSString *_artworkOf;   // the last track whose cover the card asked for
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.clipsToBounds = YES;
    self.layer.cornerRadius = kCardRadius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.backgroundColor = SGRNeutralField();
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitImage;
    self.accessibilityLabel = @"플레이어 미리보기";

    _field = [[SGRArtworkField alloc] initWithFrame:frame];
    _field.showsBackdrop = YES;
    [self addSubview:_field];

    _cover = [UIImageView new];
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    _cover.clipsToBounds = YES;
    _cover.layer.cornerRadius = 8;
    _cover.layer.cornerCurve = kCACornerCurveContinuous;
    _cover.tintColor = SGRTertiary();
    _cover.backgroundColor = SGRSolidGlassFill();
    _cover.preferredSymbolConfiguration = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
    [self addSubview:_cover];

    // The card reads as one image; the words glide as the player's own do.
    _title = [SGMarqueeLabel new];
    _title.textColor = SGRPrimary();
    _title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _title.isAccessibilityElement = NO;
    [self addSubview:_title];
    _artist = [SGMarqueeLabel new];
    _artist.textColor = SGRSecondary();
    _artist.font = [UIFont systemFontOfSize:15];
    _artist.isAccessibilityElement = NO;
    [self addSubview:_artist];

    // The player's slider as it is drawn at rest: a track, and in it a fill up to where the song is.
    _progress = [UIView new];
    _progress.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    _progress.clipsToBounds = YES;
    _progressFill = [UIView new];
    _progressFill.backgroundColor = SGRPrimary();
    [_progress addSubview:_progressFill];
    [self addSubview:_progress];

    SGAddPlayerStateObserver(self);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    [self reloadTrack];
    [self reloadBackgroundAnimated:NO];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)playerStateDidChange:(SPTPlayerState *)state {
    [self reloadTrack];
}

- (void)artworkChanged {
    NSString *identity = nil;
    UIImage *image = SGRNowPlayingArtwork(NULL, &identity);
    if (image) [self showArtwork:image identity:identity];
}

// The cover and the field from `image`, or from the placeholder for nil.
- (void)showArtwork:(UIImage *)image identity:(NSString *)identity {
    static UIImage *placeholder;
    static UIColor *tint;
    if (!image && (!placeholder || ![tint isEqual:SGGreen()])) {
        tint = SGGreen();
        placeholder = SGPlaceholderArtwork(tint);
    }
    _cover.image = image ?: placeholder;
    _cover.contentMode = UIViewContentModeScaleAspectFill;
    [_field setArtwork:_cover.image identity:image ? identity : @"placeholder" animated:self.window != nil];
}

// The track, where it is and whether it plays, read again.
- (void)reloadTrack {
    SPTPlayerState *state = SGPlayerState();
    SGShownTrack *shown = SGShownTrackNow();
    _title.text = shown.title ?: @"재생 중이 아님";
    _artist.text = shown.artist ?: @"";
    _position = shown.current && state.duration > 0 ? MIN(1, MAX(0, state.position / state.duration)) : 0;
    // The clip covers the field, and the hills move over it, which then holds still, as in the player.
    _field.motionHeld = state.isPaused || _motion != nil || _visualiser != nil;
    if (shown.current && SGRNowPlayingArtwork(NULL, NULL)) {
        [self artworkChanged];
    } else if (!shown.current && shown.artworkURL) {
        // The last track's cover, the placeholder until it comes.
        NSString *uri = shown.uri;
        if (![_artworkOf isEqualToString:uri]) [self showArtwork:nil identity:nil];
        _artworkOf = uri;
        __weak SGRPlayerShowcase *weakSelf = self;
        SGShownTrackArtwork(shown, ^(UIImage *image) {
            SGRPlayerShowcase *showcase = weakSelf;
            SGShownTrack *now = SGShownTrackNow();
            if (image && !now.current && [now.uri isEqualToString:uri]) [showcase showArtwork:image identity:[@"last:" stringByAppendingString:uri]];
        });
    } else {
        // Nothing ever played, or the playing track's cover still coming.
        _artworkOf = nil;
        [self showArtwork:nil identity:nil];
    }
    [self setNeedsLayout];
}

// The card on screen with Animated and no clip in it: one is looked up, and shown once it is in.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && !_motion && SGRPlayerBackground() == SGRPlayerBackgroundAnimated) [self reloadBackgroundAnimated:NO];
}

// The background chosen, read again; a new one crosses over when animated. The clip is the one playing, or
// looked up, when this is called: a track changed while the page shows keeps the last one until the page
// appears again. A clip is looked up only while the card is in a window.
- (void)reloadBackgroundAnimated:(BOOL)animated {
    SGRPlayerBackgroundKind kind = SGRPlayerBackground();
    __weak SGRPlayerShowcase *weakSelf = self;
    void (^arrived)(void) = !self.window ? nil : ^{
        SGRPlayerShowcase *showcase = weakSelf;
        if (showcase.window && !showcase->_motion && SGRPlayerBackground() == SGRPlayerBackgroundAnimated) [showcase reloadBackgroundAnimated:YES];
    };
    void (^apply)(void) = ^{
        self->_field.flows = kind == SGRPlayerBackgroundColours;
        self->_field.fluid = kind >= SGRPlayerBackgroundFluid;
        [self->_motion removeFromSuperview];
        self->_motion = kind == SGRPlayerBackgroundAnimated ? SGRPlayerMotionPreview(arrived) : nil;
        if (self->_motion) [self insertSubview:self->_motion aboveSubview:self->_field];
        [self->_visualiser removeFromSuperview];
        self->_visualiser = kind == SGRPlayerBackgroundVisualiser ? SGRPlayerVisualiserPreview() : nil;
        if (self->_visualiser) [self insertSubview:self->_visualiser aboveSubview:self->_field];
        self->_field.motionHeld = SGPlayerState().isPaused || self->_motion != nil || self->_visualiser != nil;
    };
    self.accessibilityValue = [SGRPlayerBackgroundNames()[(NSUInteger)kind] stringByAppendingString:@" background"];
    if (animated && self.window) {
        // A crossfade, which Reduce Motion keeps: nothing moves.
        [UIView transitionWithView:self duration:SGRCrossfade options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionAllowAnimatedContent
                        animations:apply completion:nil];
    } else {
        apply();
    }
    [self setNeedsLayout];
}

// The clip runs from the card's top at its width, as in the player, and its blur comes in from the
// seam under the controls, which on a card this short is over its foot, under the words.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat w = bounds.size.width, h = bounds.size.height;
    _field.frame = bounds;
    _field.backdropHeight = h;
    _motion.frame = bounds;
    _visualiser.frame = bounds;

    _cover.frame = CGRectMake(kCardPadding, h - kCardPadding - kCoverSide, kCoverSide, kCoverSide);
    CGFloat x = CGRectGetMaxX(_cover.frame) + 12, width = w - kCardPadding - x;
    CGFloat line = 4, titleHeight = ceil(_title.font.lineHeight), artistHeight = ceil(_artist.font.lineHeight);
    CGFloat bottom = CGRectGetMaxY(_cover.frame);
    _progress.frame = CGRectMake(x, bottom - line - 2, width, line);
    _progress.layer.cornerRadius = line / 2;
    _progressFill.frame = CGRectMake(0, 0, round(width * _position), line);
    CGFloat textBottom = CGRectGetMinY(_progress.frame) - 10;
    _artist.frame = CGRectMake(x, textBottom - artistHeight, width, artistHeight);
    _title.frame = CGRectMake(x, CGRectGetMinY(_artist.frame) - titleHeight, width, titleHeight);
}

@end

#pragma mark - the page

@interface SGRPlayerPage : SGModPage
@property (nonatomic, strong) SGRPlayerShowcase *showcase;
@property (nonatomic, strong) UISegmentedControl *backgrounds;
@end

@implementation SGRPlayerPage {
    UIView *_header;
    UILabel *_note;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _header = [UIView new];
    [_header addSubview:self.showcase];
    [_header addSubview:self.backgrounds];
    _note = [UILabel new];
    _note.font = SGSubtitleFont();
    _note.textColor = SGGrey();
    _note.numberOfLines = 0;
    [_header addSubview:_note];
    [self showNote];
    self.tableView.tableHeaderView = _header;
}

- (void)showNote {
    _note.text = backgroundNotes()[(NSUInteger)SGRPlayerBackground()];
    [self.view setNeedsLayout];
}

// The header keeps the height it is given, so it is sized here and given back to the table only when that
// changes (a table header set on every pass lays the table out again forever). The note's room is that of
// the longest note at this width, so picking a background never moves the rows.
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    _note.font = SGSubtitleFont();
    CGFloat width = table.bounds.size.width, inset = table.layoutMargins.left;
    CGFloat cardWidth = width - 2 * inset;
    CGFloat cardHeight = round(MIN(kCardMaxHeight, MAX(kCardMinHeight, cardWidth * kCardAspect)));
    self.showcase.frame = CGRectMake(inset, 16, cardWidth, cardHeight);
    CGFloat controlHeight = MAX(32, ceil([self.backgrounds sizeThatFits:CGSizeMake(cardWidth, CGFLOAT_MAX)].height));
    self.backgrounds.frame = CGRectMake(inset, CGRectGetMaxY(self.showcase.frame) + 12, cardWidth, controlHeight);

    CGFloat noteWidth = cardWidth - 2 * 4, room = 0;
    UILabel *measure = [UILabel new];
    measure.font = _note.font;
    measure.numberOfLines = 0;
    for (NSString *text in backgroundNotes()) {
        measure.text = text;
        room = MAX(room, ceil([measure sizeThatFits:CGSizeMake(noteWidth, CGFLOAT_MAX)].height));
    }
    CGFloat noteHeight = ceil([_note sizeThatFits:CGSizeMake(noteWidth, CGFLOAT_MAX)].height);
    CGFloat noteTop = CGRectGetMaxY(self.backgrounds.frame) + 8;
    _note.frame = CGRectMake(inset + 4, noteTop, noteWidth, noteHeight);
    CGSize size = CGSizeMake(width, noteTop + room);
    if (CGSizeEqualToSize(_header.bounds.size, size)) return;
    _header.frame = (CGRect){CGPointZero, size};
    table.tableHeaderView = _header;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The player's ⋯ menu can switch Animated and Fluid while the page is away.
    self.backgrounds.selectedSegmentIndex = SGRPlayerBackground();
    [self showNote];
    [self.showcase reloadTrack];
    [self.showcase reloadBackgroundAnimated:NO];
}

- (void)backgroundPicked {
    SGSetInt(SGRKeyPlayerBackground, self.backgrounds.selectedSegmentIndex);
    [self.showcase reloadBackgroundAnimated:YES];
    [self showNote];
    [self refreshVisibility];
}

@end

// One of Fluid's settings on a slider, written out with `unit` after the number.
static SGModRow *fluidSlider(NSString *title, SGRFluidSetting setting, NSString *unit) {
    SGRFluidLimits l = SGRFluidLimitsOf(setting);
    return SGSliderRow(title, nil, l.least, l.most, l.step, ^double { return SGRFluidValue(setting); },
                       ^(double value) { SGRSetFluidValue(setting, lround(value)); },
                       ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%@", value, unit]; });
}

SGModRow *SGRLyricsHideRow(void) {
    SGModRow *row = SGChoiceRow(@"컨트롤 숨기기", @"마지막 터치 후 몇 초가 지나면 가사가 화면을 채웁니다",
                                SGRKeyLyricsAutoHide, @[@"꺼짐", @"모두", @"제목 유지"], SGRLyricsHideMode());
    row.choiceNotes = @[@"컨트롤 유지", @"가사가 플레이어 전체를 채웁니다", @"커버, 제목, 상단 행을 유지합니다. 가로 화면에서는 제목을 유지합니다"];
    return row;
}

UIViewController *SGRPlayerSettingsPage(NSArray *more) {
    SGRPlayerShowcase *showcase = [[SGRPlayerShowcase alloc] initWithFrame:CGRectMake(0, 0, 320, kCardMinHeight)];
    UISegmentedControl *backgrounds = [[UISegmentedControl alloc] initWithItems:SGRPlayerBackgroundNames()];
    backgrounds.selectedSegmentIndex = SGRPlayerBackground();
    backgrounds.accessibilityLabel = @"배경";
    backgrounds.apportionsSegmentWidthsByContent = YES;

    SGModRow *lowData = SGOptionRow(@"저데이터 모드에서 다운로드", @"곡당 최대 약 7 MB", SGKeyMotionLowData);
    lowData.visible = ^BOOL { return SGRPlayerBackground() == SGRPlayerBackgroundAnimated; };
    SGModRow *popularity = SGOptionRow(@"곡 인기도 표시", @"트랙 목록과 재생화면 상단에 불꽃 아이콘과 인기도를 표시합니다", SGRKeyPlayerPopularity);
    popularity.defaultOn = YES;
    popularity.changed = ^(BOOL on) { SGRPlayerPopularitySettingsChanged(); };
    SGModRow *sources = SGMotionSourcesRow();
    sources.visible = lowData.visible;

    __block __weak UITableViewController *weakPage;
    SGModRow *reset = SGActionRow(@"초기화", nil, ^{
        SGRResetFluidSettings();
        [weakPage.tableView reloadData];   // the sliders at once, rather than at the page's next tick
    });
    reset.color = SGRed();
    NSArray<SGModRow *> *fluid = @[
        fluidSlider(@"속도", SGRFluidSpeed, @"%"), fluidSlider(@"왜곡", SGRFluidWarp, @"%"), fluidSlider(@"흐림", SGRFluidBlur, @""),
        fluidSlider(@"채도", SGRFluidSaturation, @"%"), fluidSlider(@"밝기", SGRFluidBrightness, @"%"), reset,
    ];
    for (SGModRow *row in fluid) row.visible = ^BOOL { return SGRPlayerBackground() == SGRPlayerBackgroundFluid; };

    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObjects:
        SGSection(nil, @[sources, lowData]),
        SGNotedSection(@"아트워크 배치", @[
            SGOptionRow(@"정지 커버 대체", @"움직이는 아트워크가 없으면 전체 화면 앨범 커버를 사용합니다", SGRKeyPlayerStaticCover),
            SGOptionRow(@"하단까지 아트워크 채우기", @"컨트롤 뒤 전체 화면을 채우도록 움직이는 아트워크를 잘라 표시합니다", SGRKeyPlayerFillArtwork),
        ], @"앨범 커버의 비율을 유지하며 양옆이 잘릴 수 있습니다. 어두운 그라데이션으로 컨트롤의 가독성을 유지합니다."),
        SGNotedSection(nil, fluid, @"밝기가 100%를 넘으면 흰색 글자를 읽기 어려울 수 있습니다. 일시정지하면 배경이 멈춥니다. 애니메이션과 시각화의 유동 배경에도 이 설정을 사용합니다."),
        SGNotedSection(@"컨트롤", @[SGSwitchRow(@"음량", nil, SGRKeyPlayerVolume),
                                      popularity,
                                      SGOptionRow(@"커버 색상 따르기", nil, SGRKeyPlayerFollowsCover),
                                      SGOptionRow(@"Spotify 아이콘", @"가사, 기기, 대기열 및 AI DJ 버튼", SGRKeyPlayerSpotifyIcons)],
                       @"음량 슬라이더를 컨트롤 아래에 표시합니다. 이 iPhone 또는 Spotify가 재생 중인 다른 기기의 음량을 조절합니다. 커버 색상 따르기는 좋아요, 셔플, 반복, 기기, 대기열 버튼과 미니플레이어의 기기·좋아요 버튼에 현재 곡의 커버 색상을 적용합니다. Spotify 아이콘은 컨트롤 아래 행에 Music 앱 대신 Spotify의 아이콘을 사용합니다."),
        SGNotedSection(@"재생 대기 목록", @[
            SGOptionRow(@"이전 재생 목록 표시", @"기존 대기열의 현재 곡 위에 이전에 재생한 곡을 표시합니다", SGRKeyPlayerHistory),
        ], @"Spotify가 제공하는 이전 곡 중 최근 25곡까지 표시합니다. 이전 곡을 누르면 해당 곡을 다시 재생합니다. 끄면 원래 대기열로 돌아갑니다."),
        SGNotedSection(@"미니플레이어", SGRNowPlayingBarRows(),
                       @"Apple Music 스타일은 아래로 스크롤할 때 미니플레이어를 두 탭 사이로 이동합니다."), nil];
    [sections addObjectsFromArray:more];
    // Fluid, Animated and Visualizer share the field (PlayerMotion.x reads the choice on every track, PlayerVisualiser.m
    // on the field's layout); Still and Colors are a field of another kind, made once a launch (PlayerField.x).
    NSString *footer = @"유동 배경, 애니메이션, 시각화는 다음 곡부터 바뀝니다. 정지, 색상, 플레이어 숨김 및 Spotify 아이콘은 Spotify 재시작 후 적용됩니다.";
    SGRPlayerPage *page = [[SGRPlayerPage alloc] initWithTitle:@"플레이어" intro:nil sections:sections footer:footer];
    weakPage = page;
    page.showcase = showcase;
    page.backgrounds = backgrounds;
    [backgrounds addTarget:page action:@selector(backgroundPicked) forControlEvents:UIControlEventValueChanged];
    return page;
}
