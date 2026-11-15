#import "Core/SGCore.h"
#import "Shared/AppIcon/AppIcon.h"
#import "Shared/Fonts/Fonts.h"
#import "Shared/LyricsTranslation/LyricsTranslation.h"
#import "Redesigned/Player/Player.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Pages.h"
#import "Shared/ArtistBlock/ArtistBlock.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsMeanings/Meanings.h"
#import "Shared/Player/PlayerSettings.h"
#import "Shared/Sing/Sing.h"
#import "Native/Appearance/Appearance.h"
#import "Native/Navbar/Navbar.h"
#import "Native/NowPlayingBar/NowPlayingBar.h"
#import "Native/Player/NowPlaying.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/AudioSources/SGAddons.h"
#import "Redesigned/Lyrics/LyricsText.h"
#import "Redesigned/Lyrics/LyricsLook.h"
#import "Redesigned/Navbar/Navbar.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Redesigned/Kit/SGRAccent.h"

NSString *const SGRedesignedUIInfo = @"Apple Music 스타일을 적용한 Vitrine의 새 화면입니다. 기본 화면 전용 설정과 함께 사용할 수 없습니다.\n\n기본 화면에서는 Spotify의 모습을 유지하며 더 많은 부분을 직접 설정할 수 있습니다.";

// Below iOS 26 the redesign also needs SGKeyRedesignUntested (Core/SGUIMode.h): whoever calls this has
// shown the warning. Turning it off takes that back, so turning it on again warns again.
void SGSetRedesignedUI(BOOL on) {
    SGSetEnabled(SGKeyRedesign, on);
    SGSetEnabled(SGKeyRedesignUntested, on && !SGRedesignAvailable());
}

NSString *SGRedesignUntestedWarning(void) {
    return [NSString stringWithFormat:@"재설계 UI는 iOS 26의 Liquid Glass를 기반으로 합니다. iOS %@에서는 흐림 효과로 대체되며 검증되지 않았습니다. 화면 배치가 잘못되거나 Spotify가 시작 중 멈출 수 있습니다. 실행하지 못하면 다음 실행에서 기본 화면으로 돌아갑니다.",
            UIDevice.currentDevice.systemVersion];
}

// The whole look changes hands at launch, so the switch asks for the restart straight away rather than
// leaving Spotify half in the old look.
static void offerRestart(BOOL on) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Spotify 재시작"
        message:on ? @"Spotify를 다시 실행하면 재설계 UI가 적용됩니다. 지금 앱을 종료한 후 다시 여세요." : @"Spotify를 다시 실행하면 기본 화면이 적용됩니다. 지금 앱을 종료한 후 다시 여세요."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"나중에" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"지금 재시작" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { SGRestartSpotify(); }]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

// Below iOS 26 the switch stores the warning's key, not the look's: it is on only once the warning has
// been accepted, which restarts Spotify at once, so the switch never reads on for a look that is not coming.
static SGModRow *untestedRow(void) {
    SGModRow *row = SGOptionRow(@"재설계 UI", [NSString stringWithFormat:@"iOS %@에서 미검증", UIDevice.currentDevice.systemVersion], SGKeyRedesignUntested);
    row.glows = YES;
    row.info = SGRedesignedUIInfo;
    row.changed = ^(BOOL on) {
        if (!on) {
            SGSetRedesignedUI(NO);
            offerRestart(NO);
            return;
        }
        SGSetEnabled(SGKeyRedesignUntested, NO);   // the page reloads to off; the warning's button turns it on
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"재설계 UI를 켤까요?"
            message:[SGRedesignUntestedWarning() stringByAppendingString:@"\n\n적용하려면 Spotify를 재시작합니다."]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"켜고 재시작" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            SGSetRedesignedUI(YES);
            SGRestartSpotify();
        }]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    };
    return SGWithTile(row, @"sparkles", UIColor.systemIndigoColor);
}

SGModRow *SGRedesignedUIRow(void) {
    if (!SGRedesignAvailable()) return untestedRow();
    SGModRow *redesign = SGOptionRow(@"재설계 UI", nil, SGKeyRedesign);
    redesign.glows = YES;
    redesign.info = SGRedesignedUIInfo;
    redesign.changed = ^(BOOL on) {
        SGSetRedesignedUI(on);
        offerRestart(on);
    };
    return SGWithTile(redesign, @"sparkles", UIColor.systemIndigoColor);
}

// The stored look's own rows, then the font and the app icon, which work under either look on any iOS.
// Redesigned UI itself leads Mod Settings' main page.
UIViewController *SGAppearancePage(void) {
    NSMutableArray<SGModRow *> *everywhere = [NSMutableArray arrayWithArray:SGAppFontRows()];
    SGModRow *icon = SGAppIconRow();
    if (icon) [everywhere addObject:icon];
    return [[SGModPage alloc] initWithTitle:@"화면 모양" intro:SGRestartNote sections:@[
        SGSection(nil, SGRedesignedUIStored() ? SGRAppearanceRows() : SGNativeAppearanceRows()),
        SGSection(nil, everywhere),
    ] footer:nil];
}

UIViewController *SGNavbarPage(void) {
    return SGRedesignedUIStored() ? SGRNavbarSettingsPage() : SGNavbarSettingsPage();
}

// Pronunciation, romanized lines, translation, word sweeping and line meanings exist only in the redesign's lyrics view.
static UIViewController *lyricsPage(void) {
    BOOL redesigned = SGRedesignedUIStored();
    NSMutableArray<SGModRow *> *more = [NSMutableArray arrayWithObjects:SGLockScreenLyricsRow(), SGLockScreenTranslationRow(), nil];
    if (!redesigned) [more insertObject:SGGlassLyricsRow() atIndex:0];
    SGModRow *sing = SGPageRow(@"노래방", ^UIViewController *{ return SGSingSettingsPage(); });
    sing.value = ^NSString *{ return SGSingSummary(); };
    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObjects:SGSection(nil, @[SGWithTile(sing, @"music.mic", UIColor.systemRedColor)]),
                                                SGLyricsSourcesSection(redesigned), nil];
    SGModSection *timing = SGNotedSection(@"타이밍", @[SGLyricsDelayRow()],
        @"Bluetooth 헤드폰의 출력 지연에 맞춰 가사를 이 시간만큼 늦게 표시합니다. 즉시 적용됩니다.");
    if (redesigned) {
        [sections addObjectsFromArray:@[
            SGSection(@"표시", @[SGRLyricsTextSizesRow(), SGLyricsWordTimingRow(), SGLyricsRomanisedRow(), SGLyricsRomanisedReplaceRow(),
                SGRLyricsHideRow(),
                SGSwitchRow(@"가로 화면 가사", @"가사를 연 상태에서 휴대전화를 돌리세요", SGRKeyLyricsLandscape)]),
            timing,
            SGSection(@"번역", [[[@[SGLyricsTranslationLanguageRow(), SGTranslateEverySongRow()] arrayByAddingObjectsFromArray:SGOnDeviceTranslatorRows()]
                                          arrayByAddingObjectsFromArray:SGAITranslatorRows()] arrayByAddingObject:SGSavedTranslationsRow()]),
            SGSection(nil, @[SGLyricsMeaningsRow()]),
        ]];
    } else {
        [sections addObject:timing];
    }
    [sections addObject:SGSection(nil, more)];
    // The redesign's page leads with its lyrics playing in the look the page sets, and that look's presets.
    if (redesigned) return SGRLyricsSettingsPage(@"가사", @"가사 모양은 즉시 적용됩니다. 아래 설정은 Spotify 재시작 후 적용됩니다.", sections);
    return [[SGModPage alloc] initWithTitle:@"가사" intro:SGRestartNote sections:sections footer:nil];
}

// Lyrics has its own row on Mod Settings' main page, beside Sing.
UIViewController *SGLyricsSettingsPage(void) {
    return lyricsPage();
}

UIViewController *SGPlayerSettingsPage(void) {
    SGModRow *blocked = SGPageRow(@"차단한 아티스트", ^UIViewController *{ return SGArtistBlockSettingsPage(); });
    blocked.value = ^NSString *{
        return SGFlag(SGKeyArtistBlock, NO) ? @(SGBlockedArtists().count).stringValue : @"꺼짐";
    };
    BOOL native = !SGRedesignedUIStored();

    // AirPods gestures, the lock screen widget and Vibrations have rows of their own on Mod Settings' main page.
    NSMutableArray<SGModSection *> *sections = [NSMutableArray arrayWithObject:SGSection(nil, @[
        SGWithTile(SGPageRow(@"제스처", ^UIViewController *{ return SGGesturesSettingsPage(); }), @"hand.tap", UIColor.systemBlueColor),
        SGWithTile(blocked, @"person.crop.circle.badge.xmark", UIColor.systemRedColor),
    ])];
    if (native) {
        [sections addObject:SGSection(nil, @[
            SGWithTile(SGPageRow(@"미니플레이어", ^UIViewController *{ return SGNowPlayingBarSettingsPage(); }), @"rectangle.bottomthird.inset.filled", UIColor.systemPinkColor),
            SGWithTile(SGPageRow(@"대기열 및 기기", ^UIViewController *{ return SGQueueSettingsPage(); }), @"text.line.first.and.arrowtriangle.forward", UIColor.systemIndigoColor),
        ])];
        [sections addObjectsFromArray:SGNativePlayerScreenSections()];
    }
    // Switch to video is the same chip of Spotify's player under either look.
    SGModRow *video = SGHideRow(@"동영상으로 전환", @"뮤직비디오가 있는 곡의 제목 위 버튼", SGKeyHideVideoSwitch);
    // Spotify's own, under either look: a tap on the cover opens it full screen, where it turns a little with the phone.
    SGModRow *tilt = SGHideRow(@"전체 화면 커버", @"커버를 탭했을 때 여는 화면", SGKeyHideFullScreenCover);
    // The native look's Shuffle and Repeat rows are in its Hide on the player section, with their own keys.
    NSArray<SGModRow *> *hidden = native ? @[video, tilt]
        : @[SGHideRow(@"셔플", nil, SGRKeyPlayerHideShuffle), SGHideRow(@"반복", nil, SGRKeyPlayerHideRepeat), video, tilt];
    [sections addObject:SGSection(native ? nil : @"플레이어에서 숨기기", hidden)];

    [sections addObject:SGNotedSection(@"무손실", @[
        SGOptionRow(@"무손실 파일", @"Spotify 스트림 대신 본인의 FLAC 파일 재생", SGKeyLossless),
        SGPageRow(@"무손실 소스", ^UIViewController *{ return SGAudioSourcesPage(); }),
        SGPageRow(@"상세 재생 정보", ^UIViewController *{ return SGPlaybackDetailsPage(); }),
    ], @"파일 앱 › Spotify › Lossless에 FLAC 또는 ALAC 파일을 넣으세요. 제목과 길이가 일치하고 Spotify 오디오와 소리가 맞아야 재생합니다. 곡 시작이나 탐색 후 약 4초부터 전환됩니다. Spotify는 자체 스트림도 계속 받으며 다음 곡의 파일이 있으면 최저 품질을 사용합니다. 노래방이나 1× 이외의 속도에서는 Spotify 오디오를 유지합니다. 재시작 후 적용됩니다.")];

    // The redesign's page leads with a card of its player and the background's control, the background's
    // rows and the Mini player section under it.
    if (!native) return SGRPlayerSettingsPage(sections);
    return [[SGModPage alloc] initWithTitle:@"플레이어" intro:SGRestartNote sections:sections footer:nil];
}
