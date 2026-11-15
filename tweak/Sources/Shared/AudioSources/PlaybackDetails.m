#import "SGAddons.h"
#import "SGWireGuard.h"
#import "SGAudioPresentation.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/Sing/Sing.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
NSDictionary *SGAudioPipelineSnapshot(void);

static NSString *hz(double rate) { return rate > 0 ? [NSString stringWithFormat:@"%.1f kHz", rate / 1000] : @"알 수 없음"; }
static NSDictionary *sourceInfo(void) { return SGLosslessSourceInfo(); }
static UIViewController *legacyDetailsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"상세 재생 정보" intro:@"이 페이지를 연 동안 값을 갱신합니다. 소스 메타데이터와 로컬 오디오 출력은 서로 다른 단계를 나타냅니다."
        sections:@[
            SGSection(@"곡", @[
                SGStatRow(@"제목", ^NSString *{ return SGPlayerState().track.trackTitle ?: @"곡 없음"; }),
                SGStatRow(@"아티스트", ^NSString *{ return SGPlayerState().track.artistName ?: @"—"; }),
                SGStatRow(@"Spotify URI", ^NSString *{ return SGURIString(SGPlayerState().track.URI) ?: @"—"; }),
                SGStatRow(@"상태", ^NSString *{ SPTPlayerState *s = SGPlayerState(); return !s ? @"플레이어 없음" : s.isLoading ? @"Loading" : s.isPaused ? @"일시정지됨" : s.isPlaying ? @"재생 중" : @"중지됨"; }),
                SGStatRow(@"재생 위치 / 길이", ^NSString *{ SPTPlayerState *s = SGPlayerState(); return [NSString stringWithFormat:@"%.1f / %.1f s", s.position, s.duration]; }),
            ]),
            SGNotedSection(@"소스", @[
                SGStatRow(@"선택된 오디오", ^NSString *{ return SGLosslessRendering() ? @"외부 무손실 프레임이 로컬 출력에 전달됨" : SGLosslessPlaying() ? @"정렬됨 · 현재 외부 출력은 확인되지 않음" : @"Spotify"; }),
                SGStatRow(@"애드온 준비", ^NSString *{ return SGAddonStatus(); }),
                SGStatRow(@"준비된 코덱", ^NSString *{ return sourceInfo()[@"codec"] ?: SGAddonMediaInfo()[@"codec"] ?: @"알 수 없음"; }),
                SGStatRow(@"원본 샘플레이트", ^NSString *{ return hz([(sourceInfo()[@"rate"] ?: SGAddonMediaInfo()[@"rate"]) doubleValue]); }),
                SGStatRow(@"원본 비트 깊이", ^NSString *{ NSInteger bits = [(sourceInfo()[@"bits"] ?: SGAddonMediaInfo()[@"bits"]) integerValue]; return bits > 0 ? [NSString stringWithFormat:@"%ld bit", (long)bits] : @"알 수 없음"; }),
                SGStatRow(@"원본 채널", ^NSString *{ NSNumber *n = sourceInfo()[@"channels"] ?: SGAddonMediaInfo()[@"channels"]; return n ? n.stringValue : @"알 수 없음"; }),
                SGStatRow(@"평균 파일 비트레이트", ^NSString *{ NSNumber *n = sourceInfo()[@"averageKbps"] ?: SGAddonMediaInfo()[@"averageKbps"]; return n ? [NSString stringWithFormat:@"%.0f kbps", n.doubleValue] : @"알 수 없음"; }),
                SGStatRow(@"Spotify 코덱 / 비트레이트", ^NSString *{ return @"검증된 플레이어 API에서 제공하지 않음"; }),
            ], @"준비된 형식 정보는 파일 디코더에서 읽습니다. 실제 소리로 출력된다는 증거는 아닙니다. 선택 상태는 로컬 출력의 최근 교체 여부로 확인합니다. 확인할 수 없는 원본 비트 깊이는 추정하지 않습니다."),
            SGNotedSection(@"로컬 출력 및 처리", @[
                SGStatRow(@"클라이언트 PCM", ^NSString *{ AudioStreamBasicDescription f = {0}; return SGPlayerMusicClientFormat(&f) ? [NSString stringWithFormat:@"%@ · %u ch · %u bit", hz(f.mSampleRate), (unsigned)f.mChannelsPerFrame, (unsigned)f.mBitsPerChannel] : @"사용 불가"; }),
                SGStatRow(@"오디오 세션 레이트", ^NSString *{ return hz(AVAudioSession.sharedInstance.sampleRate); }),
                SGStatRow(@"출력 경로", ^NSString *{ NSMutableArray *names = [NSMutableArray array]; for (AVAudioSessionPortDescription *p in AVAudioSession.sharedInstance.currentRoute.outputs) [names addObject:p.portName]; return names.count ? [names componentsJoinedByString:@", "] : @"로컬 출력 경로 없음"; }),
                SGStatRow(@"출력 지연", ^NSString *{ return [NSString stringWithFormat:@"%.0f ms", AVAudioSession.sharedInstance.outputLatency * 1000]; }),
                SGStatRow(@"속도 / 피치", ^NSString *{ return [NSString stringWithFormat:@"%.2f× / %+.1f st", SGPlayerSpeed(), SGPlayerPitch()]; }),
                SGStatRow(@"노래방", ^NSString *{ return SGSingOn() ? @"켜짐" : @"꺼짐"; }),
                SGStatRow(@"애드온 터널", ^NSString *{ return SGWireGuardStatus()[@"state"]; }),
            ], @"고해상도 원본은 클라이언트 레이트로 리샘플링될 수 있습니다. Float32 PCM은 원본 비트 깊이나 bit-perfect 재생을 입증하지 않습니다. Bluetooth에서 다시 인코딩될 수 있으며 이 로컬 정보는 원격 Spotify Connect 출력을 나타내지 않습니다."),
        ] footer:nil];
}
@interface SGPipelineContainer : SGPage
@property(nonatomic, strong) UIViewController *host;
@end
@implementation SGPipelineContainer
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return 0; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.scrollEnabled = NO;
    [self addChildViewController:self.host];
    self.tableView.tableHeaderView = self.host.view;
    [self.host didMoveToParentViewController:self];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.tableView.bounds;
    bounds.origin = CGPointZero;
    bounds.size.height = MAX(1, bounds.size.height - self.tableView.adjustedContentInset.top - self.tableView.adjustedContentInset.bottom);
    if (!CGRectEqualToRect(self.host.view.frame, bounds)) {
        self.host.view.frame = bounds;
        self.tableView.tableHeaderView = self.host.view;
    }
}
@end
UIViewController *SGPlaybackDetailsPage(void) {
    Class hostClass = NSClassFromString(@"SGAudioPipelineHost");
    SEL factory = NSSelectorFromString(@"controllerWithProvider:close:");
    if (![hostClass respondsToSelector:factory]) return legacyDetailsPage();
    SGPipelineContainer *page = [SGPipelineContainer new];
    page.title = @"상세 재생 정보";
    __weak SGPipelineContainer *weakPage = page;
    NSDictionary *(^provider)(void) = ^{ return SGAudioPipelineSnapshot(); };
    void (^close)(void) = ^{
        SGPipelineContainer *owner = weakPage;
        if (owner.navigationController.viewControllers.count > 1) [owner.navigationController popViewControllerAnimated:YES];
        else [owner dismissViewControllerAnimated:YES completion:nil];
    };
    page.host = ((UIViewController *(*)(id, SEL, id, id))objc_msgSend)(hostClass, factory, provider, close);
    return page;
}
void SGShowPlaybackDetails(void) {
    UIViewController *page = SGPlaybackDetailsPage();
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    page.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:page action:@selector(sg_closePlaybackDetails)];
    nav.navigationBarHidden = [page isKindOfClass:SGPipelineContainer.class];
    SGShowAudioController(nav);
}
// SGPage already conforms to Spotify's page protocol; a local category just closes the modal.
@implementation SGPage (SGPlaybackDetailsClosing)
- (void)sg_closePlaybackDetails { [self dismissViewControllerAnimated:YES completion:nil]; }
@end
