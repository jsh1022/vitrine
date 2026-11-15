#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "About.h"
#import "App/Onboarding/Onboarding.h"
#import "Shared/AutoMix/AutoMix.h"
#import "Shared/Lossless/LosslessQuality.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LyricsTranslation/LyricsTranslation.h"

// Every key of the mod's is under one prefix, so a reset is a sweep of the defaults with the stock
// marker of SGPrefs.h left behind; the hooks read them at launch, so it ends in a restart.
static void resetAll(void) {
    // Spotify's own settings that AutoMix and Lossless changed go back first, while the keys that hold them are there.
    SGAutoMixApply(NO);
    SGLosslessLowerQuality(NO);
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSUInteger removed = 0;
    for (NSString *key in [store persistentDomainForName:NSBundle.mainBundle.bundleIdentifier].allKeys) {
        if (![key hasPrefix:@"spotifyglass."]) continue;
        [store removeObjectForKey:key];
        removed++;
    }
    [store setBool:YES forKey:SGKeyStock];
    SGLog(@"reset: removed %lu keys", (unsigned long)removed);
    SGRestartSpotify();
}

static void confirmReset(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"모든 설정을 초기화할까요?"
                                                                  message:@"모든 스위치를 끄고 플래그 재정의와 탭 배치를 지운 후 Spotify를 재시작합니다. 다시 켤 때까지 Mod 기능은 작동하지 않습니다. Spotify 자체 설정은 유지됩니다."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"초기화 후 재시작" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { resetAll(); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// Reset all leaves the Keychain alone, so a key outlives a reset; this takes every item Vitrine keeps there.
static void confirmClearKeychain(void) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Keychain을 지울까요?"
                                                                  message:@"이 iPhone에서 Gemini, OpenAI 호환 서버, Anthropic의 API 키와 OpenAI 호환 서버 주소 및 Spicy Lyrics 키를 삭제합니다. 설정은 유지됩니다."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keychain 지우기" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SGAIForgetKeys();
        SGSpicyLyricsForgetKey();
        SGLog(@"reset: keychain cleared");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static SGModRow *withSymbol(SGModRow *row, NSString *symbol) {
    row.symbol = symbol;
    return row;
}

// Which build this is, whether GitHub has a newer release, and where to reach the mod: without these
// rows a build that is already installed has no way of telling its user that anything moved on.
UIViewController *SGAboutPage(void) {
    SGModRow *reset = withSymbol(SGActionRow(@"모든 설정 초기화", nil, ^{ confirmReset(); }), @"trash");
    reset.color = SGRed();
    SGModRow *clearKeys = withSymbol(SGActionRow(@"Keychain 지우기", nil, ^{ confirmClearKeychain(); }), @"key");
    clearKeys.color = SGRed();
    NSString *spotify = SGSpotifyVersion();
    if ([SGSpotifyLikelyWorksVersions containsObject:spotify]) spotify = [spotify stringByAppendingString:@", 작동 가능"];
    else if (![SGSpotifySupportedVersions containsObject:spotify]) spotify = [NSString stringWithFormat:@"현재 %@ · 대상 %@", spotify, SGSpotifyMadeFor];
    // The row reads out where the build stands and opens the changelog of everything newer than it.
    SGModRow *updates = SGPageRow(@"업데이트", ^UIViewController *{ return SGUpdatePage(); });
    updates.value = ^NSString *{ return SGUpdateStatus(); };
    // A release build can opt into betas; a beta build starts opted in. Either way a check follows at
    // once, since the stored list only holds what counted at the last one.
    SGModRow *betas = SGSwitchRow(@"베타 버전 포함", @"정식 릴리스 전 테스트 빌드 제공", SGKeyUpdateBetas);
    betas.defaultOn = SGBuildIsBeta();
    betas.changed = ^(BOOL on) { SGCheckForUpdate(YES); };
    NSMutableArray<SGModRow *> *links = [NSMutableArray array];
    if (SGRepoURL) [links addObject:withSymbol(SGLinkRow(@"GitHub", nil, SGRepoURL), @"chevron.left.forwardslash.chevron.right")];
    [links addObjectsFromArray:@[
        withSymbol(SGPageRow(@"라이선스", ^UIViewController *{ return SGLicensesPage(); }), @"doc.text"),
        withSymbol(SGActionRow(@"시작 안내", nil, ^{ SGShowOnboarding(); }), @"map"),
    ]];
    if (SGWhatsNewChanges().count) [links insertObject:withSymbol(SGActionRow(@"새로운 기능", nil, ^{ SGShowWhatsNew(); }), @"sparkles") atIndex:links.count - 1];
    NSMutableArray<SGModRow *> *build = [NSMutableArray arrayWithObjects:updates, betas,
        SGStatRow(@"버전", ^NSString *{ return @(SG_VERSION); }),
        SGStatRow(@"Spotify", ^NSString *{ return spotify; }), nil];
    SGModRow *signedUntil = SGSigningExpiryRow();
    if (signedUntil) [build addObject:signedUntil];
    return [[SGModPage alloc] initWithTitle:@"Mod" intro:nil sections:@[
        SGSection(nil, build),
        SGSection(nil, links),
        SGSection(nil, @[
            withSymbol(SGActionRow(@"설정 내보내기", nil, ^{ SGExportSettings(); }), @"square.and.arrow.up"),
            withSymbol(SGActionRow(@"설정 가져오기", nil, ^{ SGImportSettings(); }), @"square.and.arrow.down"),
            withSymbol(SGActionRow(@"진단 정보 공유", @"버그 보고용 버전, 광고 수, 이번 실행 로그 및 Spotify 설정입니다. 곡 이름이 포함될 수 있습니다.",
                                   ^{ SGShareDiagnostics(); }), @"stethoscope"),
        ]),
        SGSection(nil, @[clearKeys, reset]),
    ] footer:nil];
}
