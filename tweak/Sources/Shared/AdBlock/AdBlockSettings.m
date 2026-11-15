#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "AdBlock.h"
#import "Shared/Privacy/Privacy.h"

NSString *const SGFakePremiumWarning = @"Spotify가 삭제를 요청했던 EeveeSpotify 기능이며 여기서는 검증되지 않았습니다. 강제 로그아웃이나 더 심한 계정 문제가 발생할 수 있습니다. Premium 계정에는 이점이 없습니다.";

// Every switch here forces a flag Spotify ships on to off, so the titles name the blocking: on stops
// the thing, off is Spotify's own value. Hide ads and Hide upsells already force the first two
// sections off, which locks those rows.
static UIViewController *adFlagsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"광고 및 업그레이드 권유 플래그" intro:SGRestartNote sections:@[
        SGNotedSection(@"광고", @[
            SGKillRow(@"앱 실행 시 광고 차단", @"ios-feature-adonappopen.enabled"),
            SGKillRow(@"광고 유도 카드 차단", @"ios-feature-adonappopen.cta_card_enabled"),
        ], @"광고 숨기기가 켜져 있어 잠겨 있습니다."),
        SGNotedSection(@"업그레이드 권유", @[
            SGKillRow(@"셔플 전환 업그레이드 권유 숨기기", @"ios-feature-shuffletoggleupsell.is_enabled_pt2"),
            SGKillRow(@"동영상 플레이어의 셔플 업그레이드 권유 숨기기", @"ios-feature-nowplaying-modes.video_first_shuffle_upsell_enabled"),
        ], @"업그레이드 권유 숨기기가 켜져 있어 잠겨 있습니다."),
        SGSection(@"개입 줄이기", @[
            SGFlagRow(@"개입 줄이기", @"ios-messaging-reduceinterventions-impl.enabled"),
        ]),
        SGSection(@"도움말", @[
            SGKillRow(@"스마트 셔플 도움말 숨기기", @"ios-messaging-reduceinterventions-impl.enable_message_smart_shuffle_helper_tooltip"),
            SGKillRow(@"데이터 절약 도움말 숨기기", @"ios-feature-nowplayingbar.data_saver_tooltip"),
            SGKillRow(@"플레이어 추천 업그레이드 권유 숨기기", @"ios-messaging-reduceinterventions-impl.enable_message_reinvent_free_n_p_v_suggestions_upsell"),
            SGKillRow(@"AI 플레이리스트 생성 도움말 숨기기", @"ios-messaging-reduceinterventions-impl.enable_message_your_library_ai_playlist_creation_tooltip"),
            SGKillRow(@"동영상 피드 둘러보기 도움말 숨기기", @"ios-messaging-reduceinterventions-impl.enable_message_watch_feed_entity_explorer_tooltip"),
            SGKillRow(@"계정 전환 도움말 숨기기", @"ios-messaging-reduceinterventions-impl.enable_message_account_switching_tooltip"),
            SGKillRow(@"공연 알림 도움말 숨기기", @"ios-messaging-reduceinterventions-impl.enable_message_live_events_concert_notifications_tooltip"),
            SGKillRow(@"라이브 이벤트 도움말 숨기기", @"ios-messaging-reduceinterventions-impl.enable_message_live_events_event_entity_safe_tooltip"),
            SGKillRow(@"라이브 이벤트 장소 도움말 숨기기", @"ios-messaging-reduceinterventions-impl.enable_message_live_events_event_entity_venuename_header_tooltip"),
            SGKillRow(@"Puffin 안내 숨기기", @"ios-messaging-reduceinterventions-impl.enable_message_puffin_nudge_end_optimization"),
        ]),
    ] footer:nil];
}

// The switches first and what they have stopped last, so the counters bury no setting.
UIViewController *SGAdsSettingsPage(void) {
    NSMutableArray<SGModRow *> *counts = [NSMutableArray array];
    for (NSString *label in SGAdBlockLabels()) {
        [counts addObject:SGStatRow(label, ^NSString *{
            NSUInteger checked = SGAdBlockChecked(label);
            return checked == NSNotFound ? @(SGAdBlockCount(label)).stringValue
                : [NSString stringWithFormat:@"%lu개 / %lu개", (unsigned long)SGAdBlockCount(label), (unsigned long)checked];
        })];
    }
    [counts addObject:SGStatRow(@"합계", ^NSString *{
        return @(SGAdBlockCount(nil)).stringValue;
    })];
    [counts addObject:SGActionRow(@"카운터 초기화", nil, ^{ SGResetAdBlock(); })];

    SGModRow *fakePremium = SGOptionRow(@"Spoof Premium", nil, SGKeyFakePremium);
    fakePremium.warning = SGFakePremiumWarning;

    // The redesign's Search keeps only its category cards, so the video carousel switch is the native look's.
    NSMutableArray<SGModRow *> *ads = [NSMutableArray arrayWithObjects:
        SGWithSymbol(SGOptionRow(@"광고 숨기기", nil, SGKeyHideAds), @"speaker.slash"),
        SGWithSymbol(SGOptionRow(@"업그레이드 권유 숨기기", nil, SGKeyHideUpsells), @"hand.raised"), nil];
    if (!SGRedesignedUIStored()) [ads addObject:SGWithSymbol(SGOptionRow(@"검색의 동영상 목록 숨기기", nil, SGKeyHideSearchVideos), @"play.rectangle.on.rectangle")];
    [ads addObject:SGWithSymbol(SGPageRow(@"광고 및 업그레이드 권유 플래그", ^UIViewController *{ return adFlagsPage(); }), @"flag")];

    return [[SGModPage alloc] initWithTitle:@"Premium, 광고 및 개인정보" intro:SGRestartNote sections:@[
        SGNotedSection(@"광고", ads, @"곡 사이 오디오 광고 차단에는 Spoof Premium이 필요합니다."),
        SGNotedSection(@"Premium", @[
            SGWithSymbol(fakePremium, @"crown"),
        ], @"무료 계정 전용입니다."),
        SGPrivacySection(),
        SGNotedSection(@"차단한 광고 수", counts,
                       @"\"214개 중 3개\"는 검사한 214개 중 3개를 차단했다는 뜻입니다. 0개 중 0개는 Spotify가 요청하지 않아 현재 버전에서 해당 차단이 작동하지 않는다는 뜻입니다."),
        SGPrivacyCountersSection(),
    ] footer:nil];
}
