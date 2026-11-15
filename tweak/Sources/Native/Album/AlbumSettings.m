#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Album.h"

UIViewController *SGAlbumSettingsPage(void) {
    NSArray<SGModSection *> *sections = @[
        SGSection(@"헤더", @[
            SGOptionRow(@"아트워크 배경", nil, SGKeyAlbumBackdrop),
        ]),
        SGSection(@"헤더에서 숨기기", @[
            SGHideRow(@"둘러보기 (동영상 목록)", nil, SGHideAlbumExplore),
            SGHideRow(@"보관함에 추가", nil, SGHideAlbumAddTo),
            SGHideRow(@"다운로드", nil, SGHideAlbumDownload),
            SGHideRow(@"추가 옵션", nil, SGHideAlbumMore),
        ]),
        SGNotedSection(@"페이지에서 숨기기", @[
            SGHideRow(@"이 아티스트의 다른 음악", nil, SGHideAlbumMoreBy),
            SGHideRow(@"관련 뮤직비디오", nil, SGHideAlbumVideos),
            SGHideRow(@"공연", nil, SGHideAlbumConcerts),
            SGHideRow(@"상품", nil, SGHideAlbumMerch),
            SGHideRow(@"추천 음악", nil, SGHideAlbumYouMightLike),
        ], @"Spotify가 영어로 설정된 경우에만 작동합니다."),
    ];
    return [[SGModPage alloc] initWithTitle:@"앨범" intro:nil sections:sections footer:nil];
}
