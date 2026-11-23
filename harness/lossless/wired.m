#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <math.h>
#import "Shared/Lossless/SGWiredOutput.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/Player/SpeedPitch.h"
#import "Core/SGPrefs.h"
#import "Shared/AudioSources/SGAddons.h"

@interface WiredPort : NSObject
@property(nonatomic, copy) NSString *portType;
@property(nonatomic, copy) NSString *UID;
@end
@implementation WiredPort @end
@interface WiredRoute : NSObject
@property(nonatomic, copy) NSArray *outputs;
@end
@implementation WiredRoute @end

@interface WiredSession : NSObject
@property(nonatomic) double sampleRate;
@property(nonatomic) double preferredSampleRate;
@property(nonatomic) double previousPreference;
@property(nonatomic) BOOL failPreference;
@property(nonatomic, strong) WiredRoute *route;
@property(nonatomic, strong) NSMutableArray<NSString *> *events;
@end
@implementation WiredSession
- (BOOL)setPreferredSampleRate:(double)rate error:(NSError **)error {
    [self.events addObject:[NSString stringWithFormat:@"preference:%.0f", rate]];
    if (self.failPreference) {
        if (error) *error = [NSError errorWithDomain:@"wired-harness" code:1 userInfo:nil];
        return NO;
    }
    self.preferredSampleRate = rate;
    self.sampleRate = rate;
    return YES;
}
- (WiredRoute *)currentRoute { return self.route; }
@end

static WiredSession *session;
static uint64_t epoch = 7, identity = 11;
static double clientRate = 44100;
static BOOL enabled = YES, prepareOK = YES;
static NSUInteger prepareCalls, tryCalls;
static NSString *const addonRetry = @"wired-harness-addon-retry";

static id sharedSession(id self, SEL _cmd) { return session; }
static void require(BOOL value, NSString *message) {
    NSLog(@"%@ %@", value ? @"PASS:" : @"FAIL:", message);
    if (!value) exit(1);
}
static void resetState(double client, double hardware, double preference) {
    SGWiredOutputPrepare(nil);
    session = [WiredSession new];
    session.sampleRate = hardware;
    session.preferredSampleRate = preference;
    session.previousPreference = preference;
    session.events = [NSMutableArray array];
    WiredPort *port = [WiredPort new]; port.portType = AVAudioSessionPortUSBAudio; port.UID = @"test-dac";
    WiredRoute *route = [WiredRoute new]; route.outputs = @[port]; session.route = route;
    clientRate = client; enabled = YES; prepareOK = YES; prepareCalls = tryCalls = 0;
    [session.events removeAllObjects];
}
static void run(NSString *path, double hint) {
    SGWiredOutputPrepareForPosition(path, hint, epoch);
}
static void checkSource(NSString *path, double rate) {
    ExtAudioFileRef file = NULL;
    require(ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &file) == noErr,
            @"native ExtAudioFile opens generated FLAC fixture");
    AudioStreamBasicDescription format = {0}; UInt32 size = sizeof format;
    OSStatus result = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format);
    ExtAudioFileDispose(file);
    require(result == noErr && fabs(format.mSampleRate-rate)<0.5 && format.mChannelsPerFrame==2,
            [NSString stringWithFormat:@"fixture metadata is stereo %.0f Hz", rate]);
}

BOOL SGFlag(NSString *key, BOOL fallback) { (void)key; return enabled ? YES : fallback; }
BOOL SGProgressiveFLACRegistered(NSString *path) { (void)path; return NO; }
BOOL SGProgressiveFLACOpen(NSString *path, ExtAudioFileRef *file, CFTypeRef *owner, BOOL (^cancelled)(void)) {
    (void)path; (void)file; (void)owner; (void)cancelled; return NO;
}
uint64_t SGPlayerSourceEpoch(void) { return epoch; }
void SGPlayerInvalidateSource(void) { epoch++; }
AudioUnit SGPlayerMusicOutput(void) { return (AudioUnit)(uintptr_t)0x1234; }
uint64_t SGPlayerMusicOutputIdentity(void) { return identity; }
BOOL SGPlayerMusicClientFormat(AudioStreamBasicDescription *format) {
    if (!format) return NO;
    memset(format, 0, sizeof(*format)); format->mSampleRate = clientRate; return YES;
}
BOOL SGPlayerTryMusicSampleRate(double rate, uint64_t expectedIdentity, NSString **error) {
    tryCalls++; [session.events addObject:[NSString stringWithFormat:@"try:%.0f", rate]];
    if (expectedIdentity != identity) { if (error) *error = @"stale"; return NO; }
    clientRate = rate; if (error) *error = nil; return YES;
}
BOOL SGLosslessPrepareOutputBuffer(NSString *path, double rate, double hint, uint64_t expectedEpoch) {
    (void)path; (void)hint; (void)rate; (void)expectedEpoch;
    prepareCalls++; [session.events addObject:@"prepare"];
    return prepareOK;
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    require(argc == 3, @"usage: wired-sim fixture-44100.flac fixture-48000.flac");
    NSString *f441 = @(argv[1]), *f480 = @(argv[2]);
    checkSource(f441,44100); checkSource(f480,48000);
    Method method = class_getClassMethod(AVAudioSession.class, @selector(sharedInstance));
    method_setImplementation(method, (IMP)sharedSession);

    resetState(44100,44100,44100); run(f441,0.25);
    require(prepareCalls==0 && tryCalls==0 && session.events.count==0, @"matched 44.1 kHz path makes no preparation, preference, or app-rate calls");

    resetState(44100,44100,44100); run(f480,1.5);
    require(prepareCalls==1 && tryCalls==1 && [session.events.firstObject isEqualToString:@"prepare"], @"PCM preparation precedes the sole 48 kHz app negotiation");
    require(session.events.count>=3 && [session.events[1] isEqualToString:@"preference:48000"] && [session.events[2] isEqualToString:@"try:48000"], @"device preference and app rate follow prepared PCM");
    run(f480,1.75);
    require(prepareCalls==1 && tryCalls==1 && session.events.count==3, @"repeated same-rate request is a no-op");

    run(f441,2.0);
    require(tryCalls==2 && [session.events.lastObject isEqualToString:@"try:44100"], @"direct 48-to-44.1 kHz switch negotiates once without restoring an intermediate rate");
    require(session.events.count==6 && [session.events[3] isEqualToString:@"prepare"]
            && [session.events[4] isEqualToString:@"preference:44100"] && [session.events[5] isEqualToString:@"try:44100"],
            @"prepared PCM directly precedes the one device and app rate switch, with no intermediate restore");

    resetState(44100,44100,32000); prepareOK=NO; run(f480,0.5);
    require(prepareCalls==1 && tryCalls==0 && session.sampleRate==44100 && session.preferredSampleRate==32000,
            @"failed prebuffer leaves hardware preference and app output untouched");

    resetState(44100,44100,32000); run(f480,0.5);
    require(session.preferredSampleRate==48000 && clientRate==48000, @"wired transition owns negotiated preference and app rate");
    SGWiredOutputPrepare(nil);
    require(session.preferredSampleRate==32000 && clientRate==44100 && tryCalls==2,
            @"nil path restores the original preference and client rate");

    resetState(44100,44100,32000); run(f480,0.5);
    session.route = [WiredRoute new]; session.route.outputs = @[];
    SGWiredOutputRouteDidChange();
    require(session.preferredSampleRate==32000 && clientRate==48000 && tryCalls==1,
            @"unplug restores only the owned preference and leaves the detached app output alone");
    NSLog(@"RESULT wired source-rate orchestration passed");
    return 0;
} }
