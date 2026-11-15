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
    return [[SGModPage alloc] initWithTitle:@"상세 재생 정보" intro:@"Values refresh while this page is open. Source metadata and the local audio output describe different stages."
        sections:@[
            SGSection(@"곡", @[
                SGStatRow(@"Title", ^NSString *{ return SGPlayerState().track.trackTitle ?: @"No track"; }),
                SGStatRow(@"Artist", ^NSString *{ return SGPlayerState().track.artistName ?: @"—"; }),
                SGStatRow(@"Spotify URI", ^NSString *{ return SGURIString(SGPlayerState().track.URI) ?: @"—"; }),
                SGStatRow(@"State", ^NSString *{ SPTPlayerState *s = SGPlayerState(); return !s ? @"No player" : s.isLoading ? @"Loading" : s.isPaused ? @"일시정지됨" : s.isPlaying ? @"재생 중" : @"Stopped"; }),
                SGStatRow(@"Position / duration", ^NSString *{ SPTPlayerState *s = SGPlayerState(); return [NSString stringWithFormat:@"%.1f / %.1f s", s.position, s.duration]; }),
            ]),
            SGNotedSection(@"소스", @[
                SGStatRow(@"선택된 오디오", ^NSString *{ return SGLosslessRendering() ? @"외부 무손실 프레임이 로컬 출력에 전달됨" : SGLosslessPlaying() ? @"정렬됨 · 현재 외부 출력은 확인되지 않음" : @"Spotify"; }),
                SGStatRow(@"애드온 준비", ^NSString *{ return SGAddonStatus(); }),
                SGStatRow(@"Prepared codec", ^NSString *{ return sourceInfo()[@"codec"] ?: SGAddonMediaInfo()[@"codec"] ?: @"알 수 없음"; }),
                SGStatRow(@"Source sample rate", ^NSString *{ return hz([(sourceInfo()[@"rate"] ?: SGAddonMediaInfo()[@"rate"]) doubleValue]); }),
                SGStatRow(@"Source bit depth", ^NSString *{ NSInteger bits = [(sourceInfo()[@"bits"] ?: SGAddonMediaInfo()[@"bits"]) integerValue]; return bits > 0 ? [NSString stringWithFormat:@"%ld bit", (long)bits] : @"알 수 없음"; }),
                SGStatRow(@"Source channels", ^NSString *{ NSNumber *n = sourceInfo()[@"channels"] ?: SGAddonMediaInfo()[@"channels"]; return n ? n.stringValue : @"알 수 없음"; }),
                SGStatRow(@"평균 파일 비트레이트", ^NSString *{ NSNumber *n = sourceInfo()[@"averageKbps"] ?: SGAddonMediaInfo()[@"averageKbps"]; return n ? [NSString stringWithFormat:@"%.0f kbps", n.doubleValue] : @"알 수 없음"; }),
                SGStatRow(@"Spotify codec / bitrate", ^NSString *{ return @"Not exposed by the verified player API"; }),
            ], @"Prepared format values come from the file decoder. They do not prove those frames are audible. The selection row checks recent replacement at the local output. An unknown source depth remains unknown."),
            SGNotedSection(@"Local output & processing", @[
                SGStatRow(@"클라이언트 PCM", ^NSString *{ AudioStreamBasicDescription f = {0}; return SGPlayerMusicClientFormat(&f) ? [NSString stringWithFormat:@"%@ · %u ch · %u bit", hz(f.mSampleRate), (unsigned)f.mChannelsPerFrame, (unsigned)f.mBitsPerChannel] : @"사용 불가"; }),
                SGStatRow(@"오디오 세션 레이트", ^NSString *{ return hz(AVAudioSession.sharedInstance.sampleRate); }),
                SGStatRow(@"Route", ^NSString *{ NSMutableArray *names = [NSMutableArray array]; for (AVAudioSessionPortDescription *p in AVAudioSession.sharedInstance.currentRoute.outputs) [names addObject:p.portName]; return names.count ? [names componentsJoinedByString:@", "] : @"No local route"; }),
                SGStatRow(@"Output latency", ^NSString *{ return [NSString stringWithFormat:@"%.0f ms", AVAudioSession.sharedInstance.outputLatency * 1000]; }),
                SGStatRow(@"Speed / pitch", ^NSString *{ return [NSString stringWithFormat:@"%.2f× / %+.1f st", SGPlayerSpeed(), SGPlayerPitch()]; }),
                SGStatRow(@"노래방", ^NSString *{ return SGSingOn() ? @"켜짐" : @"꺼짐"; }),
                SGStatRow(@"애드온 터널", ^NSString *{ return SGWireGuardStatus()[@"state"]; }),
            ], @"A high resolution source may be resampled to the client rate. Float32 PCM does not establish source bit depth or bit-perfect playback. Bluetooth may encode again. These local values do not describe a remote Spotify Connect renderer."),
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
