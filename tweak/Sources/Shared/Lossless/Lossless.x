// Anchors the playing track's lossless file again whenever the anchor stops holding: a new track, a seek, a resume.
// Only at normal speed with Karaoke off; anything else leaves Spotify's own sound.
#import "Core/SGCore.h"
#import <objc/runtime.h>
#import "Shared/Player/PlayerState.h"
#import "Shared/Sing/Sing.h"
#import "Shared/Player/SpeedPitch.h"
#import "SGLossless.h"
#import "SGWiredOutput.h"
#import "SGLosslessStore.h"
#import "LosslessQuality.h"
#import "Shared/AudioSources/SGAddons.h"

static const int kTries = 3;            // failed anchors in a row before waiting for the next change of source
static const double kRetrySeconds = 2;
// The store's lookups read the folder and open untagged files, so they run here, one at a time.
static dispatch_queue_t sg_storeQueue;

@interface SGLosslessCoordinator : NSObject <SGPlayerStateObserver>
@end

@implementation SGLosslessCoordinator {
    NSString *_track, *_path;
    BOOL _busy, _looked, _looking, _nextHas, _nextLooking;
    NSString *_next;
    NSTimer *_ticker;
    NSDate *_folderChanged;
    int _failures;
    uint64_t _gaveUpEpoch;
    double _retryAt;
    BOOL _addonAsked;
    uint64_t _occurrence;
}
- (void)retryAddons:(NSNotification *)note {
    _addonAsked = NO;
    [self tick];
}

// Position reports are not change callbacks, and a seek or resume shows only in the source's epoch: while
// Spotify plays, a tick each second catches those, and a file that arrives while the song before plays.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    BOOL playing = state.isPlaying && !state.isPaused;
    if (playing && !_ticker) {
        _ticker = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [self tick]; }];
    } else if (!playing) {
        [_ticker invalidate];
        _ticker = nil;
    }
    [self tick];
}

- (void)tick {
    SPTPlayerState *state = SGPlayerState();
    if (state.isPlaying && !state.isPaused && [SGWiredOutputStatus()[@"state"] isEqualToString:@"Restore pending"])
        dispatch_async(sg_storeQueue, ^{ SGWiredOutputPrepare(nil); });
    NSString *track = SGURIString(state.track.URI);
    if (![track isEqualToString:_track]) {
        SGAddonCancel();
        ++_occurrence;
        _addonAsked = NO;
        if (_path) {
            SGLosslessStop(YES);
            // Restore before the next local lookup completes, including a next song with no
            // replacement file. The main thread never waits for Core Audio reconfiguration.
            dispatch_async(sg_storeQueue, ^{ SGWiredOutputPrepare(nil); });
        }
        if ([_path.stringByDeletingLastPathComponent.lastPathComponent isEqualToString:@"vitrine-addons"])
            [NSFileManager.defaultManager removeItemAtPath:_path error:NULL];
        _track = track;
        _path = nil;
        _looked = NO;
        _failures = 0;
        _gaveUpEpoch = 0;
    }
    // A track's first report can come before its title and length: look again until both are known.
    if (track && !_looked && !_looking) {
        _looking = YES;
        NSString *title = state.track.trackTitle ?: @"";
        double duration = state.duration;
        uint64_t occurrence = _occurrence;
        dispatch_async(sg_storeQueue, ^{
            NSString *path = SGLosslessStoreFile(track, title, duration);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_looking = NO;
                if (occurrence == self->_occurrence && [track isEqualToString:self->_track]) {
                    self->_path = path;
                    self->_looked = path || (title.length && duration > 0);
                    // Not looked yet: the next tick looks again, not this one.
                    if (!self->_looked) return;
                    SGLog(@"lossless: %@ (%.1f s): %@", track, duration, path.lastPathComponent ?: @"no file");
                }
                [self tick];
            });
        });
    }
    // Spotify fetches a song as it starts, so its quality is set while the one before plays.
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    id upcoming = [future isKindOfClass:NSArray.class] ? [(NSArray *)future firstObject] : nil;
    SPTPlayerTrack *next = [upcoming isKindOfClass:objc_getClass("SPTPlayerTrack")] ? upcoming : nil;
    NSString *nextURI = SGURIString(next.URI);
    // Again when the folder changes: a file can arrive while the song before plays.
    NSDate *changed = [NSFileManager.defaultManager attributesOfItemAtPath:SGLosslessStoreDirectory() error:NULL].fileModificationDate;
    if (!_nextLooking && (![nextURI isEqualToString:_next] || ![changed isEqualToDate:_folderChanged])) {
        _next = nextURI;
        _folderChanged = changed;
        _nextHas = NO;
        if (nextURI) {
            // Spotify's quality stays as it is until the answer is in; a tick then sets it.
            _nextLooking = YES;
            NSString *title = next.trackTitle ?: @"";
            dispatch_async(sg_storeQueue, ^{
                BOOL has = SGLosslessStoreHas(nextURI, title);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_nextLooking = NO;
                    self->_nextHas = has;
                    [self tick];
                });
            });
        }
    }
    if (!_nextLooking) SGLosslessLowerQuality(_nextHas);

    // An addon prepares a bounded complete file while Spotify continues. The existing sound
    // correlation, source epoch and normal-speed/Karaoke checks still own the actual handoff.
    if (SGFlag(SGKeyAddons, NO) && !_path && _looked && !_addonAsked && track && state.isPlaying && !state.isPaused &&
        state.duration > 0 && state.track.trackTitle.length && state.track.artistName.length) {
        _addonAsked = YES;
        uint64_t occurrence = _occurrence;
        SGAddonPrepare(track, state.track.trackTitle, state.track.artistName, state.duration, ^(NSString *path) {
            if (occurrence != self->_occurrence) {
                if (path) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
                return;
            }
            if (path) { self->_path = path; [self tick]; }
        });
    }
    if (!_path || _busy || SGLosslessPlaying()) return;
    if (!state.isPlaying || state.isPaused || fabs(state.playbackSpeed - 1) > 0.001 || SGSingOn()) return;
    uint64_t epoch = SGPlayerSourceEpoch();
    if (_gaveUpEpoch && _gaveUpEpoch == epoch) return;
    double now = CFAbsoluteTimeGetCurrent();
    if (now < _retryAt) return;

    _busy = YES;
    NSString *path = _path;
    uint64_t occurrence = _occurrence;
    double hint = state.position;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error;
        NSDictionary *anchored = nil;
        if (epoch != SGPlayerSourceEpoch()) error = @"the source changed before preparation";
        else {
            SGWiredOutputPrepare(path);
            anchored = SGLosslessAnchor(path, hint, &error);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            if (occurrence != self->_occurrence || ![track isEqualToString:self->_track]) return;
            if (anchored) {
                SGAddonSetPlaybackStatus(@"Audio aligned; inspect recent external frames in Playback details", YES);
                self->_failures = 0;
                // Addon files are transient, not entries in Documents/Lossless's local index.
                if ([path.stringByDeletingLastPathComponent isEqualToString:SGLosslessStoreDirectory()])
                    SGLosslessStoreRemember(track, path);
                SGLog(@"lossless: playing %@ from %.2f s", path.lastPathComponent, [anchored[@"file_seconds"] doubleValue]);
                return;
            }
            SGAddonSetPlaybackStatus([NSString stringWithFormat:@"Audio alignment failed: %@", error ?: @"unknown mismatch"], NO);
            self->_retryAt = CFAbsoluteTimeGetCurrent() + kRetrySeconds;
            if (++self->_failures >= kTries) {
                self->_failures = 0;
                self->_gaveUpEpoch = SGPlayerSourceEpoch();
                SGLog(@"lossless: gave up on %@ until the source changes: %@", path.lastPathComponent, error);
            } else {
                SGLog(@"lossless: no anchor (%@)", error);
            }
        });
    });
}
@end

%ctor {
    if (!SGHidden(SGKeyLossless) && !SGFlag(SGKeyAddons, NO)) return;
    sg_storeQueue = dispatch_queue_create("spotifyglass.lossless.store", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    dispatch_async(dispatch_get_main_queue(), ^{
        static SGLosslessCoordinator *coordinator;
        coordinator = [SGLosslessCoordinator new];
        [NSNotificationCenter.defaultCenter addObserver:coordinator selector:@selector(retryAddons:) name:SGAddonRetryNotification object:nil];
        SGAddPlayerStateObserver(coordinator);
    });
}
