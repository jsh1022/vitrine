// Labs: Spotify's flags for features it built and did not ship; every row forces one flag.
#import "Settings/SGModPage.h"
#import "Flags.h"

static int compareKey(const void *key, const void *def) {
    return strcmp(key, ((const SGFlagDef *)def)->key);
}

// Only the rows for flags this Spotify has: the table comes from the IPA the build is for, and a flag
// it lacks would force nothing. A section left empty goes too.
static NSArray<SGModSection *> *known(NSArray<SGModSection *> *sections) {
    NSMutableArray<SGModSection *> *kept = [NSMutableArray array];
    for (SGModSection *section in sections) {
        NSIndexSet *rows = [section.rows indexesOfObjectsPassingTest:^BOOL(SGModRow *row, NSUInteger i, BOOL *stop) {
            return !row.flag || bsearch(row.key.UTF8String, SGFlagTable, SGFlagCount, sizeof *SGFlagTable, compareKey);
        }];
        if (!rows.count) continue;
        section.rows = [section.rows objectsAtIndexes:rows];
        [kept addObject:section];
    }
    return kept;
}

static UIViewController *martiniPage(void) {
    return [[SGModPage alloc] initWithTitle:@"AI Chat (Martini)" intro:SGRestartNote sections:known(@[
        SGSection(@"홈에서", @[
            SGFlagRow(@"채팅 진입점", @"ios-home-evopage-impl.interactive_entrypoint_enabled"),
            SGFlagRow(@"Martini 연결", @"ios-home-evopage-impl.interactive_entrypoint_martini_enabled"),
            SGFlagRow(@"떠 있는 채팅", @"ios-home-evopage-impl.interactive_entrypoint_floating_chat_enabled"),
            SGFlagRow(@"마이크", @"ios-home-evopage-impl.interactive_entrypoint_mic_enabled"),
            SGFlagRow(@"빛나는 버튼", @"ios-home-evopage-impl.interactive_entrypoint_pill_glow_enabled"),
        ]),
        SGSection(@"채팅", @[
            SGFlagRow(@"의도 선택 버튼", @"ios-martini-floatingchat-impl.intent_pills_enabled"),
            SGFlagRow(@"생각 중 상태", @"ios-martini-floatingchat-impl.thinking_states_enabled"),
            SGFlagRow(@"음성 녹음", @"ios-martini-floatingchat-impl.voice_recording_enabled"),
        ]),
        SGSection(@"플레이어에서", @[
            SGFlagRow(@"채팅 진입점", @"ios-martini-npvcardprovider-impl.floating_chat_entry_point_enabled"),
            SGFlagRow(@"에이전트 버튼", @"ios-martini-npvcardprovider-impl.npv_agent_button_enabled"),
        ]),
    ]) footer:nil];
}

UIViewController *SGLabsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"실험실" intro:@"미공개 기능입니다. 현재 버전에서 일부 기능은 작동하지 않을 수 있습니다. Spotify를 재시작하면 적용됩니다." sections:known(@[
        SGSection(nil, @[
            SGWithSymbol(SGPageRow(@"AI Chat (Martini)", ^UIViewController *{ return martiniPage(); }), @"bubble.left.and.bubble.right"),
        ]),
        SGSection(@"보관함", @[
            SGFlagRow(@"파일 앱의 로컬 파일", @"ios-feature-localfiles.documents_enabled"),
        ]),
        SGSection(@"홈 화면 위젯", @[
            SGFlagRow(@"재생 진행 막대", @"ios-widgets-widgetremoteconfig-impl.progress_bar_enabled"),
        ]),
        SGNotedSection(@"수면 타이머", @[
            SGFlagRow(@"페이드 아웃", @"ios-feature-sleeptimer.enable_fade_out"),
            SGFlagRow(@"1분 옵션", @"ios-feature-sleeptimer.enable_one_minute_option"),
            SGFlagRow(@"옵션 시트", @"ios-feature-sleeptimer.use_options_sheet"),
        ], @"재설계 UI에서는 옵션 시트가 항상 켜져 있습니다."),
        SGSection(@"DJ", @[
            SGFlagRow(@"자동 믹스", @"ios-playlistcuration-mats.auto_mix_enabled_for_dj"),
            SGFlagRow(@"컨텍스트 메뉴의 자동 믹스", @"ios-playlistcuration-mats.dj_auto_mix_context_menu_enabled"),
        ]),
        SGSection(@"플레이어", @[
            SGFlagRow(@"커버 위 뱀 게임", @"ios-feature-cover-art-snake.enabled"),
        ]),
        SGSection(@"팟캐스트 댓글", @[
            SGFlagRow(@"댓글 카드", @"ios-feature-comments.enable_comments_card"),
            SGFlagRow(@"고정 댓글", @"ios-feature-comments.enable_pinned_comments"),
            SGFlagRow(@"여러 반응", @"ios-feature-comments.enable_multi_reactions"),
        ]),
    ]) footer:nil];
}
