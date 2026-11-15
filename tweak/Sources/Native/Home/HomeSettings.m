#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Home.h"
#import "Native/Playlist/Playlist.h"
#import "Native/Artist/Artist.h"
#import "Native/Album/Album.h"

static SGModRow *choiceRow(NSString *title, NSString *subtitle, SGHomeChoice choice) {
    return SGChoiceRow(title, subtitle, SGHomeChoiceKey(choice), SGHomeChoiceNames(choice),
                       SGHomeChoiceDefault(choice));
}

UIViewController *SGHomeGradientPage(void) {
    return [[SGModPage alloc] initWithTitle:@"그라데이션"
                                      intro:@"켜거나 끈 상태는 Spotify를 재시작하면 적용됩니다."
                                   sections:@[
        SGSection(@"그라데이션", @[
            SGOptionRow(@"표시", nil, SGKeyHomeGradient),
            choiceRow(@"Color", nil, SGHomeChoiceTint),
            choiceRow(@"강도", nil, SGHomeChoiceStrength),
            choiceRow(@"Height", nil, SGHomeChoiceHeight),
        ]),
    ] footer:nil];
}

static UIViewController *libraryPage(void) {
    return [[SGModPage alloc] initWithTitle:@"보관함" intro:nil sections:@[
        SGSection(@"보관함", @[
            SGFlagRow(@"촘촘한 행", @"ios-feature-yourlibaryx.denser_rows_enabled"),
            SGFlagRow(@"최근 업데이트 순으로 플레이리스트 정렬", @"ios-feature-yourlibaryx.recently_updated_playlists_sort_enabled"),
            SGFlagRow(@"최근 업데이트 순으로 아티스트 정렬", @"ios-feature-yourlibaryx.recently_updated_artists_sort_enabled"),
            SGFlagRow(@"최근 항목", @"ios-feature-yourlibaryx.recents_enabled"),
            SGFlagRow(@"최근 항목 정렬 순서", @"ios-feature-yourlibaryx.recents_sort_order_enabled"),
            SGFlagRow(@"보관함 설정", @"ios-feature-yourlibaryx.library_settings_enabled"),
            SGFlagRow(@"보관함 Pro", @"ios-feature-yourlibaryx.your_library_pro_enabled"),
        ]),
    ] footer:nil];
}

UIViewController *SGHomeSettingsPage(void) {
    // The row reads its own state out, so the section says which color is set without being opened.
    SGModRow *gradient = SGPageRow(@"그라데이션", ^UIViewController *{ return SGHomeGradientPage(); });
    gradient.value = ^NSString *{
        if (!SGFlag(SGKeyHomeGradient, NO)) return @"꺼짐";
        return SGHomeChoiceNames(SGHomeChoiceTint)[(NSUInteger)SGHomeChoiceValue(SGHomeChoiceTint)];
    };

    NSArray<SGModSection *> *sections = @[
        SGSection(nil, @[
            SGWithSymbol(SGPageRow(@"플레이리스트", ^UIViewController *{ return SGPlaylistSettingsPage(); }), @"music.note.list"),
            SGWithSymbol(SGPageRow(@"보관함", ^UIViewController *{ return libraryPage(); }), @"books.vertical"),
            SGWithSymbol(SGPageRow(@"앨범", ^UIViewController *{ return SGAlbumSettingsPage(); }), @"square.stack"),
            SGWithSymbol(SGPageRow(@"아티스트", ^UIViewController *{ return SGArtistSettingsPage(); }), @"music.mic"),
        ]),
        SGSection(@"홈", @[
            SGWithSymbol(gradient, @"rectangle.tophalf.inset.filled"),
            SGFlagRow(@"당겨서 새로 고침", @"ios-home-evopage-impl.pull_to_refresh_enabled"),
        ]),
        SGSection(@"홈에서 숨기기", @[
            SGHideRow(@"필터 버튼", nil, SGHideHomePills),
            SGHideRow(@"바로가기 격자", nil, SGHideHomeShortcuts),
            SGHideRow(@"홍보 카드", nil, SGHideHomePromo),
            SGHideRow(@"미리보기 카드", nil, SGHideHomePreviews),
            SGHideRow(@"DJ 카드", nil, SGHideHomeDJ),
            SGKillRow(@"DJ 버튼", @"ios-home-evopage-impl.idj_show_dj_button"),
            SGKillRow(@"DJ 베타 배지", @"ios-home-evopage-impl.dj_mdc_beta_badge_enabled"),
        ]),
    ];
    return [[SGModPage alloc] initWithTitle:@"홈 및 보관함" intro:nil sections:sections footer:nil];
}
