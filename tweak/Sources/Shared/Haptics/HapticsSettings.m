// The Vibrations page, under either look (App/ModSettings.x links it from the main page): the preview at the
// top (SGVibrationsPreview.m), then a card per kind, the way the Audio effects page has one per effect.
// Controls is a switch with its strength under it. Music Haptics is two switches in one card that work together:
// Music Haptics itself, the mod's own from the sound while Spotify is in front, with its strength and what it
// follows (a choice that also says whether the rumble plays, rather than a switch of its own that one choice would
// leave with nothing to do) under it; and In the Background, which names the song to iOS's own Music Haptics, with
// what iOS's own is doing under it, or, while Music Haptics is off in Settings > Accessibility, a row saying so.
// The rows under a switch stay where they are, grayed, while it is off. Each strength's slider plays a tap at the
// new strength with each step, and the preview ripples with it.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Haptics.h"
#import "SGHapticRelay.h"
#import "SGVibrationsPreview.h"

static NSString *const kMusicInfo = @"Spotify가 재생하는 소리를 분석해 드럼에 맞춰 탭하고 베이스에 진동을 더합니다. Spotify가 열린 동안만 작동합니다. iOS는 앱 자체의 백그라운드 햅틱을 중지하며 다른 Connect 기기에서 재생하면 분석할 소리가 없습니다.\n\n백그라운드에서도 함께 켜면 지원되는 곡에는 iOS 햅틱을 우선하여 두 진동이 겹치지 않습니다.";

static NSString *const kEverywhereInfo = @"탈옥 환경에서는 Spotify를 벗어나 홈, 다른 앱, 잠금 화면에서도 음악 햅틱을 유지합니다. Spotify가 소리를 분석하고 언제든 햅틱을 재생할 수 있는 SpringBoard가 진동을 출력합니다.\n\n이 기능은 패키지 관리자(Sileo, Zebra, Filza)로 한 번 설치하는 Vitrine Addon이 담당합니다. Spotify 안에서 실행되는 Vitrine 자체는 SpringBoard에 접근할 수 없습니다.";
// The add-on's .deb inside Spotify handed to the package manager, once the alert it is picked from has gone.
static void shareAddon(void) {
    SGHapticAddonShareSoon();
}

// Everywhere switched on without the add-on: what it needs, and the add-on two taps away (SGHapticAddonExplain).
static void explainAddon(void) {
    SGHapticAddonExplain(@"Spotify 밖에서 음악 햅틱 사용");
}

static NSString *const kBackgroundInfo = @"잠금 화면과 다른 앱에서 iOS 음악 햅틱으로 진동을 유지합니다. Apple Music 카탈로그에서 얻은 ISRC로 현재 녹음을 iOS에 알리며 소리는 휴대전화 밖으로 전송하지 않습니다. iOS가 Apple Music과 같은 햅틱 트랙을 재생합니다.\n\n설정 > 손쉬운 사용 > 음악 햅틱이 켜져 있어야 하며 Apple이 햅틱을 제공하는 곡만 지원합니다. Spotify가 열린 동안에는 위 음악 햅틱 기능이 다른 곡의 진동을 담당합니다.";

NSNotificationName const SGMusicHapticsSwitchesChangedNotification = @"SGMusicHapticsSwitchesChangedNotification";
NSNotificationName const SGSystemMusicHapticsChangedNotification = @"SGSystemMusicHapticsChangedNotification";

static NSString *sg_status;
static BOOL sg_systemOff;

NSString *SGMusicHapticsStatus(void) {
    return sg_status ?: @"대기 중";
}

void SGSetMusicHapticsStatus(NSString *status) {
    sg_status = [status copy];
}

BOOL SGSystemMusicHapticsOn(void) {
    return !sg_systemOff;
}

void SGSetSystemMusicHapticsOn(BOOL on) {
    if (sg_systemOff == !on) return;
    sg_systemOff = !on;
    [NSNotificationCenter.defaultCenter postNotificationName:SGSystemMusicHapticsChangedNotification object:nil];
}

static BOOL backgroundAvailable(void) {
    if (@available(iOS 18.0, *)) return YES;
    return NO;
}

BOOL SGMusicHapticsOn(void) {
    return SGFlag(SGKeyMusicHaptics, NO);
}

BOOL SGMusicHapticsListedByInstall(void) {
    return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"MusicHapticsSupported"] boolValue];
}

BOOL SGMusicHapticsInBackground(void) {
    return backgroundAvailable() && SGFlag(SGKeyMusicHapticsBackground, NO);
}

void SGMigrateMusicHaptics(void) {
    // The redesign's old key first: SGMigrateKey leaves it where it is once the new one exists.
    SGMigrateKey(SGKeyMusicHapticsWas, SGKeyMusicHaptics);
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    if (![store objectForKey:SGKeyMusicHapticsMode]) return;
    NSInteger mode = SGInt(SGKeyMusicHapticsMode, 0);
    SGSetEnabled(SGKeyMusicHaptics, mode == 1);
    SGSetEnabled(SGKeyMusicHapticsBackground, mode == 2);
    [store removeObjectForKey:SGKeyMusicHapticsMode];
    SGLog(@"music haptics: the choice %ld is now Music Haptics %@, In the Background %@", (long)mode, mode == 1 ? @"on" : @"off", mode == 2 ? @"on" : @"off");
}

static NSArray<NSString *> *followsNames(void) {
    return @[@"모두", @"Beat", @"Bass"];
}

static NSArray<NSString *> *followsNotes(void) {
    return @[@"킥과 스네어마다 탭하며 베이스에 진동을 더합니다",
             @"킥과 스네어마다 탭하며 지속 진동은 없습니다",
             @"킥마다 탭하며 베이스에 진동을 더합니다"];
}

static void strengthRange(NSString *key, NSInteger *minimum, NSInteger *maximum) {
    BOOL music = [key isEqualToString:SGKeyMusicStrength];
    *minimum = music ? SGMusicStrengthMin : SGControlStrengthMin;
    *maximum = music ? SGMusicStrengthMax : SGControlStrengthMax;
}

double SGHapticsStrength(NSString *key) {
    NSInteger minimum, maximum;
    strengthRange(key, &minimum, &maximum);
    return MAX(minimum, MIN(maximum, SGInt(key, 100))) / 100.0;
}

SGMusicFollows SGMusicHapticsFollows(void) {
    NSInteger follows = SGInt(SGKeyMusicFollows, SGMusicFollowsEverything);
    return follows >= SGMusicFollowsEverything && follows <= SGMusicFollowsBass ? (SGMusicFollows)follows : SGMusicFollowsEverything;
}

// A percentage slider over a strength key, telling `changed` each step it stores.
static SGModRow *strengthRow(NSString *key, void (^changed)(void)) {
    NSInteger minimum, maximum;
    strengthRange(key, &minimum, &maximum);
    return SGSliderRow(@"강도", nil, minimum, maximum, SGStrengthStep,
        ^double { return SGHapticsStrength(key) * 100; },
        ^(double value) {
            SGSetInt(key, lround(value));
            if (changed) changed();
        },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld%%", lround(value)]; });
}

// The cards, `preview` told when something it reads out changes and shown the slider's taps, `explain` run by a
// tap on the row that says iOS's Music Haptics is off.
static NSArray<SGModSection *> *sections(SGVibrationsPreview *preview, void (^explain)(void)) {
    SGMigrateMusicHaptics();
    __weak SGVibrationsPreview *weakPreview = preview;
    SGModRow *controls = SGSwitchRow(@"컨트롤", nil, SGKeyControlHaptics);
    controls.changed = ^(BOOL on) { [weakPreview reload]; };
    SGModRow *controlStrength = strengthRow(SGKeyControlStrength, ^{
        // Felt as it is set, and seen: a tap at the new strength with each step, and its ripple.
        SGPlayFeedback(SGFeedbackAdd);
        [weakPreview rippleAt:SGHapticsStrength(SGKeyControlStrength)];
    });
    controlStrength.waitsOn = SGKeyControlHaptics;

    void (^switched)(BOOL) = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGMusicHapticsSwitchesChangedNotification object:nil];
        [weakPreview reload];
    };
    SGModRow *music = SGOptionRow(@"음악 햅틱", nil, SGKeyMusicHaptics);
    music.info = kMusicInfo;
    music.changed = switched;
    SGModRow *musicStrength = strengthRow(SGKeyMusicStrength, ^{
        // As Controls' Strength: a kick at the new strength with each step, and its ripple.
        SGMusicHapticsSettingsChanged();
        SGMusicHapticsPreview();
        [weakPreview rippleAt:SGHapticsStrength(SGKeyMusicStrength) / 2];
    });
    musicStrength.waitsOn = SGKeyMusicHaptics;
    SGModRow *follows = SGChoiceRow(@"진동 기준", nil, SGKeyMusicFollows, followsNames(), SGMusicFollowsEverything);
    follows.choiceNotes = followsNotes();
    follows.chosen = ^(NSInteger index) { SGMusicHapticsSettingsChanged(); };
    follows.waitsOn = SGKeyMusicHaptics;

    // Everywhere (SGHapticRelay.h): on a jailbroken phone, played from SpringBoard when its side answers, else by the vibration.
    SGModRow *everywhere = SGOptionRow(@"모든 화면", nil, SGKeyMusicHapticsEverywhere);
    everywhere.info = kEverywhereInfo;
    everywhere.changed = ^(BOOL on) {
        switched(on);
        if (on && !SGHapticRelayAvailable()) explainAddon();
    };
    everywhere.waitsOn = SGKeyMusicHaptics;
    everywhere.visible = ^BOOL { return SGHapticEverywhereOffered(); };
    // Everywhere's second switch: with it, Music Haptics plays in Spotify only, everywhere but the lock screen, or everywhere.
    SGModRow *lockScreen = SGSwitchRow(@"잠금 화면에서", @"꺼짐: 휴대전화 잠금이 풀린 동안만 작동", SGKeyMusicHapticsLockScreen);
    // Off until asked for: a locked phone in a pocket does not vibrate.
    lockScreen.defaultOn = NO;
    lockScreen.changed = ^(BOOL on) { SGHapticRelaySendLockScreen(); };
    lockScreen.waitsOn = SGKeyMusicHapticsEverywhere;
    lockScreen.visible = ^BOOL { return SGHapticEverywhereOffered(); };
    // A newer add-on inside this Vitrine than the one SpringBoard runs: the same two taps put it in place.
    SGModRow *addonUpdate = SGActionRow(@"Vitrine Addon 업데이트", @"이 Vitrine에는 더 최신 Addon이 포함되어 있습니다", ^{ shareAddon(); });
    addonUpdate.visible = ^BOOL { return SGHapticAddonOutdated(); };

    SGModRow *background = SGOptionRow(@"백그라운드에서", nil, SGKeyMusicHapticsBackground);
    background.info = kBackgroundInfo;
    background.changed = switched;
    background.visible = ^BOOL { return backgroundAvailable(); };
    // What iOS's own is doing, or, while it is off in Accessibility, a row saying where to turn it on.
    SGModRow *status = SGStatRow(@"상태", ^NSString *{ return SGMusicHapticsStatus(); });
    status.visible = ^BOOL { return SGMusicHapticsInBackground() && SGSystemMusicHapticsOn(); };
    // Under In the Background while the install lacks the key iOS lists apps for Music Haptics by.
    SGModRow *unlisted = SGWarningRow(@"이 설치에는 백그라운드 기능이 없습니다", @"탭하여 이유 확인", ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"백그라운드 기능이 없습니다"
            message:@"iOS는 지원을 선언한 앱에만 음악 햅틱을 제공합니다. Vitrine IPA 빌드만 Spotify에 해당 선언을 추가합니다. 이 설치에는 선언이 없어 Spotify를 벗어나면 진동이 멈춥니다. 앱이 열린 동안 위 음악 햅틱은 계속 작동합니다. 두 기능을 모두 사용하려면 Vitrine으로 IPA를 빌드하세요."
            preferredStyle:UIAlertControllerStyleAlert];
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    });
    unlisted.visible = ^BOOL { return backgroundAvailable() && !SGMusicHapticsListedByInstall(); };
    SGModRow *systemOff = SGActionRow(@"iOS에서 음악 햅틱이 꺼져 있습니다", @"탭하여 설정에서 켜기", explain);
    systemOff.visible = ^BOOL { return SGMusicHapticsInBackground() && !SGSystemMusicHapticsOn(); };

    return @[
        SGSection(nil, @[SGWithSymbol(controls, @"hand.tap"), controlStrength]),
        SGSection(nil, @[SGWithSymbol(music, @"waveform"), musicStrength, follows, everywhere, lockScreen, addonUpdate, background, unlisted, status, systemOff]),
    ];
}

#pragma mark - the page

@interface SGVibrationsPage : SGModPage
@property (nonatomic, strong) SGVibrationsPreview *preview;
@end

@implementation SGVibrationsPage

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.tableHeaderView = self.preview;
    // Music Haptics turned on or off in Accessibility while the page is open, or before coming back to it.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(systemMusicHapticsChanged:) name:SGSystemMusicHapticsChangedNotification object:nil];
    // SpringBoard answering after the page opened shows Everywhere.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(systemMusicHapticsChanged:) name:SGHapticRelayAvailableNotification object:nil];
}

- (void)systemMusicHapticsChanged:(NSNotification *)note {
    [self refreshVisibility];
}

// The header keeps the height it is given, so it is sized here and handed back to the table only when that
// changes (a table header set on every pass lays the table out again forever).
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.preview reload];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    self.preview.listening = YES;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.preview.listening = NO;
}

// The row under In the Background that says iOS's Music Haptics is off: what it needs, and the way there.
- (void)explainBackground {
    // iOS opens no Settings page but an app's own from a third-party app (App-prefs: links fail on iOS 27), so the
    // message gives the path from there.
    NSString *message = @"백그라운드 기능에는 iOS 음악 햅틱이 필요합니다. Spotify 설정에서 뒤로 이동한 후 손쉬운 사용 > 음악 햅틱을 켜세요.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"음악 햅틱 켜기" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"나중에" style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *open = [UIAlertAction actionWithTitle:@"설정 열기" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
    }];
    [alert addAction:open];
    alert.preferredAction = open;
    [self presentViewController:alert animated:YES completion:nil];
}

@end

UIViewController *SGVibrationsSettingsPage(void) {
    SGVibrationsPreview *preview = [SGVibrationsPreview new];
    __block __weak SGVibrationsPage *weakPage;
    NSArray<SGModSection *> *cards = sections(preview, ^{ [weakPage explainBackground]; });
    SGVibrationsPage *page = [[SGVibrationsPage alloc] initWithTitle:@"진동" intro:nil sections:cards footer:nil];
    page.preview = preview;
    weakPage = page;
    return page;
}

