// The redesign's Albums page: Apple Music's animated covers on album pages, whether their downloads run in Low
// Data Mode, and what the redesign takes off the page.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Album.h"

UIViewController *SGRAlbumSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"앨범" intro:SGRestartNote sections:@[
        SGNotedSection(@"Apple Music", @[
            SGSwitchRow(@"Animated covers", @"At the top of an album that has one, about 5 MB each", SGRKeyAlbumMotion),
            SGOptionRow(@"저데이터 모드에서 다운로드", nil, SGKeyMotionLowData),
        ], @"Only the album's name is sent to Apple Music. A cover stays still in Low Power Mode."),
        SGSection(@"Hide on an album's page", @[
            SGSwitchRow(@"Repeated track artists", @"The artist under a track when it is the album's own", SGRKeyAlbumHideTrackArtists),
        ]),
        SGNotedSection(@"앨범 곡 목록 아래에서 숨기기", @[
            SGSwitchRow(@"More by the artist", nil, SGRKeyAlbumHideMoreBy),
            SGSwitchRow(@"Related music videos", nil, SGRKeyAlbumHideVideos),
            SGSwitchRow(@"Concerts", nil, SGRKeyAlbumHideConcerts),
            SGSwitchRow(@"상품", nil, SGRKeyAlbumHideMerch),
            SGSwitchRow(@"You might also like", nil, SGRKeyAlbumHideYouMightLike),
            SGSwitchRow(@"그 외 모두", @"Any other section Spotify sends", SGRKeyAlbumHideOther),
        ], @"Sections are told apart by their English names. With Spotify in another language, Everything else "
           @"covers them all."),
    ] footer:nil];
}
