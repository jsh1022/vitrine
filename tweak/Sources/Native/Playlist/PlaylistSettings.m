#import "Settings/SGModPage.h"
#import "Playlist.h"

UIViewController *SGPlaylistSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"플레이리스트" intro:nil sections:@[
        SGSection(@"헤더", @[
            SGOptionRow(@"아트워크 배경", nil, SGKeyPlaylistBackdrop),
        ]),
        SGSection(@"플레이리스트 헤더에서 숨기기", @[
            SGHideRow(@"커버 아트워크", nil, SGHidePlaylistArtwork),
            SGHideRow(@"설명", nil, SGHidePlaylistDescription),
            SGHideRow(@"제작자 및 공동 작업자", nil, SGHidePlaylistCreator),
            SGHideRow(@"길이 및 저장 수", nil, SGHidePlaylistLength),
        ]),
        SGSection(@"플레이리스트 버튼 숨기기", @[
            SGHideRow(@"동영상", nil, SGHidePlaylistVideo),
            SGHideRow(@"보관함에 추가", nil, SGHidePlaylistAddTo),
            SGHideRow(@"다운로드", nil, SGHidePlaylistDownload),
            SGHideRow(@"공유", nil, SGHidePlaylistShare),
            SGHideRow(@"더 보기", nil, SGHidePlaylistMore),
        ]),
        SGSection(@"곡 목록 위에서 숨기기", @[
            SGHideRow(@"추천 구성 버튼", nil, SGHidePlaylistPills),
            SGHideRow(@"검색 및 정렬 막대", nil, SGHidePlaylistFind),
        ]),
    ] footer:nil];
}
