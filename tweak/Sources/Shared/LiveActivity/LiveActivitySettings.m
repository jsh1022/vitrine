// The Live Activity page (App/ModSettings.x links it from the root, under either look): the preview at its top
// (SGLiveActivityPreview.m), then the switch, the view and the card's options, which the tick reads, so they
// apply at once to a card that is showing.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Player/SleepTimer.h"
#import "LiveActivity.h"
#import "SGLiveActivityPreview.h"

static NSArray<NSString *> *viewNames(void) {
    return @[@"가사", @"대기열", @"컨트롤 메뉴"];
}

@interface SGLiveActivityPage : SGModPage
@property (nonatomic, strong) SGLiveActivityPreview *preview;
@end

@implementation SGLiveActivityPage

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableHeaderView = self.preview;
}

// Handed back to the table only when its size changes (SGFitNote's way: the table lays out again on every handing back).
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    CGFloat width = table.bounds.size.width;
    self.preview.layoutMargins = UIEdgeInsetsMake(0, table.layoutMargins.left, 0, table.layoutMargins.right);
    CGSize size = CGSizeMake(width, [self.preview heightForWidth:width]);
    if (CGSizeEqualToSize(self.preview.bounds.size, size)) return;
    self.preview.frame = (CGRect){CGPointZero, size};
    table.tableHeaderView = self.preview;
}

// Back from Shows' or Text size's list, the preview reads them again.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.preview reload];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.preview.running = YES;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.preview.running = NO;
}

@end

// A menu row of `names` stored under `key`, which shows the preview the new choice.
static SGModRow *menuRow(NSString *title, NSString *key, NSArray<NSString *> *names, NSInteger fallback, SGLiveActivityPreview *preview) {
    __weak SGLiveActivityPreview *weakPreview = preview;
    return SGMenuRow(title, names, ^NSString *{
        NSInteger index = SGInt(key, fallback);
        return names[(NSUInteger)(index >= 0 && index < (NSInteger)names.count ? index : fallback)];
    }, ^(NSInteger index) {
        SGSetInt(key, index);
        [weakPreview reload];
    });
}

BOOL SGLiveActivityAllowedByInstall(void) {
    return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"NSSupportsLiveActivities"] boolValue];
}

// At the top while the install lacks the key, saying why nothing shows and what to do.
static SGModRow *missingRow(void) {
    SGModRow *row = SGWarningRow(@"이 설치에 포함되지 않음", @"탭하여 이유 확인", ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Live Activity 기능이 없습니다"
            message:@"iOS는 지원을 선언한 앱에만 Live Activity를 표시합니다. Vitrine IPA 빌드만 Spotify에 해당 선언을 추가합니다. 이 설치에는 선언이 없어 카드를 표시하지 못합니다. Vitrine으로 IPA를 빌드하세요."
            preferredStyle:UIAlertControllerStyleAlert];
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    });
    row.visible = ^BOOL { return !SGLiveActivityAllowedByInstall(); };
    return row;
}

UIViewController *SGLiveActivitySettingsPage(void) {
    SGLiveActivityPreview *preview = [SGLiveActivityPreview new];
    __weak SGLiveActivityPreview *weakPreview = preview;
    void (^switched)(BOOL) = ^(BOOL on) { [weakPreview reload]; };

    SGModRow *on = SGOptionRow(@"Live Activity", nil, SGKeyLiveActivity);
    on.changed = ^(BOOL value) { SGSetLiveActivityEnabled(value); };
    SGModRow *view = SGChoiceRow(@"표시 내용", nil, SGKeyLiveActivityView, viewNames(), SGLiveActivityLyrics);
    // The lyrics view's own rows, shown while it is picked.
    SGModRow *without = menuRow(@"가사가 없을 때", SGKeyLiveActivityWithoutLyrics, @[@"음표", @"곡"], SGLiveActivityWithoutLyricsNote, preview);
    SGModRow *alignment = menuRow(@"정렬", SGKeyLiveActivityAlignment, @[@"왼쪽", @"가운데"], SGLiveActivityAlignCenter, preview);
    SGModRow *translation = SGOptionRow(@"번역", @"번역이 있으면 가사 아래에 표시", SGKeyLiveActivityTranslation);
    translation.changed = switched;
    SGModRow *size = SGChoiceRow(@"글자 크기", nil, SGKeyLiveActivityTextSize, @[@"작게", @"중간", @"크게"], SGLiveActivityTextMedium);
    for (SGModRow *row in @[without, alignment, translation, size]) row.visible = ^BOOL { return SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics) == SGLiveActivityLyrics; };
    // Every view's.
    SGModRow *artwork = SGSwitchRow(@"아트워크", @"곡 이름 옆과 Dynamic Island에 커버 표시", SGKeyLiveActivityArtwork);
    artwork.changed = switched;
    SGModRow *colors = menuRow(@"색상", SGKeyLiveActivityColors, @[@"Spotify", @"아트워크", @"Plain"], SGLiveActivityColorsSpotify, preview);
    SGModRow *progress = SGSwitchRow(@"재생 진행 막대", nil, SGKeyLiveActivityProgressBar);
    progress.changed = switched;
    // The sleep timer's own: the card's Timer tab, the Sleep Timer shortcut and its control all fade by it, card on or
    // off, and so does Spotify's own timer from the player's menu (Shared/Player/SpotifySleepTimer.m).
    NSArray<NSString *> *fades = SGSleepTimerFadeNames();
    SGModRow *fade = SGMenuRow(@"페이드 아웃", fades, ^NSString *{ return fades[(NSUInteger)SGSleepTimerFadeChoice()]; },
                               ^(NSInteger index) { SGSetInt(SGKeySleepTimerFade, index); });
    SGLiveActivityPage *page = [[SGLiveActivityPage alloc] initWithTitle:@"Live Activity" intro:nil sections:@[
        SGSection(nil, @[missingRow(), on, view, without, alignment, translation, size]),
        SGNotedSection(@"카드", @[artwork, colors, progress],
                       @"Spotify 색상은 커버 배경과 Spotify 초록색을 사용하고, 아트워크 색상은 강조색도 커버에서 가져옵니다. 단색은 잠금 화면 배경 위에 흰색으로 표시합니다. iOS 18부터 연결된 Apple Watch의 스마트 스택, iOS 26부터 CarPlay에도 가사 또는 곡 정보를 작은 카드로 표시합니다. 카드를 탭하면 iPhone에서 Spotify를 엽니다."),
        SGNotedSection(@"수면 타이머", @[fade],
                       @"수면 타이머가 Spotify를 일시정지하기 전 음량을 줄이는 시간입니다. 타이머 탭, 수면 타이머 단축어, 제어 센터 및 플레이어 ⋯ 메뉴의 Spotify 타이머에 적용됩니다."),
    ] footer:nil];
    page.preview = preview;
    return page;
}
