// The native player's settings: Spotify's own player screen and the parts of it to hide, and the queue
// and devices flags. The Player page that holds them is App/Pages.m's.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "NowPlaying.h"

NSArray<SGModSection *> *SGNativePlayerScreenSections(void) {
    return @[
        SGSection(@"재생 화면", @[
            SGPageRow(@"아트워크 배경", ^UIViewController *{ return SGNativeArtworkSettingsPage(); }),
            SGOptionRow(@"글래스 헤더 버튼", nil, SGKeyPlayer),
            SGKillRow(@"Canvas 끄기", @"ios-feature-canvas.canvas_enabled"),
            SGFlagRow(@"시트형 플레이어", @"ios-feature-nowplaying.sheet_style_npv"),
            SGFlagRow(@"재설계 헤더", @"ios-feature-nowplaying.new_redesign_header_with_context_menu_enabled"),
            SGFlagRow(@"새 재생 진행 슬라이더", @"ios-feature-encoreexperiments.new_npv_slider_enabled"),
            SGFlagRow(@"탭하여 고정 헤더 펼치기", @"ios-feature-nowplaying.expand_sticky_header_on_tap"),
        ]),
        SGSection(@"플레이어 아래 카드 숨기기", @[
            SGHideRow(@"가사", nil, SGHideLyricsCard),
            SGHideRow(@"아티스트 정보", nil, SGHideAboutArtist),
            SGHideRow(@"관련 동영상", nil, SGHideRelatedVideos),
            SGHideRow(@"SongDNA", nil, SGHideSongDNA),
            SGHideRow(@"라이브 이벤트", nil, SGHideLiveEvents),
            SGHideRow(@"아티스트 둘러보기", nil, SGHideExploreArtist),
            SGHideRow(@"크레딧", nil, SGHideCredits),
            SGHideRow(@"상품", nil, SGHideMerch),
            SGHideRow(@"추천", nil, SGHideRecommendations),
        ]),
        SGSection(@"플레이어에서 숨기기", @[
            SGHideRow(@"한 줄 가사", nil, SGHideLyricsInline),
            SGHideRow(@"셔플", nil, SGHideShuffle),
            SGHideRow(@"반복", nil, SGHideRepeat),
            SGHideRow(@"플레이리스트에 추가", nil, SGHideAddTo),
            SGHideRow(@"대기열", nil, SGHideQueue),
            SGHideRow(@"공유", nil, SGHideShare),
            SGHideRow(@"기기에 연결", nil, SGHideConnect),
        ]),
    ];
}

SGModRow *SGGlassLyricsRow(void) {
    return SGOptionRow(@"글래스 가사", nil, SGKeyLyricsCard);
}

UIViewController *SGQueueSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"대기열 및 기기" intro:SGRestartNote sections:@[
        SGSection(@"하단 시트", @[
            SGFlagRow(@"대기열을 하단 시트로 표시", @"ios-feature-nowplaying.bottom_sheet_queue_enabled"),
            SGFlagRow(@"기기 연결을 하단 시트로 표시", @"ios-feature-nowplaying-elements.enable_connect_bottom_sheet"),
            SGFlagRow(@"동영상 전환 버튼에서 기기 연결 시트 열기", @"ios-playbackcontrol-audiovideoswitcher-impl.enable_connect_bottom_sheet"),
        ]),
        SGSection(@"대기열", @[
            SGFlagRow(@"대기열 뒤집기 전환", @"ios-feature-nowplaying.queue_flip_transition_enabled"),
            SGFlagRow(@"컨텍스트 메뉴에 다음에 재생 표시", @"ios-feature-queue.is_play_next_context_menu_enabled"),
        ]),
    ] footer:nil];
}
