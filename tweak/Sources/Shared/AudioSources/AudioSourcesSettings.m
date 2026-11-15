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
static NSDictionary *sourceAt(NSUInteger index) {
    NSArray *sources = SGAddonSources();
    return index < sources.count ? sources[index] : nil;
}
UIViewController *SGAudioSourcesPage(void) {
    SGModRow *wired = SGOptionRow(@"유선 원본 출력", @"실험 기능 · 원본 레이트 일치 및 음량 유지", SGKeyWiredSourceOutput);
    wired.changed = ^(BOOL on) { SGWiredOutputSettingsChanged(); };
    __block __weak SGModPage *weakPage;
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
    SGModRow *tunnel = SGOptionRow(@"애드온용 WireGuard", @"애드온 JSON 및 오디오만 · iOS 17 이상", SGKeySourceWireGuard);
    tunnel.changed = ^(BOOL on) { SGAddonRetryCurrentTrack(); };
    SGModRow *add = SGActionRow(@"소스 추가", @"발급받은 HTTPS 루트 또는 manifest URL 붙여넣기", ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"무손실 소스 추가" message:@"접근 권한이 있는 서버를 사용하세요. 설정 웹페이지는 애드온 URL이 아닙니다. 추가 순서대로 최대 8개 소스를 조회합니다." preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"https://server/secret/manifest.json";
            field.keyboardType = UIKeyboardTypeURL; field.secureTextEntry = YES;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"추가" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (!SGAddonAddSource(alert.textFields.firstObject.text)) message(@"소스를 저장하지 못했습니다", @"사용자 이름이나 비밀번호가 없는 HTTPS 루트 또는 manifest URL을 사용하세요. 최대 8개 소스를 지원하며 Keychain을 사용할 수 있어야 합니다.");
            [weakPage refreshVisibility];
        }]];
        SGShowAudioController(alert);
    });
    NSMutableArray *rows = [NSMutableArray arrayWithObject:add];
    for (NSUInteger i = 0; i < 8; i++) {
        SGModRow *row = SGActionRow([NSString stringWithFormat:@"소스 %lu", (unsigned long)i + 1], @"검사 또는 제거", ^{
            NSDictionary *source = sourceAt(i);
            if (!source) return;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"무손실 소스" message:@"소스 URL은 인증 정보이며 Keychain에 보관합니다. manifest 검사는 재생과 동일한 네트워크 및 WireGuard 설정을 사용합니다." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"소스 검사" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                SGAddonTestSource(source[@"id"], ^(NSString *status) { message(@"소스 검사", status); });
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"제거" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
                if (!SGAddonRemoveSource(source[@"id"])) message(@"소스를 제거하지 못했습니다", @"Keychain을 사용할 수 없습니다. 기기 잠금을 해제한 후 다시 시도하세요.");
                [weakPage refreshVisibility];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
            SGShowAudioController(alert);
        });
        row.visible = ^BOOL { return sourceAt(i) != nil; };
        [rows addObject:row];
    }
    SGModPage *page = [[SGModPage alloc] initWithTitle:@"무손실 소스" intro:@"플레이어 페이지에서 무손실 파일을 켜고 Spotify를 한 번 재시작하여 재생 훅을 설치하세요. 아래 소스 및 네트워크 설정은 새 요청부터 적용됩니다."
        sections:@[
            SGNotedSection(@"재생", @[enabled, cellular, SGActionRow(@"현재 곡 다시 시도", @"각 소스의 요청 제한 준수", ^{ SGAddonRetryCurrentTrack(); }), SGStatActionRow(@"준비 상태", @"탭하여 자세히 보기", ^NSString *{ return SGAddonStatusSummary(); }, ^{ message(@"준비 상태", SGAddonStatus()); })], @"직접 제공되는 스테레오 FLAC/ALAC 파일만 지원합니다. 기본 디코더로 확인한 뒤 Spotify 오디오와 정렬합니다. HLS, DASH, DRM 및 공식 앱 전용 소스는 지원하지 않습니다. 노래방이나 1× 이외의 속도에서는 Spotify 오디오를 유지합니다."),
            SGSection(@"소스 (우선순위 순)", rows),
            SGNotedSection(@"유선 출력", @[wired,
                SGStatActionRow(@"출력 상태", @"탭하여 자세히 보기", ^NSString *{ return SGWiredOutputStatus()[@"state"]; }, ^{
                    message(@"유선 출력", SGWiredOutputStatus()[@"detail"]);
                }),
            ], @"USB DAC, wired headphones and line output only. Applies to local and addon lossless files. Negotiation may briefly pause playback. Unsupported devices or Spotify mixers keep their existing rate. Source level can be louder. Disable EQ, Sing, reverb and speed/pitch effects for an unprocessed path. Matching rates alone do not prove bit-perfect output."),
            SGNotedSection(@"선택적 라우팅", @[tunnel,
                SGPageRow(@"WireGuard 프록시", ^UIViewController *{ return SGWireGuardSettingsPage(); }),
            ], @"애드온은 WireGuard 없이도 작동합니다. 앱 프록시 모드에서는 이 개별 스위치와 관계없이 애드온의 URLSession 트래픽에도 프록시가 적용됩니다."),
        ] footer:@"공급자 주소나 인증 정보는 포함하지 않습니다. 요청은 클라이언트를 Vitrine으로 식별합니다. 소스 URL과 WireGuard 키는 설정 백업에서 제외됩니다."];
    weakPage = page;
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
        message(@"Spotify 재시작", @"The app-wide URLSession proxy is selected at launch. Fully close and reopen Spotify to apply this change. Import your profile before enabling. Lossless addons can stay off.");
    };
    return [[SGModPage alloc] initWithTitle:@"WireGuard 프록시" intro:@"Import your own .conf, optionally test tunnel DNS, then enable Spotify app proxy and restart Spotify. Requires iOS 17+."
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
                SGStatRow(@"Tunnel bytes received / sent", ^NSString *{
                    NSDictionary *engine = SGWireGuardStatus()[@"engine"];
                    return [NSString stringWithFormat:@"%.1f / %.1f KiB", [engine[@"wgRxBytes"] doubleValue] / 1024, [engine[@"wgTxBytes"] doubleValue] / 1024];
                }),
                SGStatRow(@"Profile", ^NSString *{ return SGWireGuardHasProfile() ? @"Saved in Keychain" : @"Not imported"; }),
                SGStatRow(@"Tunnel", ^NSString *{ return SGWireGuardStatus()[@"state"]; }),
                SGStatRow(@"Last handshake", ^NSString *{
                    NSNumber *age = SGWireGuardStatus()[@"engine"][@"handshakeAgeSec"];
                    return age && age.doubleValue >= 0 ? [NSString stringWithFormat:@"%.0f s ago", age.doubleValue] : @"Not verified";
                }),
                SGStatRow(@"Tunnel DNS test", ^NSString *{ return testState; }),
                SGActionRow(@"Test tunnel DNS", @"Resolve api.spotify.com through the peer", ^{
                    if (testing) return;
                    testing = YES; testState = @"Testing…";
                    SGWireGuardTestDNS(^(NSString *result) { testing = NO; testState = result; message(@"WireGuard test", result); });
                }),
                SGActionRow(@"Check tunnel HTTPS / exit country", @"Contacts Cloudflare through the selected tunnel", ^{
                    if (testing) return;
                    testing = YES; testState = @"Testing HTTPS…";
                    SGWireGuardTestHTTPS(^(NSString *result) { testing = NO; testState = result; message(@"WireGuard HTTPS", result); });
                }),
                SGActionRow(@".conf 파일 가져오기", @"Single-peer profile · numeric DNS · default routes", ^{
                    sg_importer = [SGWGImporter new];
                    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                        initForOpeningContentTypes:@[UTTypeData, UTTypeText, UTTypeItem] asCopy:YES];
                    picker.delegate = sg_importer;
                    picker.allowsMultipleSelection = NO;
                    SGShowAudioController(picker);
                }),
                SGActionRow(@"클립보드에서 가져오기", @"Paste a copied WireGuard configuration", ^{
                    NSString *text = UIPasteboard.generalPasteboard.string;
                    NSString *reason;
                    BOOL ok = text.length && SGWireGuardImport(text, &reason);
                    if (ok) { UIPasteboard.generalPasteboard.string = @""; SGAddonRetryCurrentTrack(); }
                    message(@"WireGuard", ok ? @"Profile saved. Configuration text removed from the clipboard." : reason ?: @"먼저 UTF-8 .conf 전체 내용을 복사하세요.");
                }),
                SGActionRow(@"저장된 프로필 삭제", @"실행 중인 엔진을 중지하려면 WireGuard를 끄고 재시작하세요", ^{
                    SGSetEnabled(SGKeyAppWireGuard, NO); SGSetEnabled(SGKeySourceWireGuard, NO); SGAddonRetryCurrentTrack();
                    message(@"WireGuard", SGWireGuardDelete() ? @"Saved profile deleted. Restart Spotify to release an engine already running in memory." : @"Keychain could not delete the profile.");
                }),
            ], @"This app-local proxy routes new Spotify/Vitrine URLSession traffic, even with lossless addons off. It is not a system VPN. Raw sockets, Spotify Connect discovery, other apps, and WebKit/AVFoundation processes are outside the verified scope. Enabled URLSession configurations block when the tunnel is unavailable. A ready proxy does not prove a peer handshake. A hostname peer endpoint requires one local DNS lookup at startup."),
        ] footer:@"Keep the same signed app Identifier when reinstalling to preserve Keychain. To replace or stop an in-memory engine, disable both app and addon routing and restart first."];
}
