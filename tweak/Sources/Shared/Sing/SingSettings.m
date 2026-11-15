// The Sing page (Sing on Mod Settings' main page, and Lyrics > Karaoke), under either look: the card at its top
// (SGSingCard.m: the song, what Sing is doing, the vocals and the rest traced live, play and pause, the vocals'
// level and its three stops), Sing's switch, which turns the mic on and off at once, Ignore heat warnings, the voice
// model (Best quality or Light, the chosen one's download and removal, and the other's removal), spatial voice's page (its preview, SGSpatialPreview.m, and its switch), and Runs on under
// Advanced. While the page is on screen with Spotify in front, the card's reads of its lines keep Sing separating
// the playing song even at As sung, where it otherwise rests (SGSingReadLevels), so what the card shows and what
// its slider sets are heard at once; popped, covered or in the background, the page no longer counts.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Sing.h"
#import <sys/utsname.h>

// Chips before the A14 (the iPhone XS, XR, 11 and SE 2: iPhone11,x and iPhone12,x) are untested and may not keep up.
static BOOL untestedChip(void) {
    struct utsname name;
    int major = 0;
    return uname(&name) == 0 && sscanf(name.machine, "iPhone%d,", &major) == 1 && major < 13;
}

UIView *SGSingCardView(void);   // SGSingCard.m

static void tell(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static void ask(NSString *title, NSString *message, NSString *action, BOOL destructive, void (^then)(void)) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:action style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) { then(); }]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

NSString *SGSingLevelText(double level) {
    if (level <= 0.001) return @"Gone";
    if (level < 0.999) return [NSString stringWithFormat:@"%.0f%%", level * 100];
    if (level <= 1.001) return @"원래 보컬";
    if (level >= 1.999) return @"보컬만";
    return [NSString stringWithFormat:@"반주 %.0f%%", (2 - level) * 100];
}

static NSString *bytes(long long count) {
    return [NSByteCountFormatter stringFromByteCount:count countStyle:NSByteCountFormatterCountStyleFile];
}

// The row's state: with the old model, its update reads as the model's download, worded as an update.
static SGSingModelState rowState(void) {
    if (SGSingModelUpdateDownloading()) return SGSingModelDownloading;
    if (SGSingModelUpdateAvailable()) return SGSingModelMissing;
    return SGSingModelCurrentState();
}

static NSString *modelValue(void) {
    if (!SGSingOSSupported()) return @"사용 불가";
    BOOL update = SGSingModelUpdateAvailable();
    switch (rowState()) {
        case SGSingModelDownloading:
            if (SGSingModelChecking()) return @"Checking…";
            if (SGSingModelWaitingForNetwork()) return SGSingModelOverCellular() ? @"네트워크 대기 중" : @"Wi-Fi 대기 중";
            return [NSString stringWithFormat:@"%.0f%%", SGSingModelProgress() * 100];
        case SGSingModelReady: return [NSString stringWithFormat:@"다운로드됨 · %@", SGSingModelSizeText()];
        case SGSingModelMissing:
            if (SGSingModelError()) return update ? @"업데이트 실패 · 다시 시도하세요" : @"실패했습니다. 다시 시도하세요";
            if (SGSingModelPausedBytes()) {
                return [NSString stringWithFormat:@"%@ · %@ of %@", update ? @"업데이트 일시정지됨" : @"일시정지됨", bytes(SGSingModelPausedBytes()), SGSingModelSizeText()];
            }
            return [NSString stringWithFormat:update ? @"업데이트 가능 · %@" : @"다운로드 · %@", SGSingModelSizeText()];
    }
    return @"";
}

static void modelTapped(UITableViewController *page) {
    if (!SGSingOSSupported()) {
        tell(@"음성 모델", SGSingMissing());
        return;
    }
    switch (rowState()) {
        case SGSingModelMissing: {
            BOOL update = SGSingModelUpdateAvailable();
            NSString *message = [NSString stringWithFormat:@"Hugging Face에서 %@%@%@을 받습니다. 셀룰러 사용을 허용하지 않으면 Wi-Fi를 기다립니다. 모델은 이 iPhone에 보관되며 소리는 외부로 전송하지 않습니다.",
                                 SGSingModelError() ? [NSString stringWithFormat:@"마지막 시도 실패: %@\n\n", SGSingModelError()] : @"",
                                 update ? @"새 모델은 Neural Engine에서 더 빠르고 발열이 적게 작동합니다. 새 모델을 받을 때까지 기존 모델을 유지합니다. " : @"",
                                 SGSingModelSizeText()];
            if (untestedChip()) {
                message = [message stringByAppendingString:SGSingChosenModel() == SGSingModelLight
                    ? @"\n\niPhone 15 Pro에서 노래방을 검증했습니다. iPhone 12 이전 모델에서는 경량 모델도 실시간 처리 속도를 따라가지 못할 수 있습니다."
                    : @"\n\niPhone 15 Pro에서 노래방을 검증했습니다. iPhone 12 이전 모델에서는 처리 속도가 부족할 수 있으며 경량 모델이 더 적합합니다."];
            }
            NSString *title = SGSingModelPausedBytes() ? (update ? @"업데이트를 계속할까요?" : @"다운로드를 계속할까요?")
                                                       : (update ? @"업데이트를 다운로드할까요?" : @"음성 모델을 다운로드할까요?");
            ask(title, message, @"다운로드", NO, ^{ SGSingDownloadModel(); });
            break;
        }
        case SGSingModelDownloading:
            if (SGSingModelWaitingForNetwork() && !SGSingModelOverCellular()) {
                ask(@"셀룰러로 다운로드할까요?", [NSString stringWithFormat:@"Wi-Fi 연결을 기다리고 있습니다. 셀룰러나 저데이터 모드에서 다운로드하면 최대 %@의 데이터를 사용합니다.",
                                                 SGSingModelSizeText()], @"셀룰러 사용", NO, ^{ SGSingDownloadModelOverCellular(); });
                break;
            }
            ask(@"다운로드를 중지할까요?", @"받은 데이터는 보관되며 다음 다운로드에서 이어받습니다.", @"Stop", YES, ^{ SGSingCancelModelDownload(); });
            break;
        case SGSingModelReady:
            ask(@"음성 모델을 삭제할까요?", [NSString stringWithFormat:@"%@의 공간을 확보합니다. 보컬을 줄이려면 모델을 다시 받아야 합니다.", SGSingModelInUseSizeText()],
                @"삭제", YES, ^{
                    SGSetSingOn(NO);
                    SGSingDeleteModel();
                    // Sing's switch goes off with it.
                    [page.tableView reloadData];
                });
            break;
    }
}

// Spatial voice's page, under Sing's: the preview at its top and the switch.
@interface SGSpatialVoicePage : SGModPage
@property (nonatomic, readonly) SGSpatialPreview *preview;
@end

@implementation SGSpatialVoicePage

- (void)viewDidLoad {
    [super viewDidLoad];
    _preview = [[SGSpatialPreview alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 0)];
    self.tableView.tableHeaderView = _preview;
}

// Its caption follows Dynamic Type and what the preview is doing, so the header is sized to it, and handed back
// only when that size changes (SGFitNote's way: the table lays out again on every handing back).
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    CGSize size = [_preview sizeThatFits:CGSizeMake(table.bounds.size.width, 0)];
    if (CGSizeEqualToSize(_preview.bounds.size, size)) return;
    _preview.frame = (CGRect){_preview.frame.origin, size};
    table.tableHeaderView = _preview;
}

@end

UIViewController *SGSpatialVoiceSettingsPage(void) {
    SGModRow *spatial = SGOptionRow(@"공간 음성", nil, SGKeySingSpatial);
    __block __weak SGSpatialVoicePage *page;
    spatial.changed = ^(BOOL on) {
        SGSetSingSpatial(on);
        [page.preview refresh];
    };
    SGSpatialVoicePage *made = [[SGSpatialVoicePage alloc] initWithTitle:@"공간 음성" intro:nil sections:@[
        SGNotedSection(nil, @[spatial],
                       @"고개를 돌려도 목소리는 앞쪽에 머무르고 반주는 고개를 따라 움직입니다. 고개를 돌린 채 유지하면 목소리가 다시 앞으로 돌아옵니다. 머리 추적을 지원하는 AirPods Pro, AirPods 3 이후 모델, AirPods Max를 사용하며 처음에는 동작 및 피트니스 권한을 요청합니다. iOS 스테레오 공간화가 켜져 있으면 목소리도 iOS에서 처리합니다."),
        SGNotedSection(@"소리", @[
            SGSliderRow(@"거리", nil, 1, 6.5, 0.5, ^double { return SGSingSpatialDistance(); }, ^(double value) {
                SGSetSingSpatialSound(value, SGSingSpatialRoom(), SGSingSpatialFront(), SGSingSpatialWidth());
            }, ^NSString *(double value) { return [NSString stringWithFormat:@"%.1f m", value]; }),
            SGSliderRow(@"공간", nil, 0, 100, 5, ^double { return SGSingSpatialRoom(); }, ^(double value) {
                SGSetSingSpatialSound(SGSingSpatialDistance(), value, SGSingSpatialFront(), SGSingSpatialWidth());
            }, ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%%", value]; }),
            SGSliderRow(@"정면 복귀", nil, 5, 60, 1, ^double { return SGSingSpatialFront(); }, ^(double value) {
                SGSetSingSpatialSound(SGSingSpatialDistance(), SGSingSpatialRoom(), value, SGSingSpatialWidth());
            }, ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f초 후", value]; }),
            SGSliderRow(@"악기 폭", nil, 0, 200, 5, ^double { return SGSingSpatialWidth(); }, ^(double value) {
                SGSetSingSpatialSound(SGSingSpatialDistance(), SGSingSpatialRoom(), SGSingSpatialFront(), value);
            }, ^NSString *(double value) { return [NSString stringWithFormat:@"%.0f%%", value]; }),
        ], @"목소리의 거리와 주변 공간감을 조절합니다. 멀어질수록 목소리는 작아지고 공간의 울림이 늘어납니다. 정면 복귀 시간은 고개를 돌린 채 유지할 때 목소리가 다시 앞으로 돌아오는 시간입니다. 악기 폭은 반주를 원본보다 넓게 펼치며 100% 미만에서는 좁힙니다."),
    ] footer:nil];
    page = made;
    return made;
}

// The Sing page: the card (SGSingCard.m) as the table's header, sized to Dynamic Type, then its rows.
@interface SGSingPage : SGModPage
@end

@implementation SGSingPage {
    UIView *_card;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _card = SGSingCardView();
    self.tableView.tableHeaderView = _card;
}

// Handed back only when its size changes (SGFitNote's way: the table lays out again on every handing back).
- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    CGSize size = [_card sizeThatFits:CGSizeMake(table.bounds.size.width, 0)];
    if (CGSizeEqualToSize(_card.bounds.size, size)) return;
    _card.frame = (CGRect){_card.frame.origin, size};
    table.tableHeaderView = _card;
}

@end

NSNotificationName const SGSingButtonDidChangeNotification = @"SGSingButtonDidChangeNotification";

BOOL SGSingButtonShown(void) {
    return SGFlag(SGKeySingButton, SGSingOSSupported());
}

UIViewController *SGSingSettingsPage(void) {
    SGModRow *sing = SGOptionRow(@"노래방", nil, SGKeySing);
    sing.changed = ^(BOOL on) { SGSetSingOn(on); };
    // Only the redesign's lyrics have the mic.
    SGModRow *button = SGSwitchRow(@"가사에서 전환", @"가사 모서리의 마이크", SGKeySingButton);
    button.defaultOn = SGSingOSSupported();
    button.changed = ^(BOOL on) { [NSNotificationCenter.defaultCenter postNotificationName:SGSingButtonDidChangeNotification object:nil]; };
    button.visible = ^BOOL { return SGRedesignedUIStored(); };
    SGModRow *heat = SGOptionRow(@"발열 경고 무시", @"발열 중에도 노래방을 유지합니다. 기기가 더 뜨거워질 수 있습니다", SGKeySingIgnoreHeat);
    SGModRow *memory = SGOptionRow(@"메모리 경고 무시", @"메모리가 부족해도 노래방을 유지합니다. iOS가 Spotify를 종료할 수 있습니다",
                                   SGKeySingIgnoreMemory);
    heat.changed = ^(BOOL on) { SGSetSingIgnoresHeat(on); };
    __block __weak SGModPage *page;
    SGModRow *model = SGStatActionRow(@"음성 모델", nil, ^NSString *{ return modelValue(); }, ^{ modelTapped(page); });
    SGModRow *remove = SGActionRow(@"음성 모델 제거", nil, ^{
        BOOL partial = SGSingModelCurrentState() != SGSingModelReady;
        ask(partial ? @"일시정지한 다운로드를 제거할까요?" : @"음성 모델을 제거할까요?",
            partial ? [NSString stringWithFormat:@"%@의 공간을 확보합니다. 새 다운로드는 처음부터 시작합니다.", bytes(SGSingModelPausedBytes())]
                    : [NSString stringWithFormat:@"%@의 공간을 확보합니다. 보컬을 줄이려면 모델을 다시 받아야 합니다.", SGSingModelInUseSizeText()],
            @"제거", YES, ^{
                SGSetSingOn(NO);
                SGSingDeleteModel();
                [page.tableView reloadData];
            });
    });
    remove.color = SGRed();
    remove.visible = ^BOOL { return SGSingModelCurrentState() == SGSingModelReady || SGSingModelPausedBytes() > 0; };
    // The two models, picked on the page: the rows below follow the one with the checkmark.
    SGModRow *(^choice)(NSString *, NSString *, SGSingModelKind) = ^SGModRow *(NSString *title, NSString *format, SGSingModelKind kind) {
        SGModRow *row = SGActionRow(title, [NSString stringWithFormat:format, SGSingModelSizeTextOf(kind)], ^{
            if (SGSingChosenModel() == kind) return;
            void (^choose)(void) = ^{
                SGSetSingChosenModel(kind);
                [page.tableView reloadData];
                [page refreshVisibility];
            };
            BOOL downloading = SGSingModelCurrentState() == SGSingModelDownloading || SGSingModelUpdateDownloading();
            if (!downloading) choose();
            else ask(@"다운로드를 중지할까요?", @"모델 다운로드를 중지하고 받은 데이터는 해당 모델을 다시 선택할 때까지 보관합니다.", @"Switch", NO, choose);
        });
        row.checked = ^BOOL { return SGSingChosenModel() == kind; };
        return row;
    };
    SGModRow *full = choice(@"최고 음질", @"전체 모델 %@ · 최신 iPhone용, 가장 선명한 결과", SGSingModelFull);
    SGModRow *light = choice(@"경량", @"소형 모델 %@ · 구형 iPhone용, 보컬이 더 남고 반주 음량이 줄어듭니다",
                             SGSingModelLight);
    SGModRow *other = SGStatActionRow(@"다른 모델 제거", nil, ^NSString *{ return bytes(SGSingOtherModelBytes()); }, ^{
        NSString *name = SGSingChosenModel() == SGSingModelFull ? @"경량" : @"최고 음질";
        ask(@"다른 모델을 제거할까요?", [NSString stringWithFormat:@"%@은 사용 중이 아닙니다. 제거하면 %@의 공간을 확보하며 다시 선택하면 다시 받습니다.",
                                         name, bytes(SGSingOtherModelBytes())],
            @"제거", YES, ^{
                SGSingDeleteOtherModel();
                [page refreshVisibility];
            });
    });
    other.color = SGRed();
    other.visible = ^BOOL { return SGSingOtherModelBytes() > 0; };
    SGModRow *spatial = SGPageRow(@"공간 음성", ^UIViewController *{ return SGSpatialVoiceSettingsPage(); });
    spatial.subtitle = @"AirPods를 사용하면 고개를 돌려도 목소리가 앞쪽에 머무릅니다";
    spatial.value = ^NSString *{ return SGSingSpatial() ? @"켜짐" : @"꺼짐"; };
    // Facts about the iPhone, which do not change while the page shows.
    spatial.visible = ^BOOL { return SGSingSpatialAvailable(); };
    SGModRow *units = SGChoiceRow(@"실행 장치", nil, SGKeySingComputeUnits, SGSingComputeUnitNames(), 0);
    units.choiceNotes = @[@"가장 빠른 Neural Engine 사용 · 로딩 중에는 CPU 사용", @"더 느리고 발열이 많지만 메모리는 조금 적게 사용"];
    units.choiceFooter = @"노래방은 먼저 CPU에 음성 모델을 불러와 시작합니다. 자동 모드에서는 Neural Engine용 모델을 추가로 불러와 백그라운드에서도 사용합니다. Vitrine 설치 또는 업데이트 후 첫 준비에는 약 1분이 걸리며 그동안 CPU를 사용합니다. 업데이트 후 미리 준비가 완료됐다면 바로 전환합니다. 로드하지 못하면 다음 Spotify 실행까지 CPU를 사용합니다.";
    units.chosen = ^(NSInteger index) { SGSingComputeUnitsChanged(); };
    SGModRow *prepare = SGSwitchRow(@"업데이트 후 미리 준비",
                                    @"Vitrine 또는 iOS 업데이트 후 백그라운드에서 Neural Engine을 준비하여 노래방을 빠르게 시작합니다", SGKeySingPrepareAhead);
    SGSingPage *made = [[SGSingPage alloc] initWithTitle:@"노래방" intro:nil sections:@[
        SGSection(nil, @[sing, button, heat, memory]),
        SGNotedSection(@"음성 모델", @[full, light, model, remove, other],
                       @"모델은 각각 따로 받아 보관하며 선택한 모델만 필요합니다. Spotify를 재시작하지 않아도 변경됩니다. 모델은 몇 초 내에 로드되며 준비될 때까지 원래 음악을 재생합니다."),
        SGSection(nil, @[spatial]),
        SGNotedSection(@"고급", @[units, prepare],
                       @"노래방은 보컬을 줄여 따라 부르거나 반주를 줄여 보컬만 들을 수 있습니다. 음성 모델은 이 iPhone에서만 실행되며 소리는 외부로 전송하지 않습니다. 몇 초 앞의 소리를 분석하므로 곡 시작이나 탐색 후 효과가 적용되기까지 몇 초 걸립니다."),
    ] footer:nil];
    page = made;
    return made;
}
