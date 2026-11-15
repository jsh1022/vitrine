// The redesign's Home page of Mod Settings: Top picks and where its cards come from, what stays on Home, and
// one switch per shelf Home has shown lately (HomeShelves.m). Every switch is read as Home lays out, so a
// change needs a restart (SGRestartNote).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Home.h"

static NSString *const kFirstShelf = @"첫 목록";

UIViewController *SGRHomeSettingsPage(void) {
    NSArray<NSString *> *shelves = SGRHomeShelvesSeen();
    NSArray<NSString *> *sources = [@[kFirstShelf] arrayByAddingObjectsFromArray:shelves];
    SGModRow *from = SGMenuRow(@"카드 소스", sources, ^NSString *{ return SGRHomeTopPicksFrom() ?: kFirstShelf; }, ^(NSInteger index) {
        if (index == 0) [NSUserDefaults.standardUserDefaults removeObjectForKey:SGRKeyHomeTopPicksFrom];
        else [NSUserDefaults.standardUserDefaults setObject:sources[(NSUInteger)index] forKey:SGRKeyHomeTopPicksFrom];
        SGPrefsChanged();
    });
    SGModRow *look = SGSwitchRow(@"홈 모양", @"추천 음악, 색상이 있는 바로가기, 제목의 글래스 버튼을 표시합니다. 끄면 기존 재설계 홈을 사용합니다", SGRKeyHomeLook);
    SGModRow *topPicks = SGRHomeTopPicksRow();
    topPicks.waitsOn = SGRKeyHomeLook;
    from.waitsOn = SGRKeyHomeTopPicks;
    SGModRow *colour = SGSwitchRow(@"추천 음악 배경색", nil, SGRKeyHomeTopPicksColour);
    colour.waitsOn = SGRKeyHomeTopPicks;
    SGModRow *heading = SGOptionRow(@"추천 음악 제목 표시", @"카드 위에 목록 제목 표시", SGRKeyHomeTopPicksHeading);
    heading.waitsOn = SGRKeyHomeTopPicks;

    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    for (NSString *identity in shelves) [rows addObject:SGShownRow(identity, nil, SGRHomeShelfHideKey(identity))];
    if (!rows.count) [rows addObject:SGStatRow(@"아직 감지되지 않음", ^NSString *{ return @""; })];

    return [[SGModPage alloc] initWithTitle:@"홈" intro:SGRestartNote sections:@[
        SGNotedSection(nil, @[look, topPicks, from, colour, heading],
                       @"현재 홈에 없는 목록은 다시 나타날 때까지 추천 음악에서 표시하지 않습니다."),
        SGSection(@"홈에서", @[
            SGShownRow(@"바로가기", nil, SGRKeyHomeHideShortcuts),
            SGShownRow(@"DJ", nil, SGRKeyHomeHideDJ),
            SGOptionRow(@"스크롤해도 제목 유지", @"홈을 스크롤해도 제목, 아바타, 버튼을 상단에 유지합니다", SGRKeyHomeKeepTitle),
            SGOptionRow(@"추천 곡", @"홈에서 제공되는 Spotify 추천 곡 목록", SGRKeyHomeSongSuggestions),
            SGOptionRow(@"동영상 및 플레이리스트 미리보기", @"홈 스크롤 중 재생되는 카드", SGRKeyHomePreviews),
        ]),
        SGNotedSection(@"음악 목록", rows, @"지난 30일간 홈에 표시된 목록입니다. 목록은 제목으로 구분하므로 Spotify 언어를 바꿔 이름이 달라지면 별도 항목으로 표시합니다."),
    ] footer:nil];
}
