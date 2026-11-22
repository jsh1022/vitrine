#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>
#import <math.h>
#import <unistd.h>
#import <mach/mach_time.h>
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/AudioSources/SGProgressiveFLAC.h"

// These APIs are implemented by SGLosslessEngine.m. They are deliberately kept in this harness
// until the rolling-capture / upcoming-file API is ready to become part of the public header.
extern void SGLosslessBeginCapture(void);
extern void SGLosslessPrepareNext(NSString * _Nullable path, double rate);

static SGPlayerSourceSelector selectorCallback;
static NSArray<NSNumber *> *lastPhases;
static BOOL progressOnMain;
static _Atomic uint64_t sourceEpoch = 1;
static AudioUnit const fakeOutput = (AudioUnit)(uintptr_t)0x1234;
static atomic_bool driving;
static atomic_uint_fast64_t fedFrames;
static dispatch_semaphore_t driverStopped;
static float *fixtureLeft, *fixtureRight;
static uint64_t fixtureFrames;
static uint64_t fixtureStart;
static float fixtureScale = 0.5f;

void SGPlayerSetSourceSelector(SGPlayerSourceSelector callback) { selectorCallback = callback; }
uint64_t SGPlayerSourceEpoch(void) { return atomic_load(&sourceEpoch); }
void SGPlayerInvalidateSource(void) { atomic_fetch_add(&sourceEpoch, 1); }
BOOL SGWiredOutputPreserveLevel(void) { return NO; }
NSDictionary *SGMeasureLosslessFile(NSString *path, double duration) { return @{}; }

static void require(BOOL ok, NSString *message) {
    NSLog(@"%@ %@", ok ? @"PASS:" : @"FAIL:", message);
    if (!ok) exit(1);
}

static BOOL decodeFixture(NSString *path) {
    ExtAudioFileRef file = NULL;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &file)) return NO;
    UInt32 size = sizeof(SInt64);
    SInt64 count = 0; size = sizeof count;
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &count) || count <= 0) {
        ExtAudioFileDispose(file); return NO;
    }
    AudioStreamBasicDescription client = {44100, kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
    if (ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client)) {
        ExtAudioFileDispose(file); return NO;
    }
    fixtureFrames = (uint64_t)count;
    fixtureLeft = calloc(fixtureFrames, sizeof(float)); fixtureRight = calloc(fixtureFrames, sizeof(float));
    if (!fixtureLeft || !fixtureRight) { ExtAudioFileDispose(file); return NO; }
    struct { AudioBufferList list; AudioBuffer second; } buffers = {{2, {{1, (UInt32)(fixtureFrames * 4), fixtureLeft}}},
                                                                    {1, (UInt32)(fixtureFrames * 4), fixtureRight}};
    UInt32 got = (UInt32)fixtureFrames;
    OSStatus status = ExtAudioFileRead(file, &got, &buffers.list);
    ExtAudioFileDispose(file);
    return !status && got == fixtureFrames;
}

static void feed(void) {
    @autoreleasepool {
        enum { n = 512 };
        float left[n], right[n];
        struct { AudioBufferList list; AudioBuffer second; } data = {{2, {{1, sizeof left, left}}},
                                                                      {1, sizeof right, right}};
        uint64_t frame = 0;
    while (atomic_load(&driving)) {
            for (UInt32 i = 0; i < n; i++) {
                uint64_t f = fixtureStart + frame + i;
                if (f >= fixtureFrames) f %= fixtureFrames;
                left[i] = fixtureLeft[f] * fixtureScale;
                right[i] = fixtureRight[f] * fixtureScale;
            }
            if (selectorCallback) selectorCallback(fakeOutput, SGPlayerSourceEpoch(), (double)frame,
                                                   44100, n, &data.list);
            frame += n;
            atomic_store(&fedFrames, frame);
            usleep((useconds_t)((double)n * 1000000.0 / 44100.0));
        }
        dispatch_semaphore_signal(driverStopped);
    }
}

static void startDriver(void) {
    atomic_store(&fedFrames, 0);
    atomic_store(&driving, true);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ feed(); });
}

static void stopDriver(void) {
    atomic_store(&driving, false);
    require(dispatch_semaphore_wait(driverStopped, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
            @"virtual output driver stops cleanly");
}

static void waitForHistory(void) {
    const uint64_t target = (uint64_t)ceil(4.2 * 44100.0);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while (atomic_load(&fedFrames) < target && deadline.timeIntervalSinceNow > 0) usleep(10000);
    require(atomic_load(&fedFrames) >= target, @"virtual output fills at least 4.2 seconds of history before the bounded deadline");
}

static NSDictionary *anchor(NSString *path, double hint, NSString **error) {
    __block NSDictionary *result;
    __block NSString *failure;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *phases=[NSMutableArray array];
        progressOnMain=NO;
        result = SGLosslessAnchorWithProgress(path,hint,^(SGLosslessPreparationPhase phase) {
            [phases addObject:@(phase)];
            if (NSThread.isMainThread) progressOnMain=YES;
        },&failure);
        lastPhases=[phases copy];
        dispatch_semaphore_signal(done);
    });
    require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC)) == 0,
            @"anchor finishes within the bounded simulator run");
    if (error) *error = failure;
    return result;
}

static NSDictionary *anchorForTrack(NSString *path, NSString *trackIdentity, double hint,
                                    uint64_t hintHostTime, NSString **error) {
    __block NSDictionary *result;
    __block NSString *failure;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *phases=[NSMutableArray array];
        progressOnMain=NO;
        result = SGLosslessAnchorForTrack(path, trackIdentity, hint, hintHostTime,
            ^(SGLosslessPreparationPhase phase) {
                [phases addObject:@(phase)];
                if (NSThread.isMainThread) progressOnMain=YES;
            }, &failure);
        lastPhases=[phases copy];
        dispatch_semaphore_signal(done);
    });
    require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC)) == 0,
            @"track anchor finishes within the bounded simulator run");
    if (error) *error = failure;
    return result;
}

static NSDictionary *trackAnchorAtCurrentOutput(NSString *path, NSString *trackIdentity, NSString **error) {
    // Sample host time and the source hint together, immediately before the synchronous wait begins.
    double hint = (double)(fixtureStart + atomic_load(&fedFrames)) / 44100.0;
    uint64_t hintHostTime = mach_absolute_time();
    return anchorForTrack(path, trackIdentity, hint, hintHostTime, error);
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    require(argc == 3, @"usage: anchor-sim fixture.flac wrong.flac");
    NSString *path = @(argv[1]), *wrong = @(argv[2]);
    require(decodeFixture(path), @"decode deterministic FLAC fixture for virtual Spotify output");
    driverStopped = dispatch_semaphore_create(0);
    // Use a nonzero offset so the test proves correlation, rather than a start-of-file shortcut.
    fixtureStart = 8 * 44100;
    require(fixtureStart + 4 * 44100 < fixtureFrames, @"fixture is long enough for the anchor window");
    SGLosslessBeginCapture();
    startDriver();
    // Keep native output flowing through the 4 s window; BeginCapture should retain its rolling tail.
    waitForHistory();
    double currentHint = fixtureStart / 44100.0 + atomic_load(&fedFrames) / 44100.0;
    NSString *error = nil;
    NSDictionary *result = anchor(path, currentHint, &error);
    NSLog(@"RESULT rolling-anchor: %@ error=%@", result, error);
    require(result != nil, [NSString stringWithFormat:@"same recording anchors (%@)", error ?: @"no error"]);
    require([result[@"match"] doubleValue] >= 0.8, @"normalized correlation exceeds the production threshold");
    require(fabs([result[@"file_frame"] doubleValue] - (fixtureStart + [result[@"source_frame"] doubleValue])) < 2.0,
            @"known recording offset is recovered within two frames");
    require(fabs([result[@"gain"] doubleValue] - fixtureScale) < 0.02, @"alignment gain matches the virtual output level");
    require([result[@"capture_reused_s"] doubleValue] >= 3.9, @"anchor reuses the rolling native capture instead of recording another four seconds");
    require([result[@"search_scope"] isEqual:@"hint"], @"hinted match stays in the local search window");
    require([lastPhases isEqual:@[@(SGLosslessPhaseCapture),@(SGLosslessPhaseDecode),@(SGLosslessPhaseMatch)]],
            @"progress reports real capture, decode and correlation phases in order");
    require(!progressOnMain,@"preparation progress never runs on main or changes the audio render callback");

    // A prepared upcoming file should be reused at anchor time. The engine owns its own bounded cache.
    stopDriver();
    SGLosslessStop(YES);
    fixtureStart = 0;
    SGLosslessBeginCapture();
    startDriver();
    SGLosslessPrepareNext(path, 44100);
    usleep(1000000);
    waitForHistory();
    currentHint = atomic_load(&fedFrames) / 44100.0;
    error = nil;
    NSDictionary *prepared = anchor(path, currentHint, &error);
    NSLog(@"RESULT prepared-anchor: %@ error=%@", prepared, error);
    require(prepared && [prepared[@"predecoded"] boolValue], @"prepared next file is reused by anchor");
    require([prepared[@"decoded_frames"] unsignedLongLongValue] == 0,
            @"predecoded prefix avoids another file decode during anchor");

    // A source epoch transition must invalidate all buffered samples before another anchor.
    SGPlayerInvalidateSource();
    SGLosslessBeginCapture();
    error = nil;
    currentHint = atomic_load(&fedFrames) / 44100.0;
    NSDictionary *afterEpoch = anchor(path, currentHint, &error);
    NSLog(@"RESULT epoch-anchor: %@ error=%@", afterEpoch, error);
    require(afterEpoch != nil, [NSString stringWithFormat:@"same recording reanchors after epoch change (%@)", error ?: @"no error"]);
    require(fabs([afterEpoch[@"file_frame"] doubleValue] - [afterEpoch[@"source_frame"] doubleValue]) < 2.0,
            @"epoch reset reanchors at the recording's actual frame");
    require([afterEpoch[@"capture_reused_s"] doubleValue] < 0.5,
            @"epoch invalidation discards stale rolling history");

    // An independent recording must not pass correlation after a fresh source epoch.
    SGPlayerInvalidateSource();
    SGLosslessBeginCapture();
    currentHint = atomic_load(&fedFrames) / 44100.0;
    NSDictionary *wrongResult = anchor(wrong, currentHint, &error);
    require(!wrongResult, @"an unrelated recording is rejected by the production threshold");
    require(error != nil, @"wrong-recording rejection reports a reason");

    // Exercise the production track-keyed alignment cache across pause/resume and seeks.
    stopDriver();
    SGLosslessStop(YES);
    SGLosslessForgetAlignment();
    NSString *trackPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"vitrine-anchor-track-%@.flac", NSUUID.UUID.UUIDString]];
    require([[NSFileManager defaultManager] copyItemAtPath:path toPath:trackPath error:nil],
            @"copy original fixture to an isolated path for replacement checks");
    fixtureStart = 8 * 44100;
    SGLosslessBeginCapture();
    startDriver();
    waitForHistory();
    error = nil;
    NSDictionary *initialTrack = trackAnchorAtCurrentOutput(trackPath, @"track-A", &error);
    NSLog(@"RESULT track-initial: %@ error=%@", initialTrack, error);
    require(initialTrack && ![initialTrack[@"reused_alignment"] boolValue],
            @"first track-A alignment is computed from the full capture");
    require([initialTrack[@"validation_s"] doubleValue] == 4.0,
            @"first track-A alignment validates with the four-second window");
    require(fabs([initialTrack[@"file_frame"] doubleValue] -
                 (fixtureStart + [initialTrack[@"source_frame"] doubleValue])) <= 2.0,
            @"initial track-A alignment recovers the known offset within two frames");
    require(fabs([initialTrack[@"gain"] doubleValue] - fixtureScale) < 0.02,
            @"initial track-A alignment recovers virtual output gain");

    stopDriver();
    // Pause/resume: a fresh source counter starts at zero while the file continues from this position.
    fixtureStart = 15 * 44100;
    SGPlayerInvalidateSource();
    SGLosslessBeginCapture();
    startDriver();
    usleep(1100000);
    error = nil;
    NSDictionary *resumedTrack = trackAnchorAtCurrentOutput(trackPath, @"track-A", &error);
    NSLog(@"RESULT track-resume: %@ error=%@", resumedTrack, error);
    require(resumedTrack && [resumedTrack[@"reused_alignment"] boolValue],
            @"same track reuses alignment after pause/resume");
    require([resumedTrack[@"validation_s"] doubleValue] == 1.0,
            @"pause/resume reuse validates with one second, without a four-second capture");
    require(fabs([resumedTrack[@"file_frame"] doubleValue] -
                 (fixtureStart + [resumedTrack[@"source_frame"] doubleValue])) <= 2.0,
            @"pause/resume alignment tracks the continued file position within two frames");
    require(fabs([resumedTrack[@"gain"] doubleValue] - fixtureScale) < 0.02,
            @"pause/resume alignment retains the measured output gain");

    stopDriver();
    fixtureStart = 2 * 44100;
    SGPlayerInvalidateSource();
    SGLosslessBeginCapture();
    startDriver();
    usleep(1100000);
    error = nil;
    NSDictionary *seekTrack = trackAnchorAtCurrentOutput(trackPath, @"track-A", &error);
    NSLog(@"RESULT track-seek: %@ error=%@", seekTrack, error);
    require(seekTrack && [seekTrack[@"reused_alignment"] boolValue],
            @"same track reuses alignment after a forward seek following pause");
    require([seekTrack[@"validation_s"] doubleValue] == 1.0,
            @"post-pause seek validates with one second instead of the full window");
    require(fabs([seekTrack[@"file_frame"] doubleValue] -
                 (fixtureStart + [seekTrack[@"source_frame"] doubleValue])) <= 2.0,
            @"post-pause seek follows the new file position within two frames");
    require(fabs([seekTrack[@"gain"] doubleValue] - fixtureScale) < 0.02,
            @"post-pause seek alignment retains the measured output gain");

    stopDriver();
    fixtureStart = 20 * 44100;
    SGPlayerInvalidateSource();
    SGLosslessBeginCapture();
    startDriver();
    usleep(1100000);
    error = nil;
    NSDictionary *forwardSeekTrack = trackAnchorAtCurrentOutput(trackPath, @"track-A", &error);
    NSLog(@"RESULT track-forward-seek: %@ error=%@", forwardSeekTrack, error);
    require(forwardSeekTrack && [forwardSeekTrack[@"reused_alignment"] boolValue],
            @"same track reuses alignment after a forward seek following pause");
    require([forwardSeekTrack[@"validation_s"] doubleValue] == 1.0,
            @"post-pause forward seek validates with one second instead of the full window");
    require(fabs([forwardSeekTrack[@"file_frame"] doubleValue] -
                 (fixtureStart + [forwardSeekTrack[@"source_frame"] doubleValue])) <= 2.0,
            @"post-pause forward seek follows the new file position within two frames");
    require(fabs([forwardSeekTrack[@"gain"] doubleValue] - fixtureScale) < 0.02,
            @"post-pause forward seek alignment retains the measured output gain");

    stopDriver();
    // Deliberately put the hint outside the cached alignment's local verification window.
    fixtureStart = 11 * 44100;
    SGPlayerInvalidateSource();
    SGLosslessBeginCapture();
    startDriver();
    waitForHistory();
    double badHint = (double)(fixtureStart + atomic_load(&fedFrames)) / 44100.0 + 5.0;
    uint64_t badHintHostTime = mach_absolute_time();
    error = nil;
    NSDictionary *badHintTrack = anchorForTrack(trackPath, @"track-A", badHint,
                                                 badHintHostTime, &error);
    NSLog(@"RESULT track-bad-hint: %@ error=%@", badHintTrack, error);
    require(badHintTrack != nil, @"bad cached-location hint falls back to a full track verification");
    require([badHintTrack[@"validation_s"] doubleValue] == 4.0,
            @"failed one-second validation retries with the full four-second window");
    require(fabs([badHintTrack[@"file_frame"] doubleValue] -
                 (fixtureStart + [badHintTrack[@"source_frame"] doubleValue])) <= 2.0,
            @"full verification recovers the actual lag despite the inaccurate hint");
    require(fabs([badHintTrack[@"gain"] doubleValue] - fixtureScale) < 0.02,
            @"full verification preserves the measured output gain after bad hint");

    stopDriver();
    // Keep the same path and track key while atomically substituting unrelated file contents.
    NSString *replacementPath = [trackPath stringByAppendingString:@".replacement"];
    require([[NSFileManager defaultManager] copyItemAtPath:wrong toPath:replacementPath error:nil],
            @"stage unrelated fixture contents without touching the source fixtures");
    require([[NSFileManager defaultManager] removeItemAtPath:trackPath error:nil],
            @"remove isolated original at its cached path");
    require([[NSFileManager defaultManager] moveItemAtPath:replacementPath toPath:trackPath error:nil],
            @"replace isolated fixture at the identical cached path");
    fixtureStart = 11 * 44100;
    SGPlayerInvalidateSource();
    SGLosslessBeginCapture();
    startDriver();
    waitForHistory();
    error = nil;
    NSDictionary *replacedTrackFile = trackAnchorAtCurrentOutput(trackPath, @"track-A", &error);
    NSLog(@"RESULT track-replaced-path: %@ error=%@", replacedTrackFile, error);
    require(!replacedTrackFile || ![replacedTrackFile[@"reused_alignment"] boolValue],
            @"same-path replacement cannot reuse the old alignment proof or reader");
    require(!replacedTrackFile, @"replacement file contents are rejected for the existing track proof");
    stopDriver();
    [[NSFileManager defaultManager] removeItemAtPath:trackPath error:nil];

    SGPlayerInvalidateSource();
    SGLosslessBeginCapture();
    startDriver();
    usleep(1100000);
    error = nil;
    NSDictionary *differentTrack = trackAnchorAtCurrentOutput(path, @"track-B", &error);
    NSLog(@"RESULT track-B: %@ error=%@", differentTrack, error);
    require(differentTrack && ![differentTrack[@"reused_alignment"] boolValue] &&
            [differentTrack[@"validation_s"] doubleValue] == 4.0,
            @"a different track identity cannot reuse track-A alignment");

    stopDriver();
    SGLosslessForgetAlignment();
    SGPlayerInvalidateSource();
    SGLosslessBeginCapture();
    startDriver();
    usleep(1100000);
    error = nil;
    NSDictionary *forgottenTrack = trackAnchorAtCurrentOutput(path, @"track-A", &error);
    NSLog(@"RESULT track-after-forget: %@ error=%@", forgottenTrack, error);
    require(forgottenTrack && ![forgottenTrack[@"reused_alignment"] boolValue] &&
            [forgottenTrack[@"validation_s"] doubleValue] == 4.0,
            @"forgetting alignment forces a full validation when returning to track-A");

    stopDriver();
    SGLosslessForgetAlignment();
    SGPlayerInvalidateSource();
    SGLosslessBeginCapture();
    startDriver();
    usleep(1100000);
    error = nil;
    NSDictionary *wrongTrackFile = anchorForTrack(wrong, @"track-A",
        (double)(fixtureStart + atomic_load(&fedFrames)) / 44100.0, mach_absolute_time(), &error);
    NSLog(@"RESULT wrong-track-file: %@ error=%@", wrongTrackFile, error);
    require(!wrongTrackFile || ![wrongTrackFile[@"reused_alignment"] boolValue],
            @"a different file path cannot reuse the cached track alignment");
    require(!wrongTrackFile, @"wrong file path is not accepted for track-A");
    stopDriver();
    SGLosslessStop(YES);
    NSLog(@"PASS: actual lossless engine rolling capture, local correlation and prepared-file path");
} return 0; }
