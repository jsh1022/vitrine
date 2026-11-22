#import "SGAddons.h"
#import "SGWireGuard.h"
#import "SGAudioPresentation.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/Lossless/SGWiredOutput.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static void message(NSString *title, NSString *text) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
    SGShowAudioController(alert);
}
@interface SGWGImporter : NSObject <UIDocumentPickerDelegate>
@end
static SGWGImporter *sg_importer;
@implementation SGWGImporter
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) { sg_importer = nil; return; }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL access = [url startAccessingSecurityScopedResource];
        __block NSData *data;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:url options:0 error:NULL byAccessor:^(NSURL *readURL) {
            NSInputStream *stream = [NSInputStream inputStreamWithURL:readURL];
            [stream open];
            NSMutableData *bytes = [NSMutableData data];
            uint8_t buffer[4096]; NSInteger count;
            while (bytes.length <= 65536 && (count = [stream read:buffer maxLength:MIN(sizeof buffer, 65537 - bytes.length)]) > 0)
                [bytes appendBytes:buffer length:(NSUInteger)count];
            if (!stream.streamError && bytes.length && bytes.length <= 65536) data = bytes;
            [stream close];
        }];
        if (access) [url stopAccessingSecurityScopedResource];
        // Import mode owns a copy. Never remove a file outside our app's import folders.
        NSString *path = url.path.stringByStandardizingPath;
        NSString *inbox = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Inbox/"];
        if ([path hasPrefix:NSTemporaryDirectory()] || [path hasPrefix:inbox])
            [NSFileManager.defaultManager removeItemAtURL:url error:NULL];
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *reason;
            BOOL ok = text.length && SGWireGuardImport(text, &reason);
            if (ok) SGAddonRetryCurrentTrack();
            message(@"WireGuard", ok ? @"프로필을 Keychain에 저장했습니다. Spotify 앱 프록시를 켜고 재시작하세요." : reason ?: @"다운로드한 64 KiB 이하의 UTF-8 .conf 파일을 선택하세요.");
            sg_importer = nil;
        });
    });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { sg_importer = nil; }
@end
UIViewController *SGAudioSourcesPage(void) {
    SGModRow *wired = SGOptionRow(@"유선 원본 출력", @"실험 기능 · 원본 레이트 일치 및 음량 유지", SGKeyWiredSourceOutput);
    wired.changed = ^(BOOL on) { SGWiredOutputSettingsChanged(); };
    SGModRow *enabled = SGOptionRow(@"HTTP 무손실 애드온", @"Spotify 재생 중 일치하는 파일 준비", SGKeyAddons);
    enabled.changed = ^(BOOL on) {
        if (on && !SGFlag(SGKeyLossless, NO)) {
            SGSetEnabled(SGKeyLossless, YES);
            message(@"Spotify 재시작", @"무손실 재생 훅이 활성화되었습니다. 애드온 음원을 재생하기 전에 Spotify를 완전히 종료하고 다시 여세요.");
        }
        SGAddonRetryCurrentTrack();
    };
    SGModRow *cellular = SGOptionRow(@"셀룰러 다운로드 허용", @"꺼짐: 비과금 네트워크만 사용합니다. 파일은 최대 128 MiB입니다", SGKeyAddonCellular);
    cellular.changed = ^(BOOL on) { SGAddonRetryCurrentTrack(); };

    SGModRow *playbackMode = SGChoiceRow(@"애드온 재생 방식", nil, SGKeyAddonPlaybackMode,
        @[@"빠른 재생", @"연속 재생 우선", @"애드온 우선 재생"], 1);
    playbackMode.choiceNotes = @[
        @"애드온을 조회하거나 기다리지 않고 Spotify 기본 스트림으로 바로 재생합니다.",
        @"현재 곡은 Spotify로 바로 재생하고, 다음 곡 사전 준비가 켜져 있으면 바로 다음 한 곡만 준비합니다. Wi-Fi에서는 전체 파일을 받으며, 모바일 데이터에서는 셀룰러 다운로드를 허용하면 앞부분 최대 2 MiB를 받으며, ‘모바일 데이터로 다음 곡 전체 준비’도 켜면 전체 파일을 받습니다. 사전 준비를 꺼도 자동 음원 전환 설정은 유지됩니다.",
        @"설정한 시간만큼 재생을 기다린 뒤 Spotify 기본 스트림으로 재개합니다. 재개 후 Spotify 오디오와 파일의 4초 상관 분석으로 안전한 전환 여부를 확인합니다.",
    ];
    playbackMode.chosen = ^(NSInteger index) { SGAddonRetryCurrentTrack(); };
    playbackMode.visible = ^BOOL { return SGRedesignedUIStored(); };

    SGModRow *autoSwitch = SGSwitchRow(@"재생 중 자동 음원 전환", @"안전한 상관 정렬이 끝나면 현재 곡을 전환합니다. 꺼도 다음 곡은 준비합니다.", SGKeyAddonAutoSwitch);
    autoSwitch.changed = ^(BOOL on) { SGAddonRetryCurrentTrack(); };
    autoSwitch.visible = ^BOOL {
        return SGRedesignedUIStored() && SGInt(SGKeyAddonPlaybackMode, SGAddonPlaybackContinuous) == SGAddonPlaybackContinuous;
    };

    SGModRow *prefetch = SGSwitchRow(@"다음 곡 사전 준비", @"켜면 바로 다음 한 곡만 미리 준비합니다.", SGKeyAddonPrefetchEnabled);
    prefetch.changed = ^(BOOL on) { SGAddonUpdateUpcoming(@[]); };
    prefetch.visible = autoSwitch.visible;

    SGModRow *cellularFull = SGOptionRow(@"모바일 데이터로 다음 곡 전체 준비", @"Wi-Fi에서는 다음 곡 전체를 받습니다. 기존 셀룰러 다운로드 허용 설정도 켜야 모바일 데이터에서 전체 파일을 준비합니다.", SGKeyAddonPrefetchCellular);
    cellularFull.changed = ^(BOOL on) { SGAddonRetryCurrentTrack(); };
    cellularFull.visible = ^BOOL {
        return SGRedesignedUIStored() && SGInt(SGKeyAddonPlaybackMode, SGAddonPlaybackContinuous) == SGAddonPlaybackContinuous && SGFlag(SGKeyAddonPrefetchEnabled, YES);
    };

    SGModRow *wait = SGSliderRow(@"애드온 대기 시간", @"대기 후 Spotify 기본 스트림으로 재개합니다. 재개 후 4초 상관 분석으로 안전한 전환 여부를 확인합니다.", 5, 30, 1,
        ^double { return SGInt(SGKeyAddonWaitSeconds, 10); },
        ^(double value) { SGSetInt(SGKeyAddonWaitSeconds, lround(value)); SGAddonRetryCurrentTrack(); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%ld초", lround(value)]; });
    wait.visible = ^BOOL { return SGRedesignedUIStored() && SGInt(SGKeyAddonPlaybackMode, SGAddonPlaybackContinuous) == SGAddonPlaybackPrefer; };
    SGModRow *tunnel = SGOptionRow(@"애드온용 WireGuard", @"애드온 JSON 및 오디오만 · iOS 17 이상", SGKeySourceWireGuard);
    tunnel.changed = ^(BOOL on) { SGAddonRetryCurrentTrack(); };
    SGModPage *page = [[SGModPage alloc] initWithTitle:@"무손실 소스" intro:@"플레이어 페이지에서 무손실 파일을 켜고 Spotify를 한 번 재시작하여 재생 훅을 설치하세요. 아래 소스 및 네트워크 설정은 새 요청부터 적용됩니다."
        sections:@[
            SGNotedSection(@"재생", @[enabled, cellular, playbackMode, autoSwitch, prefetch, cellularFull, wait,
                SGActionRow(@"현재 곡 다시 시도", @"각 소스의 요청 제한 준수", ^{ SGAddonRetryCurrentTrack(); }), SGStatActionRow(@"준비 상태", @"탭하여 자세히 보기", ^NSString *{ return SGAddonStatusSummary(); }, ^{ message(@"준비 상태", SGAddonStatus()); })], @"HTTPS 정적 VOD를 지원합니다. 직접 제공되는 스테레오 FLAC/ALAC 또는 무압축 PCM WAV/AIFF와 HLS의 fMP4 EXT-X-MAP/단일 직접 세그먼트, DASH 단일 Period의 SegmentBase/full file, SegmentList, 또는 최대 2048개 세그먼트의 duration/Timeline을 사용할 수 있습니다. 전경 직접 FLAC은 알려진 전체 크기가 128 MiB 이하이고 바이트가 연속되며 완전한 FLAC 메타데이터와 native 코덱·스테레오·레이트·깊이·길이 검사를 통과하면 다운로드 중 조기 전환을 시도합니다. 필요한 PCM은 worker에서 새 바이트를 기다리고 render ring이 부족하면 Spotify가 계속 재생됩니다. 기존 4초 정렬 검사는 유지되며 초기 대기 시간은 조기 전환 수락 시 끝납니다. 남은 전송은 최대 120초이며 실패하면 외부 재생을 취소합니다. 자라는 파일을 native parser가 열지 못하면 전체 다운로드 후 처리합니다. 다른 직접 형식과 HLS/DASH는 전체 파일을 받은 뒤 준비하며, 세그먼트는 AVAssetReader로 WAV 변환합니다. 암호화·DRM·라이브·discontinuity·Atmos·MP3/AAC는 지원하지 않습니다. 노래방이나 1× 이외의 속도에서는 Spotify 오디오를 유지합니다. 전체 파일 준비에는 Wi-Fi 또는 전체 셀룰러 다운로드 허용이 필요합니다. 백그라운드 다음 곡 사전 준비는 기존처럼 유지되고 접두부 방식은 세그먼트 스트림을 건너뜁니다. 안전한 전환에는 Spotify 오디오와 파일의 4초 상관 분석이 필요하므로 첫 샘플부터 애드온 음원으로 재생된다고 보장할 수 없습니다."),
            SGNotedSection(@"소스", @[SGPageRow(@"음원을 찾는 순서", ^UIViewController *{ return SGAddonSourcesPage(); })], @"소스 이름과 설명을 확인하고, 사용 여부와 조회 순서를 설정합니다."),
            SGNotedSection(@"유선 출력", @[wired,
                SGStatActionRow(@"출력 상태", @"탭하여 자세히 보기", ^NSString *{ return SGWiredOutputStatus()[@"state"]; }, ^{
                    message(@"유선 출력", SGWiredOutputStatus()[@"detail"]);
                }),
            ], @"USB DAC, 유선 헤드폰, 라인 출력에서만 사용할 수 있습니다. 로컬 및 애드온 무손실 파일에 적용되며 협상 중 재생이 잠시 멈출 수 있습니다. 지원하지 않는 기기나 Spotify 믹서는 기존 레이트를 유지합니다. 원본 음량이 더 클 수 있습니다. 가공하지 않은 출력을 원하면 EQ, Sing, 리버브, 속도·피치 효과를 끄세요. 레이트 일치만으로 bit-perfect 출력을 입증하지는 않습니다."),
            SGNotedSection(@"선택적 라우팅", @[tunnel,
                SGPageRow(@"WireGuard 프록시", ^UIViewController *{ return SGWireGuardSettingsPage(); }),
            ], @"애드온은 WireGuard 없이도 작동합니다. 앱 프록시 모드에서는 이 개별 스위치와 관계없이 애드온의 URLSession 트래픽에도 프록시가 적용됩니다."),
        ] footer:@"공급자 주소나 인증 정보는 포함하지 않습니다. 요청은 클라이언트를 Vitrine으로 식별합니다. 소스 URL과 WireGuard 키는 설정 백업에서 제외됩니다."];
    return page;
}

UIViewController *SGWireGuardSettingsPage(void) {
    __block BOOL testing = NO;
    __block NSString *testState = @"실행 전";
    SGModRow *app = SGOptionRow(@"Spotify 앱 프록시", @"WireGuard로 URLSession 라우팅 · 재시작 필요", SGKeyAppWireGuard);
    app.changed = ^(BOOL on) {
        if (on) {
            BOOL supported = NO;
#if SG_WIREGUARD
            supported = [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){17, 0, 0}];
#endif
            if (!supported || !SGWireGuardHasProfile()) {
                SGSetEnabled(SGKeyAppWireGuard, NO);
                message(@"WireGuard를 켜지 못했습니다", supported ? @"올바른 .conf 프로필을 먼저 가져온 후 앱 프록시를 켜세요." : @"iOS 17 이상과 WireGuard가 포함된 빌드가 필요합니다.");
                return;
            }
        }
        message(@"Spotify 재시작", @"앱 전체 URLSession 프록시는 시작할 때 선택됩니다. 적용하려면 Spotify를 완전히 종료하고 다시 여세요. 먼저 프로필을 가져온 후 켜세요. 무손실 애드온을 켤 필요는 없습니다.");
    };
    return [[SGModPage alloc] initWithTitle:@"WireGuard 프록시" intro:@"본인의 .conf를 가져와 필요하면 터널 DNS를 검사한 후 Spotify 앱 프록시를 켜고 재시작하세요. iOS 17 이상이 필요합니다."
        sections:@[
            SGNotedSection(@"앱 내부 WireGuard", @[
                app,
                SGStatRow(@"이번 실행의 앱 프록시", ^NSString *{ return SGWireGuardAppProxyActive() ? @"켜짐 · 끄려면 재시작 필요" : @"꺼짐 · 켜려면 재시작 필요"; }),
                SGStatRow(@"라우팅된 구성", ^NSString *{ return [SGWireGuardProxyCounters()[@"configurations"] stringValue]; }),
                SGStatRow(@"차단된 구성", ^NSString *{ return [SGWireGuardProxyCounters()[@"blockedConfigurations"] stringValue]; }),
                SGStatRow(@"프록시 TCP 연결", ^NSString *{
                    NSNumber *count = SGWireGuardStatus()[@"engine"][@"connections"][@"total"];
                    return count ? count.stringValue : @"0";
                }),
                SGStatRow(@"터널 수신 / 송신 바이트", ^NSString *{
                    NSDictionary *engine = SGWireGuardStatus()[@"engine"];
                    return [NSString stringWithFormat:@"%.1f / %.1f KiB", [engine[@"wgRxBytes"] doubleValue] / 1024, [engine[@"wgTxBytes"] doubleValue] / 1024];
                }),
                SGStatRow(@"프로필", ^NSString *{ return SGWireGuardHasProfile() ? @"Keychain에 저장됨" : @"가져오지 않음"; }),
                SGStatRow(@"터널", ^NSString *{ return SGWireGuardStatus()[@"state"]; }),
                SGStatRow(@"마지막 핸드셰이크", ^NSString *{
                    NSNumber *age = SGWireGuardStatus()[@"engine"][@"handshakeAgeSec"];
                    return age && age.doubleValue >= 0 ? [NSString stringWithFormat:@"%.0f s ago", age.doubleValue] : @"확인되지 않음";
                }),
                SGStatRow(@"터널 DNS 검사", ^NSString *{ return testState; }),
                SGActionRow(@"터널 DNS 검사하기", @"피어를 통해 api.spotify.com의 주소 확인", ^{
                    if (testing) return;
                    testing = YES; testState = @"Testing…";
                    SGWireGuardTestDNS(^(NSString *result) { testing = NO; testState = result; message(@"WireGuard 검사", result); });
                }),
                SGActionRow(@"터널 HTTPS / 출구 국가 확인", @"선택한 터널을 통해 Cloudflare에 연결합니다", ^{
                    if (testing) return;
                    testing = YES; testState = @"HTTPS 검사 중…";
                    SGWireGuardTestHTTPS(^(NSString *result) { testing = NO; testState = result; message(@"WireGuard HTTPS", result); });
                }),
                SGActionRow(@".conf 파일 가져오기", @"단일 피어 프로필 · 숫자 DNS · 기본 경로", ^{
                    sg_importer = [SGWGImporter new];
                    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                        initForOpeningContentTypes:@[UTTypeData, UTTypeText, UTTypeItem] asCopy:YES];
                    picker.delegate = sg_importer;
                    picker.allowsMultipleSelection = NO;
                    SGShowAudioController(picker);
                }),
                SGActionRow(@"클립보드에서 가져오기", @"복사한 WireGuard 구성 붙여넣기", ^{
                    NSString *text = UIPasteboard.generalPasteboard.string;
                    NSString *reason;
                    BOOL ok = text.length && SGWireGuardImport(text, &reason);
                    if (ok) { UIPasteboard.generalPasteboard.string = @""; SGAddonRetryCurrentTrack(); }
                    message(@"WireGuard", ok ? @"프로필을 저장하고 클립보드에서 구성 텍스트를 지웠습니다." : reason ?: @"먼저 UTF-8 .conf 전체 내용을 복사하세요.");
                }),
                SGActionRow(@"저장된 프로필 삭제", @"실행 중인 엔진을 중지하려면 WireGuard를 끄고 재시작하세요", ^{
                    SGSetEnabled(SGKeyAppWireGuard, NO); SGSetEnabled(SGKeySourceWireGuard, NO); SGAddonRetryCurrentTrack();
                    message(@"WireGuard", SGWireGuardDelete() ? @"저장된 프로필을 삭제했습니다. 메모리의 실행 중인 엔진을 해제하려면 Spotify를 재시작하세요." : @"Keychain에서 프로필을 삭제하지 못했습니다.");
                }),
            ], @"이 앱 내부 프록시는 무손실 애드온이 꺼져 있어도 새 Spotify/Vitrine URLSession 트래픽을 라우팅합니다. 시스템 VPN은 아닙니다. 일반 소켓, Spotify Connect 검색, 다른 앱, WebKit/AVFoundation 프로세스는 검증 범위에 포함되지 않습니다. 프록시를 사용하는 URLSession 구성은 터널이 없으면 차단됩니다. 프록시 준비 완료가 피어 핸드셰이크 성공을 뜻하지는 않습니다. 피어 주소가 호스트 이름이면 시작 시 로컬 DNS 조회를 한 번 사용합니다."),
        ] footer:@"재설치할 때 서명 앱 Identifier를 유지해야 Keychain이 보존됩니다. 메모리의 엔진을 교체하거나 중지하려면 앱 및 애드온 라우팅을 모두 끈 후 먼저 재시작하세요."];
}
