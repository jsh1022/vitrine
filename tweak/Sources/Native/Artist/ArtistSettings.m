#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Artist.h"

UIViewController *SGArtistSettingsPage(void) {
    NSArray<SGModSection *> *sections = @[
        SGSection(@"사진", @[
            SGOptionRow(@"흐림으로 페이드", nil, SGKeyArtistPhotoFade),
        ]),
        SGSection(@"헤더에서 숨기기", @[
            SGHideRow(@"둘러보기 (동영상 목록)", nil, SGHideArtistExplore),
            SGHideRow(@"팔로우", nil, SGHideArtistFollow),
            SGHideRow(@"추가 옵션", nil, SGHideArtistMore),
            SGHideRow(@"셔플", nil, SGHideArtistShuffle),
            SGHideRow(@"인증 배지", nil, SGHideArtistVerified),
            SGHideRow(@"월간 청취자", nil, SGHideArtistListeners),
        ]),
        SGSection(@"탭", @[
            SGHideRow(@"탭 막대 숨기기", nil, SGHideArtistTabBar),
        ]),
        SGNotedSection(@"페이지에서 숨기기", @[
            SGHideRow(@"좋아요 표시한 곡", nil, SGHideArtistLikedSongs),
            SGHideRow(@"인기 곡", nil, SGHideArtistPopular),
            SGHideRow(@"아티스트 추천", nil, SGHideArtistPick),
            SGHideRow(@"인기 발매 음악", nil, SGHideArtistReleases),
            SGHideRow(@"참여 음악", nil, SGHideArtistFeaturing),
            SGHideRow(@"뮤직비디오", nil, SGHideArtistVideos),
            SGHideRow(@"정보", nil, SGHideArtistAbout),
            SGHideRow(@"아티스트 플레이리스트", nil, SGHideArtistPlaylists),
            SGHideRow(@"팬들이 좋아하는 아티스트", nil, SGHideArtistFansAlsoLike),
            SGHideRow(@"참여 앨범", nil, SGHideArtistAppearsOn),
            SGHideRow(@"발견한 곳", nil, SGHideArtistDiscoveredOn),
        ], @"Spotify가 영어로 설정된 경우에만 작동합니다."),
        SGSection(@"Spotify 기본", @[
            SGFlagRow(@"헤더의 공유 버튼", @"ios-creator-impl.share_in_action_row_enabled_artist"),
            SGFlagRow(@"탐색 막대의 추가 옵션", @"ios-creator-impl.context_menu_in_navigation_bar_enabled_artist"),
            SGFlagRow(@"주요 공동 작업자", @"ios-creator-impl.is_top_collaborators_enabled"),
            SGFlagRow(@"아티스트 정보", @"ios-creator-impl.is_artist_facts_enabled"),
        ]),
    ];
    return [[SGModPage alloc] initWithTitle:@"아티스트" intro:nil sections:sections footer:nil];
}
