#import "SGWiredOutput.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/AudioSources/SGAddons.h"
#import "Core/SGCore.h"
#import <AVFoundation/AVFoundation.h>

static NSObject *control(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; }); return lock;
}
static NSDictionary *sg_status;
static double sg_previousPreference, sg_previousClient, sg_requested;
static AudioUnit sg_changedOutput;
static uint64_t sg_changedIdentity;
static NSString *sg_savedRoute;

static void status(NSString *state, NSString *detail) {
    @synchronized (SGKeyWiredSourceOutput) { sg_status = @{@"state": state, @"detail": detail}; }
}
static NSString *wiredRoute(void) {
    NSArray<AVAudioSessionPortDescription *> *ports = AVAudioSession.sharedInstance.currentRoute.outputs;
    if (ports.count != 1) return nil;
    AVAudioSessionPortDescription *port = ports.firstObject;
    if (![@[AVAudioSessionPortUSBAudio, AVAudioSessionPortHeadphones, AVAudioSessionPortLineOut] containsObject:port.portType]) return nil;
    return [NSString stringWithFormat:@"%@:%@", port.portType, port.UID];
}
BOOL SGWiredOutputPreserveLevel(void) {
    return SGFlag(SGKeyWiredSourceOutput, NO) && wiredRoute() != nil;
}
NSDictionary *SGWiredOutputStatus(void) {
    @synchronized (SGKeyWiredSourceOutput) {
        if ([sg_status[@"state"] isEqualToString:@"Restore pending"]) return sg_status;
    }
    if (!SGFlag(SGKeyWiredSourceOutput, NO)) return @{@"state": @"Off", @"detail": @"Wired source output is off"};
    if (!wiredRoute()) return @{@"state": @"Wired only", @"detail": @"Connect a USB DAC, wired headphones or line output"};
    @synchronized (SGKeyWiredSourceOutput) {
        return sg_status ?: @{@"state": @"Waiting", @"detail": @"Waiting for a local or addon lossless file"};
    }
}
// Caller holds control(). A recycled or newly configured Spotify output is never restored by
// an old pointer alone: both route and current negotiated rate must still match our request.
static BOOL restore(void) {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    AudioStreamBasicDescription current = {0};
    if (sg_changedOutput && [wiredRoute() isEqualToString:sg_savedRoute]
        && SGPlayerMusicOutput() == sg_changedOutput && SGPlayerMusicOutputIdentity() == sg_changedIdentity && SGPlayerMusicClientFormat(&current)
        && fabs(current.mSampleRate - sg_requested) < 0.5) {
        NSString *reason;
        if (!SGPlayerTryMusicSampleRate(sg_previousClient, sg_changedIdentity, &reason)) {
            status(@"Restore pending", [NSString stringWithFormat:@"Resume playback to retry restoring the previous app rate, or restart Spotify. %@", reason ?: @""]);
            return NO;
        }
    }
    // Restore only a preference we still own. This releases the wired preference when a route
    // goes away; it does not choose a Bluetooth codec, rate or output device.
    if (sg_requested > 0 && fabs(session.preferredSampleRate - sg_requested) < 0.5
        && ![session setPreferredSampleRate:sg_previousPreference error:NULL]) {
        status(@"Restore pending", @"iOS did not restore the previous rate preference. Resume playback to retry, or restart Spotify.");
        return NO;
    }
    sg_changedOutput = NULL; sg_changedIdentity = 0; sg_previousPreference = sg_previousClient = sg_requested = 0; sg_savedRoute = nil;
    return YES;
}
static BOOL undoPreference(double previous, double requested) {
    if ([AVAudioSession.sharedInstance setPreferredSampleRate:previous error:NULL]) return YES;
    if (!sg_requested) {
        sg_previousPreference = previous; sg_requested = requested;
        sg_changedOutput = NULL; sg_changedIdentity = 0;
    }
    status(@"Restore pending", @"iOS did not release the requested rate. Resume playback to retry, or restart Spotify.");
    return NO;
}
void SGWiredOutputPrepare(NSString *path) {
    @synchronized (control()) {
        NSString *route = wiredRoute();
        if (!path || !route || !SGFlag(SGKeyWiredSourceOutput, NO)) {
            if (!restore()) return;
            status(@"Waiting", @"Waiting for a local or addon lossless file");
            return;
        }
        ExtAudioFileRef file = NULL;
        AudioStreamBasicDescription source = {0}; UInt32 size = sizeof source;
        OSStatus read = ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &file);
        if (!read) read = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source);
        if (file) ExtAudioFileDispose(file);
        if (read || (source.mFormatID != kAudioFormatFLAC && source.mFormatID != kAudioFormatAppleLossless)
            || source.mChannelsPerFrame != 2 || !isfinite(source.mSampleRate) || source.mSampleRate < 44100 || source.mSampleRate > 192000) {
            status(@"Unavailable", @"This file cannot use wired source-rate output"); return;
        }
        AVAudioSession *session = AVAudioSession.sharedInstance;
        if (sg_requested && (fabs(sg_requested - source.mSampleRate) >= 0.5 || ![route isEqualToString:sg_savedRoute]))
            if (!restore()) return;
        AudioStreamBasicDescription client = {0};
        if (!SGPlayerMusicClientFormat(&client)) { status(@"Waiting", @"Spotify has no active local output"); return; }
        if (sg_requested && [route isEqualToString:sg_savedRoute] && fabs(client.mSampleRate - source.mSampleRate) < 0.5
            && fabs(session.sampleRate - source.mSampleRate) < 0.5) {
            status(@"Rate matched", [NSString stringWithFormat:@"Source, app and device: %.0f Hz. Source level is preserved. Bit transparency is not measured.", source.mSampleRate]);
            return;
        }
        // Category, activation, route selection and device volume remain Spotify/iOS owned.
        double previous = session.preferredSampleRate;
        NSError *error;
        if (![route isEqualToString:wiredRoute()]) return;
        status(@"Negotiating", @"Requesting the measured file rate from the wired device");
        BOOL accepted = [session setPreferredSampleRate:source.mSampleRate error:&error];
        if (!accepted || ![route isEqualToString:wiredRoute()] || fabs(session.sampleRate - source.mSampleRate) >= 0.5) {
            if (accepted && !undoPreference(previous, source.mSampleRate)) return;
            status(@"Device limit", [NSString stringWithFormat:@"Requested %.0f Hz; device uses %.0f Hz. Existing app format retained.", source.mSampleRate, session.sampleRate]);
            return;
        }
        // A hardware rate change can make Spotify replace its RemoteIO chain. Pin the new
        // chain, and remember its own pre-change client rate, rather than a disposed unit's.
        uint64_t identity = SGPlayerMusicOutputIdentity();
        if (!SGPlayerMusicClientFormat(&client)) {
            if (!undoPreference(previous, source.mSampleRate)) return;
            status(@"Waiting", @"Spotify is rebuilding its local output. Retry the current track."); return;
        }
        NSString *reason;
        BOOL configured = SGPlayerTryMusicSampleRate(source.mSampleRate, identity, &reason);
        if (!configured) {
            if (!undoPreference(previous, source.mSampleRate)) return;
            status(@"App limit", reason ?: @"Spotify retained its existing output format"); return;
        }
        if (!sg_requested) sg_previousPreference = previous;
        if (!sg_requested || sg_changedIdentity != identity) {
            sg_previousClient = client.mSampleRate;
            sg_changedOutput = SGPlayerMusicOutput(); sg_changedIdentity = identity; sg_savedRoute = route;
        }
        sg_requested = source.mSampleRate;
        BOOL exact = [route isEqualToString:wiredRoute()] && SGPlayerMusicClientFormat(&client)
            && fabs(client.mSampleRate - source.mSampleRate) < 0.5 && fabs(session.sampleRate - source.mSampleRate) < 0.5;
        status(exact ? @"Rate matched" : @"Not matched", exact
            ? [NSString stringWithFormat:@"Source, app and device: %.0f Hz. Source level is preserved. Bit transparency is not measured.", source.mSampleRate]
            : @"Output changed during negotiation; inspect the actual rates in Playback details");
    }
}
static void reset(void) {
    SGPlayerInvalidateSource();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SGWiredOutputPrepare(nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:SGAddonRetryNotification object:nil];
        });
    });
}
void SGWiredOutputSettingsChanged(void) { reset(); }
