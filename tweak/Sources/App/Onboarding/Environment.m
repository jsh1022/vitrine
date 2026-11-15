// What about the install itself can work against the mod, said once and kept at the top of Mod Settings
// while it lasts: EeveeSpotify injected beside it, a Spotify other than the one it is made for, the redesign without
// the app changes the IPA build makes, and a
// redesign below iOS 26 that did not start (Core/SGUIMode.h), which turned itself off. Also what Chroma, installed
// over the same Spotify before, left behind, offered once for deleting.
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Haptics/Haptics.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Onboarding.h"

static NSString *const kTold = @"spotifyglass.environment.told";
static NSString *const kCleanupOffered = @"spotifyglass.environment.chromaCleanupOffered";
static const NSTimeInterval kSettle = 4;   // after the first activation, behind the signing sheet's 3 s
static const NSTimeInterval kRetry = 4;
static const NSInteger kTries = 45;        // three minutes of waiting for the screen, then the rows say it

// A problem is its title and what it means, @[title, body].
typedef NSArray<NSString *> *SGProblem;

NSString *SGSpotifyVersion(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
}

// A Spotify whose version can be read and is not the one the mod is made for; one that cannot be read
// says nothing, rather than "Spotify unknown".
static BOOL otherVersion(void) {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] && ![SGSpotifySupportedVersions containsObject:version]
        && ![SGSpotifyLikelyWorksVersions containsObject:version];
}

static SGProblem eevee(void) {
    return @[@"EeveeSpotify도 함께 삽입되어 있습니다",
             @"Vitrine과 EeveeSpotify는 Spotify의 같은 부분에 광고 차단과 가사를 적용합니다. 함께 사용하면 시작 중 멈추거나 잘못된 가사를 표시할 수 있습니다. EeveeSpotify 없이 Spotify를 다시 서명하세요."];
}

// "a", "a and b", "a, b and c", with `word` for the last join.
static NSString *joined(NSArray<NSString *> *items, NSString *word) {
    if (items.count < 2) return items.firstObject ?: @"";
    NSString *head = [[items subarrayWithRange:NSMakeRange(0, items.count - 1)] componentsJoinedByString:@", "];
    return [NSString stringWithFormat:@"%@ %@ %@", head, word, items.lastObject];
}

static SGProblem version(void) {
    NSArray<NSString *> *likely = SGSpotifyLikelyWorksVersions;
    NSString *also = !likely.count ? @""
        : [NSString stringWithFormat:@", and %@ likely %@ too", joined(likely, @"and"), likely.count == 1 ? @"works" : @"work"];
    return @[[NSString stringWithFormat:@"Spotify %@는 Vitrine의 대상 버전이 아닙니다", SGSpotifyVersion()],
             [NSString stringWithFormat:@"Vitrine은 Spotify %@%@용입니다. 다른 버전에서는 일부 기능이 작동하지 않거나 화면 오류와 충돌이 발생할 수 있습니다. Spotify %@에 Vitrine을 삽입하세요.",
                 joined(SGSpotifySupportedVersions, @"and"), also,
                 joined([SGSpotifySupportedVersions arrayByAddingObjectsFromArray:likely], @"or")]];
}

// What this install lacks of the app changes Vitrine's IPA build makes (scripts/pipeline.sh: plist/liquid-glass.plist),
// as when its .deb is injected by hand, each said as what it costs. Spotify's own plist opting out of the system's glass
// (9.1.88's) costs the redesign its glass bars. 9.1.90 has no such key, and none is the same as glass on. The Live
// Activity and Music Haptics keys matter in either look, and their own settings say so too.
static NSArray<NSString *> *missingAppChanges(void) {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    id compatibility = [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIDesignRequiresCompatibility"];
    if (SGRedesignAvailable() && SGRedesignedUIStored() && [compatibility isKindOfClass:NSNumber.class] && [compatibility boolValue])
        [missing addObject:@"탭 막대에 글래스 없이 Spotify 기본 화면을 사용합니다"];
    if (!SGLiveActivityAllowedByInstall()) [missing addObject:@"Live Activity가 없습니다"];
    if (!SGMusicHapticsListedByInstall())
        [missing addObject:@"iOS 음악 햅틱 목록에 Spotify가 없어 백그라운드 진동이 중지됩니다"];
    return missing;
}

static BOOL withoutAppChanges(void) {
    return missingAppChanges().count > 0;
}

static SGProblem appChanges(void) {
    return @[@"Vitrine의 앱 변경 사항 없이 설치됨",
             [NSString stringWithFormat:@"일부 기능은 Vitrine IPA 빌드의 앱 변경 사항이 필요합니다. 없으면 %@. .deb를 삽입하는 대신 Vitrine으로 IPA를 빌드하세요.",
                 joined(missingAppChanges(), @"and")]];
}

static SGProblem fellBack(void) {
    return @[@"재설계 UI를 시작하지 못했습니다",
             [NSString stringWithFormat:@"iOS %@에서 재설계 UI로 Spotify를 실행하지 못해 기본 화면으로 돌아오고 재설계 UI를 껐습니다. Mod 설정에서 다시 켤 수 있습니다.",
                 UIDevice.currentDevice.systemVersion]];
}

// One problem is the alert's title and message; several are a paragraph each under a count.
static void tell(NSArray<SGProblem> *list) {
    NSString *title = list.count == 1 ? list[0][0] : [NSString stringWithFormat:@"확인할 사항 %lu개", (unsigned long)list.count];
    NSMutableArray<NSString *> *paragraphs = [NSMutableArray array];
    for (SGProblem problem in list) {
        [paragraphs addObject:list.count == 1 ? problem[1] : [NSString stringWithFormat:@"%@.\n%@", problem[0], problem[1]]];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:[paragraphs componentsJoinedByString:@"\n\n"]
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// What Chroma, installed over the same Spotify before Vitrine, left in the app's storage that Vitrine never
// reads: its Karaoke voice model (about 470 MB) and its saved lock screen videos. Its listening history and
// audio effects are the person's own and stay (AudioEffectsFiles.m moves the effects over).
static NSArray<NSURL *> *chromaLeftovers(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *support = [files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *caches = [files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSMutableArray<NSURL *> *found = [NSMutableArray array];
    for (NSURL *url in @[[support URLByAppendingPathComponent:@"spoti.pw/Sing" isDirectory:YES],
                         [caches URLByAppendingPathComponent:@"spoti.pw/LockArtwork" isDirectory:YES]]) {
        if ([files fileExistsAtPath:url.path]) [found addObject:url];
    }
    return found;
}

static NSString *sizeOf(NSArray<NSURL *> *urls) {
    long long total = 0;
    for (NSURL *url in urls) {
        for (NSURL *file in [NSFileManager.defaultManager enumeratorAtURL:url includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey] options:0 errorHandler:nil]) {
            NSNumber *size = nil;
            [file getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey error:nil];
            total += size.longLongValue;
        }
    }
    return [NSByteCountFormatter stringFromByteCount:total countStyle:NSByteCountFormatterCountStyleFile];
}

static void offerCleanup(void) {
    NSArray<NSURL *> *leftovers = chromaLeftovers();
    if (!leftovers.count) return;
    NSString *size = sizeOf(leftovers);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"이 iPhone에 Chroma의 %@ 항목이 남아 있습니다", size]
                                                                  message:@"Spotify 저장 공간에 Chroma의 노래방 음성 모델과 잠금 화면 동영상이 남아 있습니다. Vitrine은 이 파일들을 사용하지 않습니다. 감상 기록과 오디오 효과는 유지됩니다."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"삭제" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            for (NSURL *url in leftovers) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
            SGLog(@"environment: deleted %@ Chroma left", size);
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// What about the install is worth saying.
static NSArray<SGProblem> *installProblems(void) {
    NSMutableArray<SGProblem> *list = [NSMutableArray array];
    if (SGEeveeSpotifyInjected()) [list addObject:eevee()];
    if (otherVersion()) [list addObject:version()];
    if (withoutAppChanges()) [list addObject:appChanges()];
    return list;
}

// The rows stay while the install is so; the fall back is said once and is over.
NSArray<SGModRow *> *SGEnvironmentWarningRows(void) {
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    if (SGEeveeSpotifyInjected())
        [rows addObject:SGWarningRow(@"EeveeSpotify도 함께 삽입되어 있습니다", @"탭하여 영향 확인", ^{ tell(@[eevee()]); })];
    if (otherVersion())
        [rows addObject:SGWarningRow([NSString stringWithFormat:@"Spotify %@용", joined(SGSpotifySupportedVersions, @"and")],
                                     [NSString stringWithFormat:@"현재 버전은 %@입니다. 탭하여 영향 확인", SGSpotifyVersion()],
                                     ^{ tell(@[version()]); })];
    if (withoutAppChanges())
        [rows addObject:SGWarningRow(@"앱 변경 사항 없이 설치됨", @"탭하여 영향 확인", ^{ tell(@[appChanges()]); })];
    if (chromaLeftovers().count)
        [rows addObject:SGWarningRow(@"Chroma 파일이 남아 있습니다", [NSString stringWithFormat:@"Vitrine이 사용하지 않는 %@ 항목입니다. 탭하여 삭제", sizeOf(chromaLeftovers())], ^{ offerCleanup(); })];
    return rows;
}

// Once per install state: the same EeveeSpotify and the same Spotify version say nothing again, a
// change says what it is now.
static NSString *state(void) {
    return [NSString stringWithFormat:@"eevee %d, spotify %@, app changes %d", SGEeveeSpotifyInjected(), SGSpotifyVersion(), !withoutAppChanges()];
}

static void whenClear(NSInteger tries, void (^then)(void)) {
    UIViewController *top = SGTopController();
    // The tour, What's new and the signing sheet own the screen first; an alert presented from one of
    // them lands nowhere, so this one waits its turn. It also waits for the app to be in front, so it is
    // not shown, and counted as told, to someone who sent Spotify away in its first seconds.
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if (!front || !top || SGOnboardingShowing() || [top isKindOfClass:UIAlertController.class]) {
        if (tries <= 0) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kRetry * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            whenClear(tries - 1, then);
        });
        return;
    }
    then();
}

static void tellProblems(void) {
    // The fall back is news every time; the install's state only when it changed.
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSMutableArray<SGProblem> *list = [NSMutableArray array];
    if (SGRedesignFellBack()) [list addObject:fellBack()];
    if (![[store stringForKey:kTold] isEqualToString:state()]) {
        [store setObject:state() forKey:kTold];
        [list addObjectsFromArray:installProblems()];
    }
    if (list.count) tell(list);
    // Chroma's leftovers are offered once, after any problem; the row in Mod Settings stays while they do.
    if (chromaLeftovers().count && ![store boolForKey:kCleanupOffered]) {
        whenClear(kTries, ^{
            [store setBool:YES forKey:kCleanupOffered];
            offerCleanup();
        });
    }
}

void SGCheckEnvironmentOnce(void) {
    __block id token = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                      object:nil
                                                                       queue:nil
                                                                  usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:token];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSettle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (SGEeveeSpotifyInjected()) SGLog(@"environment: EeveeSpotify is injected too");
            if (otherVersion()) SGLog(@"environment: Spotify %@, made for %@", SGSpotifyVersion(), SGSpotifyMadeFor);
            whenClear(kTries, ^{ tellProblems(); });
        });
    }];
}
