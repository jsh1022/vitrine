#import "Settings/SGModPage.h"
#import "Playlist.h"

UIViewController *SGPlaylistSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Playlists" intro:nil sections:@[
        SGSection(@"Header", @[
            SGOptionRow(@"아트워크 배경", nil, SGKeyPlaylistBackdrop),
        ]),
        SGSection(@"Hide in the playlist header", @[
            SGHideRow(@"Cover artwork", nil, SGHidePlaylistArtwork),
            SGHideRow(@"Description", nil, SGHidePlaylistDescription),
            SGHideRow(@"Creator and collaborators", nil, SGHidePlaylistCreator),
            SGHideRow(@"Length and saves", nil, SGHidePlaylistLength),
        ]),
        SGSection(@"Hide playlist buttons", @[
            SGHideRow(@"Video", nil, SGHidePlaylistVideo),
            SGHideRow(@"Add to library", nil, SGHidePlaylistAddTo),
            SGHideRow(@"다운로드", nil, SGHidePlaylistDownload),
            SGHideRow(@"공유", nil, SGHidePlaylistShare),
            SGHideRow(@"더 보기", nil, SGHidePlaylistMore),
        ]),
        SGSection(@"곡 목록 위에서 숨기기", @[
            SGHideRow(@"Curation pills", nil, SGHidePlaylistPills),
            SGHideRow(@"Find and sort bar", nil, SGHidePlaylistFind),
        ]),
    ] footer:nil];
}
