// The redesign's Artists page: Apple Music's logo in place of the name on an artist's page, and what the redesign
// takes off the page.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Artist.h"

UIViewController *SGRArtistSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"아티스트" intro:SGRestartNote sections:@[
        SGNotedSection(@"Apple Music", @[
            SGSwitchRow(@"아티스트 로고", @"아티스트 페이지에서 이름 대신 표시", SGRKeyArtistLogo),
        ], @"아티스트 이름만 Apple Music에 전송합니다."),
        SGSection(@"아티스트 페이지에서 숨기기", @[
            SGSwitchRow(@"동영상", @"음악 목록 및 동영상 탭에서", SGRKeyArtistHideVideos),
            SGSwitchRow(@"음악, 동영상 및 상품 탭", @"숨기면 음악 목록만 페이지에 표시됩니다", SGRKeyArtistHideTabs),
            SGHideRow(@"아티스트 추천", nil, SGRKeyArtistHidePick),
            SGHideRow(@"발매 카운트다운", @"발매 예정 음악의 사전 저장", SGRKeyArtistHideCountdown),
            SGHideRow(@"정보", nil, SGRKeyArtistHideAbout),
        ]),
    ] footer:nil];
}
