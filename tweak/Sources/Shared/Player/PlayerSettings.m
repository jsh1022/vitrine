// The player's settings that do not depend on the look: the lock screen widget's flags.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "PlayerSettings.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Lyrics/Lyrics.h"

// Widget first: the line in place of the artist (on the Lyrics page too, the same switch) and Like and dislike,
// the one lock screen control a song gets, which the Artwork section's star takes the place of
// (Shared/AnimatedArtwork/LockScreenStar.x locks the flag off). Spotify's flags for podcasts, audiobooks and its
// own lock screen artwork stay on the All flags page: the Artwork section is the mod's.
UIViewController *SGLockScreenWidgetPage(void) {
    SGModRow *likes = SGFlagRow(@"좋아요 및 싫어요 버튼", @"ios-feature-lockscreen.like_dislike_enabled");
    likes.subtitle = @"별표로 전환이 켜져 있으면 별표가 대신 표시되며 이 항목은 꺼진 상태로 잠깁니다";
    return [[SGModPage alloc] initWithTitle:@"잠금 화면" intro:SGRestartNote sections:@[
        SGSection(@"위젯", @[SGLockScreenLyricsRow(), SGLockScreenTranslationRow(), likes]),
        SGSection(@"아트워크", SGLockScreenMotionRows()),
    ] footer:nil];
}
