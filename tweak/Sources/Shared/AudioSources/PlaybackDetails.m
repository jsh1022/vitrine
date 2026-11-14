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

static NSString *hz(double rate) { return rate > 0 ? [NSString stringWithFormat:@"%.1f kHz", rate / 1000] : @"Unknown"; }
static NSDictionary *sourceInfo(void) { return SGLosslessSourceInfo(); }
UIViewController *SGPlaybackDetailsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Playback details" intro:@"Values refresh while this page is open. Source metadata and the local audio output describe different stages."
        sections:@[
            SGSection(@"Track", @[
                SGStatRow(@"Title", ^NSString *{ return SGPlayerState().track.trackTitle ?: @"No track"; }),
                SGStatRow(@"Artist", ^NSString *{ return SGPlayerState().track.artistName ?: @"—"; }),
                SGStatRow(@"Spotify URI", ^NSString *{ return SGURIString(SGPlayerState().track.URI) ?: @"—"; }),
                SGStatRow(@"State", ^NSString *{ SPTPlayerState *s = SGPlayerState(); return !s ? @"No player" : s.isLoading ? @"Loading" : s.isPaused ? @"Paused" : s.isPlaying ? @"Playing" : @"Stopped"; }),
                SGStatRow(@"Position / duration", ^NSString *{ SPTPlayerState *s = SGPlayerState(); return [NSString stringWithFormat:@"%.1f / %.1f s", s.position, s.duration]; }),
            ]),
            SGNotedSection(@"Source", @[
                SGStatRow(@"Audio selected", ^NSString *{ return SGLosslessRendering() ? @"External lossless frames reaching local output" : SGLosslessPlaying() ? @"Aligned; external output not confirmed now" : @"Spotify"; }),
                SGStatRow(@"Addon preparation", ^NSString *{ return SGAddonStatus(); }),
                SGStatRow(@"Prepared codec", ^NSString *{ return sourceInfo()[@"codec"] ?: SGAddonMediaInfo()[@"codec"] ?: @"Unknown"; }),
                SGStatRow(@"Source sample rate", ^NSString *{ return hz([(sourceInfo()[@"rate"] ?: SGAddonMediaInfo()[@"rate"]) doubleValue]); }),
                SGStatRow(@"Source bit depth", ^NSString *{ NSInteger bits = [(sourceInfo()[@"bits"] ?: SGAddonMediaInfo()[@"bits"]) integerValue]; return bits > 0 ? [NSString stringWithFormat:@"%ld bit", (long)bits] : @"Unknown"; }),
                SGStatRow(@"Source channels", ^NSString *{ NSNumber *n = sourceInfo()[@"channels"] ?: SGAddonMediaInfo()[@"channels"]; return n ? n.stringValue : @"Unknown"; }),
                SGStatRow(@"Average file bitrate", ^NSString *{ NSNumber *n = sourceInfo()[@"averageKbps"] ?: SGAddonMediaInfo()[@"averageKbps"]; return n ? [NSString stringWithFormat:@"%.0f kbps", n.doubleValue] : @"Unknown"; }),
                SGStatRow(@"Spotify codec / bitrate", ^NSString *{ return @"Not exposed by the verified player API"; }),
            ], @"Prepared format values come from the file decoder. They do not prove those frames are audible. The selection row checks recent replacement at the local output. An unknown source depth remains unknown."),
            SGNotedSection(@"Local output & processing", @[
                SGStatRow(@"Client PCM", ^NSString *{ AudioStreamBasicDescription f = {0}; return SGPlayerMusicClientFormat(&f) ? [NSString stringWithFormat:@"%@ · %u ch · %u bit", hz(f.mSampleRate), (unsigned)f.mChannelsPerFrame, (unsigned)f.mBitsPerChannel] : @"Unavailable"; }),
                SGStatRow(@"Audio session rate", ^NSString *{ return hz(AVAudioSession.sharedInstance.sampleRate); }),
                SGStatRow(@"Route", ^NSString *{ NSMutableArray *names = [NSMutableArray array]; for (AVAudioSessionPortDescription *p in AVAudioSession.sharedInstance.currentRoute.outputs) [names addObject:p.portName]; return names.count ? [names componentsJoinedByString:@", "] : @"No local route"; }),
                SGStatRow(@"Output latency", ^NSString *{ return [NSString stringWithFormat:@"%.0f ms", AVAudioSession.sharedInstance.outputLatency * 1000]; }),
                SGStatRow(@"Speed / pitch", ^NSString *{ return [NSString stringWithFormat:@"%.2f× / %+.1f st", SGPlayerSpeed(), SGPlayerPitch()]; }),
                SGStatRow(@"Karaoke", ^NSString *{ return SGSingOn() ? @"On" : @"Off"; }),
                SGStatRow(@"Addon tunnel", ^NSString *{ return SGWireGuardStatus()[@"state"]; }),
            ], @"A high resolution source may be resampled to the client rate. Float32 PCM does not establish source bit depth or bit-perfect playback. Bluetooth may encode again. These local values do not describe a remote Spotify Connect renderer."),
        ] footer:nil];
}
void SGShowPlaybackDetails(void) {
    UIViewController *page = SGPlaybackDetailsPage();
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    page.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:page action:@selector(sg_closePlaybackDetails)];
    SGShowAudioController(nav);
}
// SGPage already conforms to Spotify's page protocol; a local category just closes the modal.
@implementation SGPage (SGPlaybackDetailsClosing)
- (void)sg_closePlaybackDetails { [self dismissViewControllerAnimated:YES completion:nil]; }
@end
