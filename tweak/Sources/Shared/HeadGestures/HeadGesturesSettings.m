// The AirPods gestures page: the switch, a pull-down of what each gesture does, then fitting them to the
// user: the teaching sheet, the sensitivity, Try it, which listens a few seconds and names what it picked up
// in its own row without doing anything to the song, and Forget.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "HeadGestures.h"

// Long enough to get the AirPods' attention and make a slow double nod.
static const double kTrySeconds = 6;

// SGHeadAction's names, in its order.
static NSArray<NSString *> *actionNames(void) {
    return @[@"Nothing", @"15초 뒤로", @"15초 앞으로", @"재생 또는 일시정지", @"다음 곡", @"이전 곡",
             @"셔플", @"반복", @"Like"];
}

static void say(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static BOOL headTracking(void) {
    if (SGHeadGesturesAvailable()) return YES;
    say(@"머리 추적 불가", @"이 iPhone에서는 헤드폰 움직임을 읽을 수 없습니다.");
    return NO;
}

static NSString *learnedValue(void) {
    BOOL nod = SGInt(SGKeyHeadNod, 0) > 0, shake = SGInt(SGKeyHeadShake, 0) > 0;
    return nod && shake ? @"Learned" : nod ? @"끄덕임 학습됨" : shake ? @"고개 젓기 학습됨" : @"";
}

static BOOL anythingLearned(void) {
    return SGInt(SGKeyHeadNod, 0) > 0 || SGInt(SGKeyHeadShake, 0) > 0;
}

// Both learned sizes back to the defaults, asked first; `done` runs once they are.
static void forget(void (^done)(void)) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"끄덕임과 고개 젓기 학습을 삭제할까요?"
        message:@"두 제스처 모두 기본 감도로 돌아갑니다. 다시 학습할 수 있습니다." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Forget" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SGSetInt(SGKeyHeadNod, 0);
        SGSetInt(SGKeyHeadShake, 0);
        SGHeadGesturesSettingsChanged();
        done();
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static SGModRow *actionRow(NSString *title, SGHeadGesture gesture) {
    return SGMenuRow(title, actionNames(), ^NSString *{ return actionNames()[(NSUInteger)SGHeadGestureAction(gesture)]; },
                     ^(NSInteger index) { SGSetHeadGestureAction(gesture, index); });
}

UIViewController *SGHeadGesturesSettingsPage(void) {
    SGModRow *toggle = SGOptionRow(@"머리 제스처", @"두 번 끄덕이거나 고개를 저어 음악을 제어하세요", SGKeyHeadGestures);
    toggle.changed = ^(BOOL on) { SGHeadGesturesSettingsChanged(); };

    SGModRow *nodAction = SGWithSymbol(actionRow(@"두 번 끄덕이기", SGHeadGestureDoubleNod), @"arrow.up.and.down");
    SGModRow *shakeAction = SGWithSymbol(actionRow(@"고개 젓기", SGHeadGestureShake), @"arrow.left.and.right");
    SGModRow *chime = SGWithSymbol(SGSwitchRow(@"작동 시 알림음", nil, SGKeyHeadChime), @"bell");

    __block __weak SGModPage *page;
    SGModRow *teach = SGStatActionRow(@"제스처 학습", @"알림음이 들릴 때마다 하나씩, 각각 다섯 번", ^NSString *{ return learnedValue(); }, ^{
        if (!headTracking()) return;
        SGPresentHeadGesturesTeaching(page, ^{ [page refreshVisibility]; });
    });

    SGModRow *sensitivity = SGSliderRow(@"감도", @"값이 높으면 더 작은 움직임을 감지합니다",
        SGHeadSensitivityMin, SGHeadSensitivityMax, SGHeadSensitivityStep,
        ^double { return MAX(SGHeadSensitivityMin, MIN(SGHeadSensitivityMax, SGInt(SGKeyHeadSensitivity, 100))); },
        ^(double value) {
            SGSetInt(SGKeyHeadSensitivity, lround(value));
            SGHeadGesturesSettingsChanged();
        },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld%%", lround(value)]; });

    // What the last try picked up, read out on its row until the next; a new page starts blank.
    __block NSString *tried = @"";
    __block BOOL trying = NO;
    SGModRow *tryRow = SGStatActionRow(@"시험하기", @"알림음 이후 움직임을 감지하고 결과를 표시합니다", ^NSString *{ return tried; }, ^{
        if (trying || !headTracking()) return;
        trying = YES;
        tried = @"Listening…";
        [page.tableView reloadData];
        SGHeadGesturesCue(SGHeadCueReady);
        SGHeadGesturesTry(kTrySeconds, ^(SGHeadGesture gesture, BOOL heard) {
            trying = NO;
            tried = gesture == SGHeadGestureDoubleNod ? @"두 번 끄덕이기" : gesture == SGHeadGestureShake ? @"고개 젓기" : heard ? @"Nothing" : @"움직임 없음";
            SGHeadGesturesCue(gesture != SGHeadGestureNone ? SGHeadCueWorked : SGHeadCueFailed);
            NSString *spoken = gesture != SGHeadGestureNone ? [@"감지: " stringByAppendingString:tried]
                             : heard ? @"움직임을 감지하지 못했습니다. 더 크게 움직이거나 감도를 높이세요."
                                     : @"움직임이 전달되지 않았습니다. 머리 추적을 지원하는 AirPods를 착용하세요.";
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, spoken);
            [page.tableView reloadData];
        });
    });

    SGModRow *forgetRow = SGActionRow(@"학습 내용 삭제", nil, ^{ forget(^{ [page refreshVisibility]; }); });
    forgetRow.color = SGRed();
    forgetRow.visible = ^BOOL { return anythingLearned(); };
    for (SGModRow *row in @[nodAction, shakeAction, chime, teach, sensitivity, tryRow, forgetRow]) row.waitsOn = SGKeyHeadGestures;

    SGModPage *shown = [[SGModPage alloc] initWithTitle:@"AirPods 제스처" intro:nil sections:@[
        SGSection(nil, @[SGWithSymbol(toggle, @"airpods.pro")]),
        SGNotedSection(@"제스처", @[nodAction, shakeAction, chime],
            @"머리 추적을 지원하는 AirPods Pro, AirPods 3 이후 모델, AirPods Max 및 일부 Beats로 Spotify를 재생하는 동안 작동합니다. 재생 또는 일시정지로 설정하면 일시정지 중에도 감지합니다. 알림음을 켜면 성공 시 상승하는 두 음, 실패 시 낮은 음을 무음 모드에서도 재생합니다. 움직임을 읽기 위해 처음 한 번 동작 및 피트니스 권한을 요청합니다."),
        SGNotedSection(@"사용자에게 맞추기", @[teach, sensitivity, tryRow, forgetRow],
            @"본인의 움직임을 다섯 번씩 학습해 감지 크기를 정합니다. 감도는 두 제스처에 함께 적용됩니다. 시험하기는 음악을 제어하지 않으므로 재생 중에도 조절할 수 있습니다."),
    ] footer:nil];
    page = shown;
    return shown;
}
