// The native player's settings: Spotify's own player screen and the parts of it to hide, and the queue
// and devices flags. The Player page that holds them is App/Pages.m's.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "NowPlaying.h"

NSArray<SGModSection *> *SGNativePlayerScreenSections(void) {
    return @[
        SGSection(@"Player screen", @[
            SGPageRow(@"아트워크 배경", ^UIViewController *{ return SGNativeArtworkSettingsPage(); }),
            SGOptionRow(@"글래스 헤더 버튼", nil, SGKeyPlayer),
            SGKillRow(@"Disable Canvas", @"ios-feature-canvas.canvas_enabled"),
            SGFlagRow(@"Sheet style player", @"ios-feature-nowplaying.sheet_style_npv"),
            SGFlagRow(@"Redesigned header", @"ios-feature-nowplaying.new_redesign_header_with_context_menu_enabled"),
            SGFlagRow(@"New progress slider", @"ios-feature-encoreexperiments.new_npv_slider_enabled"),
            SGFlagRow(@"Expand the sticky header on tap", @"ios-feature-nowplaying.expand_sticky_header_on_tap"),
        ]),
        SGSection(@"플레이어 아래 카드 숨기기", @[
            SGHideRow(@"가사", nil, SGHideLyricsCard),
            SGHideRow(@"아티스트 정보", nil, SGHideAboutArtist),
            SGHideRow(@"Related videos", nil, SGHideRelatedVideos),
            SGHideRow(@"SongDNA", nil, SGHideSongDNA),
            SGHideRow(@"Live events", nil, SGHideLiveEvents),
            SGHideRow(@"Explore the artist", nil, SGHideExploreArtist),
            SGHideRow(@"Credits", nil, SGHideCredits),
            SGHideRow(@"Merch", nil, SGHideMerch),
            SGHideRow(@"Recommendations", nil, SGHideRecommendations),
        ]),
        SGSection(@"플레이어에서 숨기기", @[
            SGHideRow(@"한 줄 가사", nil, SGHideLyricsInline),
            SGHideRow(@"셔플", nil, SGHideShuffle),
            SGHideRow(@"반복", nil, SGHideRepeat),
            SGHideRow(@"Add to playlist", nil, SGHideAddTo),
            SGHideRow(@"대기열", nil, SGHideQueue),
            SGHideRow(@"Share", nil, SGHideShare),
            SGHideRow(@"Connect to a device", nil, SGHideConnect),
        ]),
    ];
}

SGModRow *SGGlassLyricsRow(void) {
    return SGOptionRow(@"Glass lyrics", nil, SGKeyLyricsCard);
}

UIViewController *SGQueueSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"대기열 및 기기" intro:SGRestartNote sections:@[
        SGSection(@"Bottom sheets", @[
            SGFlagRow(@"Queue as a bottom sheet", @"ios-feature-nowplaying.bottom_sheet_queue_enabled"),
            SGFlagRow(@"Connect as a bottom sheet", @"ios-feature-nowplaying-elements.enable_connect_bottom_sheet"),
            SGFlagRow(@"Connect sheet from the video switcher", @"ios-playbackcontrol-audiovideoswitcher-impl.enable_connect_bottom_sheet"),
        ]),
        SGSection(@"대기열", @[
            SGFlagRow(@"Queue flip transition", @"ios-feature-nowplaying.queue_flip_transition_enabled"),
            SGFlagRow(@"Play next in the context menu", @"ios-feature-queue.is_play_next_context_menu_enabled"),
        ]),
    ] footer:nil];
}
