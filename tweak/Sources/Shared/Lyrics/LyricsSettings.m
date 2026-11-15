// The Lyrics page's parts; App/Pages.m assembles the page.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Lyrics.h"
#import "Shared/LocalFiles/LocalLyrics.h"
#import "Shared/LockScreenLyrics/LockScreenLyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"

SGModSection *SGLyricsSourcesSection(BOOL namingSource) {
    SGModRow *sources = SGPageRow(@"소스", ^UIViewController *{ return SGLyricsSourcesPage(); });
    sources.value = ^NSString *{
        // The first one asked and how many follow it, short enough to sit beside the title.
        NSArray<NSString *> *order = SGLyricsOrder();
        if (!order.count) return @"꺼짐";
        NSString *first = SGLyricsProviderFor(order.firstObject).name;
        return order.count == 1 ? first : [NSString stringWithFormat:@"%@ +%lu", first, (unsigned long)order.count - 1];
    };
    SGModRow *imported = SGPageRow(@"가져온 LRC 파일", ^UIViewController *{ return SGImportedLRCPage(); });
    imported.value = ^NSString *{
        NSUInteger count = SGImportedLRCFiles().count;
        return count ? @(count).stringValue : @"없음";
    };
    SGModRow *words = SGOptionRow(@"단어별 타이밍 우선", @"줄 단위 가사 이후에도 단어별 타이밍이 있는 소스를 계속 조회합니다", SGKeyLyricsPreferWordTiming);
    NSMutableArray<SGModRow *> *rows = [NSMutableArray arrayWithObjects:sources, words, imported,
        SGSwitchRow(@"모든 곡에 가사 표시", @"Spotify에 가사가 없는 곡에도 표시", SGKeyLyricsAllTracks), SGSpicyLyricsKeyRow(), nil];
    // Spicy Lyrics' terms ask for its credit wherever its lines show (Shared/LyricsSources/SpicyLyrics.m), so the switch
    // says so, or its credit under the lyrics reads as the switch not working (issue #20).
    if (namingSource) [rows addObject:SGOptionRow(@"소스 표시", @"Spicy Lyrics는 이용 조건에 따라 마지막 줄 뒤에 항상 출처를 표시합니다", SGKeyLyricsCredit)];
    if (SGEeveeLyricsOn()) {
        [rows addObject:SGOptionRow(@"이 소스들을 함께 사용", @"EeveeSpotify의 가사가 실제로 꺼진 경우에만 사용하세요", SGKeyLyricsBesideEevee)];
        return SGNotedSection(@"소스", rows, @"EeveeSpotify의 가사가 켜져 있어 해당 앱이 가사 요청에 응답하며 이 소스들은 작동하지 않습니다. 두 기능이 함께 응답하면 실행 후 Spotify가 멈출 수 있습니다. 이 소스들을 사용하려면 EeveeSpotify의 설정에서 가사를 끄세요.");
    }
    return SGSection(@"소스", rows);
}

SGModRow *SGLockScreenLyricsRow(void) {
    return SGOptionRow(@"잠금 화면 가사", @"아티스트 이름 대신 현재 가사 표시", SGKeyLockScreenLyrics);
}

SGModRow *SGLockScreenTranslationRow(void) {
    SGModRow *row = SGOptionRow(@"잠금 화면 번역", @"번역이 있으면 현재 가사 대신 번역 표시", SGKeyLockScreenTranslation);
    row.waitsOn = SGKeyLockScreenLyrics;
    return row;
}

SGModRow *SGLyricsTranslationLanguageRow(void) {
    SGModRow *row = SGChoiceRow(@"번역 언어", nil, SGKeyLyricsTranslationLanguage, SGLyricsTranslationLanguageNames(), 0);
    row.choiceFooter = @"언어를 선택하면 번역이 없는 가사에 Musixmatch 커뮤니티 번역을 가져오며, 곡 ID를 Musixmatch에 보냅니다. 모든 언어는 가사에 포함된 첫 번역을 표시합니다. 가사 번역 메뉴의 대상 언어로도 사용하며 다른 언어의 곡에만 번역 메뉴를 표시합니다. 모든 언어를 선택하면 iPhone의 언어를 사용합니다.";
    return row;
}

// Only the redesign's lyrics view draws it, and every one there is redrawn as the switch flips.
SGModRow *SGLyricsRomanisedRow(void) {
    SGModRow *row = SGOptionRow(@"로마자 가사", @"다른 문자로 된 가사를 로마자로 함께 표시", SGKeyLyricsRomanised);
    row.changed = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsRomanisedDidChangeNotification object:nil];
    };
    return row;
}

SGModRow *SGLyricsRomanisedReplaceRow(void) {
    SGModRow *row = SGOptionRow(@"원문 대신 표시", @"원문 문자 대신 로마자로 표시", SGKeyLyricsRomanisedReplace);
    row.waitsOn = SGKeyLyricsRomanised;
    row.changed = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsRomanisedDidChangeNotification object:nil];
    };
    return row;
}

// Only the redesign's lyrics view sweeps words.
SGModRow *SGLyricsWordTimingRow(void) {
    return SGOptionRow(@"단어 타이밍 추정", nil, SGKeyLyricsSimulateWords);
}

// Read wherever lines are timed, so it applies as the thumb moves.
SGModRow *SGLyricsDelayRow(void) {
    return SGSliderRow(@"지연", nil, 0, 1000, 25, ^double { return SGKaraokeDelayMs(); },
                       ^(double value) { SGSetInt(SGKeyLyricsDelay, lround(value)); },
                       ^NSString *(double value) { return [NSString stringWithFormat:@"%ld ms", lround(value)]; });
}
