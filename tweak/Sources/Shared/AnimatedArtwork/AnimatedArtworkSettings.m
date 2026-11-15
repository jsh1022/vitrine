// What the lock screen fills the screen with, the lyrics' style and whether the downloads run in Low Data
// Mode. iOS 26 and up only.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "AnimatedArtwork.h"
#import "Shared/Haptics/SGHapticRelay.h"

SGLockArtwork SGLockScreenArtwork(void) {
    if (@available(iOS 26.0, *)) {
        // The old switch's YES and NO read as Moving artwork and Off, the enum's first two.
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGMigrateKey(SGKeyLockScreenMotion, SGKeyLockScreenArtwork); });
        return (SGLockArtwork)SGInt(SGKeyLockScreenArtwork, SGLockArtworkOff);
    }
    return SGLockArtworkOff;
}

NSArray *SGLockScreenMotionRows(void) {
    if (@available(iOS 26.0, *)) {
        SGLockScreenArtwork();   // moves the old switch over before the row reads the new key
        SGModRow *style = SGChoiceRow(@"가사 스타일", @"정지는 가사를 한 번 그리며, 애니메이션은 뒤의 커버를 부드럽게 움직입니다. 움직이는 아트워크가 없는 곡에 사용",
                                      SGKeyLockScreenLyricsStyle, @[@"정지", @"애니메이션"], 0);
        style.visible = ^BOOL { return SGLockArtworkShowsLyrics(SGLockScreenArtwork()); };
        SGModRow *lowData = SGOptionRow(@"저데이터 모드에서 다운로드", @"곡당 최대 약 7 MB의 움직이는 아트워크", SGKeyMotionLowData);
        lowData.visible = ^BOOL {
            SGLockArtwork artwork = SGLockScreenArtwork();
            return artwork == SGLockArtworkMotion || artwork == SGLockArtworkEverySong || artwork == SGLockArtworkMotionLyrics;
        };
        SGModRow *sources = SGMotionSourcesRow();
        sources.visible = lowData.visible;
        SGModRow *star = SGOptionRow(@"별표로 전환", @"잠금 화면 위젯의 별표는 움직이는 아트워크와 가사를 전환하며 Spotify의 좋아요 및 싫어요 버튼을 대신합니다",
                                     SGKeyLockScreenStar);
        star.visible = ^BOOL { return SGLockScreenArtwork() != SGLockArtworkOff; };
        return @[
            SGChoiceRow(@"전체 화면 아트워크", @"Canvas, Apple Music의 움직이는 커버 또는 한 줄씩 표시되는 가사를 사용합니다. 모든 곡은 움직이는 아트워크가 없는 곡에도 커버와 흐림 애니메이션을 표시합니다. 가사와 움직이는 아트워크는 Canvas 또는 움직이는 커버 위에 가사를 표시합니다.",
                        SGKeyLockScreenArtwork, @[@"꺼짐", @"움직이는 아트워크", @"가사", @"모든 곡", @"가사와 움직이는 아트워크"],
                        SGLockArtworkOff),
            style,
            star,
            sources,
            lowData,
        ];
    }
    // Below iOS 26 with a jailbreak the add-on in SpringBoard draws the cover full screen itself, in place of the row that
    // says the lock screen needs iOS 26. iOS 26 and later never come here: their own lock screen artwork is the rows above.
    if (SGHapticEverywhereOffered()) {
        SGModRow *cover = SGOptionRow(@"큰 커버에 Canvas 사용", @"잠금 화면 플레이어의 커버를 탭하면 시계 아래 위젯을 숨기고 화면 너비로 펼칩니다. 지원되는 곡은 Canvas 또는 Apple Music의 움직이는 커버를 표시합니다. Vitrine Addon이 그립니다", SGKeyLockCoverAddon);
        cover.changed = ^(BOOL on) {
            SGHapticRelaySendLockArt();
            if (on && !SGHapticRelayAvailable()) SGHapticAddonExplain(@"전체 화면 아트워크");
        };
        // The add-on's update, offered here as on the Vibrations page: it draws this screen too.
        SGModRow *update = SGActionRow(@"Vitrine Addon 업데이트", @"이 Vitrine에는 더 최신 Addon이 포함되어 있습니다", ^{ SGHapticAddonShareSoon(); });
        update.visible = ^BOOL { return SGHapticAddonOutdated(); };
        return @[cover, update];
    }
    return @[SGLockScreenArtworkNeedsRow()];
}

// Below iOS 26 the section stays, with one row that says why there is nothing to pick.
SGModRow *SGLockScreenArtworkNeedsRow(void) {
    return SGStatActionRow(@"전체 화면 아트워크", nil, ^NSString *{ return @"iOS 26 필요"; }, ^{
        NSString *message = [NSString stringWithFormat:@"이 iPhone의 버전은 iOS %@입니다. 앱의 움직이는 아트워크는 iOS 26부터 지원하므로 업데이트하면 Canvas와 Apple Music의 움직이는 커버를 표시할 수 있습니다.", UIDevice.currentDevice.systemVersion];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"iOS 26 필요" message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
        [SGTopController() presentViewController:alert animated:YES completion:nil];
    });
}
