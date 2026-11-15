#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "NowPlayingBar.h"

UIViewController *SGNowPlayingBarSettingsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"미니플레이어" intro:SGRestartNote sections:@[
        SGSection(nil, @[
            SGHideRow(@"기기 버튼 숨기기", nil, SGHideBarConnect),
        ]),
        SGSection(@"Spotify 플래그", @[
            SGFlagRow(@"곡 정보 두 줄 표시", @"ios-feature-nowplayingbar.two_lines_information_unit"),
            SGFlagRow(@"저장 버튼", @"ios-feature-nowplayingbar.add_button"),
            SGFlagRow(@"대기열 배지", @"ios-feature-nowplayingbar.queue_badge"),
            SGFlagRow(@"길게 누르고 드래그하여 크기 조절", @"ios-feature-nowplayingbar.hold_and_drag_to_resize"),
            SGFlagRow(@"미니플레이어 동영상", @"ios-feature-nowplaying.video_in_miniplayer"),
            SGFlagRow(@"미니플레이어에서 커버로 이어지는 애니메이션", @"ios-feature-nowplaying.bartocoverart_animation_enabled"),
            SGFlagRow(@"미니플레이어 전환 애니메이션", @"ios-feature-nowplaying.miniplayer_transition_animations"),
        ]),
    ] footer:nil];
}
