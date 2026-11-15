// The redesign's Albums page: Apple Music's animated covers on album pages, whether their downloads run in Low
// Data Mode, and what the redesign takes off the page.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Album.h"

UIViewController *SGRAlbumSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"앨범" intro:SGRestartNote sections:@[
        SGNotedSection(@"Apple Music", @[
            SGSwitchRow(@"움직이는 커버", @"지원되는 앨범 상단에 표시 · 앨범당 약 5 MB", SGRKeyAlbumMotion),
            SGOptionRow(@"저데이터 모드에서 다운로드", nil, SGKeyMotionLowData),
        ], @"앨범 이름만 Apple Music에 전송합니다. 저전력 모드에서는 커버가 움직이지 않습니다."),
        SGSection(@"앨범 페이지에서 숨기기", @[
            SGSwitchRow(@"중복된 곡 아티스트", @"앨범 아티스트와 같은 곡의 아티스트 표시", SGRKeyAlbumHideTrackArtists),
        ]),
        SGNotedSection(@"앨범 곡 목록 아래에서 숨기기", @[
            SGSwitchRow(@"이 아티스트의 다른 음악", nil, SGRKeyAlbumHideMoreBy),
            SGSwitchRow(@"관련 뮤직비디오", nil, SGRKeyAlbumHideVideos),
            SGSwitchRow(@"공연", nil, SGRKeyAlbumHideConcerts),
            SGSwitchRow(@"상품", nil, SGRKeyAlbumHideMerch),
            SGSwitchRow(@"추천 음악", nil, SGRKeyAlbumHideYouMightLike),
            SGSwitchRow(@"그 외 모두", @"Spotify가 제공하는 그 외 모든 섹션", SGRKeyAlbumHideOther),
        ], @"섹션은 영어 이름으로 구분합니다. Spotify가 다른 언어이면 그 외 모두가 모든 추가 섹션에 적용됩니다."),
    ] footer:nil];
}
