// Anchors the playing track's lossless file again whenever the anchor stops holding: a new track, a seek, a resume.
// Only at normal speed with Karaoke off; anything else leaves Spotify's own sound.
#import "Core/SGCore.h"
#import <objc/runtime.h>
#import <objc/message.h>
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
    NSArray *_upcomingIdentity, *_queueUpcoming;
    id _queueFetch;
    uint64_t _queueFetchSerial;
    BOOL _queuePending;
    double _queueFetchedAt;
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
// state.future is only a short window on Spotify 9.1.90. The complete native
// queue API is also used by PlayerHistory; query it locally, never reconstruct a playlist.
- (void)updateUpcoming:(NSArray<NSDictionary *> *)fallback state:(SPTPlayerState *)state {
    BOOL enabled=SGRedesignedUI() && SGFlag(SGKeyAddons,NO)
        && SGAddonPlaybackMode()==SGAddonPlaybackContinuous && SGFlag(SGKeyAddonPrefetchEnabled,YES);
    if (!enabled) {
        ++_queueFetchSerial; _queuePending=NO; _queueFetch=nil; _queueUpcoming=nil; _upcomingIdentity=nil;
        SGAddonUpdateUpcoming(@[]); return;
    }
    NSString *trackUID=[state.track respondsToSelector:NSSelectorFromString(@"UID")] ? [state.track valueForKey:@"UID"] : @"";
    NSArray *identity=@[SGURIString(state.track.URI) ?: @"", trackUID ?: @"",
        SGURIString(state.contextURI) ?: @"", @(state.options.shufflingContext), [fallback valueForKey:@"uri"]];
    if (![_upcomingIdentity isEqual:identity]) {
        _upcomingIdentity=identity; _queueUpcoming=nil; _queueFetchedAt=0;
        _queueFetch=nil; _queuePending=NO; ++_queueFetchSerial;
    }
    SGAddonUpdateUpcoming(_queueUpcoming ?: fallback);
    double now=NSProcessInfo.processInfo.systemUptime;
    id player=SGPlayer(); SEL selector=NSSelectorFromString(@"getQueueWithCallback:");
    NSMethodSignature *signature=[player methodSignatureForSelector:selector];
    if (_queuePending && now-_queueFetchedAt>=3) { _queuePending=NO; _queueFetch=nil; ++_queueFetchSerial; }
    if (_queuePending || now-_queueFetchedAt<3 || ![player respondsToSelector:selector]
        || signature.numberOfArguments!=3 || signature.methodReturnType[0]!='@') return;
    _queuePending=YES; _queueFetchedAt=now;
    uint64_t serial=++_queueFetchSerial;
    __weak SGLosslessCoordinator *weakSelf=self;
    id (^received)(id)=^id(id queue) {
        NSArray *items=[queue respondsToSelector:NSSelectorFromString(@"nextTracks")] ? [[queue valueForKey:@"nextTracks"] copy] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            SGLosslessCoordinator *owner=weakSelf;
            if (!owner || serial!=owner->_queueFetchSerial || ![identity isEqual:owner->_upcomingIdentity]) return;
            owner->_queuePending=NO; owner->_queueFetch=nil;
            if (![items isKindOfClass:NSArray.class]) return;
            NSMutableArray *tracks=[NSMutableArray array];
            NSUInteger count=0;
            for (id value in items) {
                if (count++==SGAddonPrefetchMaxTracks) break;
                if (![value isKindOfClass:objc_getClass("SPTPlayerTrack")]) break;
                SPTPlayerTrack *item=value; NSString *track=SGURIString(item.URI);
                if (!track.length || !item.trackTitle.length || !item.artistName.length) break;
                [tracks addObject:@{@"uri":track,@"title":item.trackTitle,@"artist":item.artistName,
                    @"duration":@([item.metadata[@"duration"] doubleValue]/1000)}];
            }
            // Never drop a better current state window while queue metadata is still loading.
            owner->_queueUpcoming=tracks.count>=fallback.count ? [tracks copy] : fallback;
            SGAddonUpdateUpcoming(owner->_queueUpcoming);
        });
        return nil;
    };
    _queueFetch=((id(*)(id,SEL,id))objc_msgSend)(player,selector,received);
}
- (void)retryAddons:(NSNotification *)note {
    if ([_path.stringByDeletingLastPathComponent.lastPathComponent isEqualToString:@"vitrine-addons"]) {
        SGPlayerInvalidateSource();
        SGLosslessStop(YES);
        ++_occurrence;
        [NSFileManager.defaultManager removeItemAtPath:_path error:NULL];
        _path = nil;
        _failures = 0; _gaveUpEpoch = 0; _retryAt = 0;
        dispatch_async(sg_storeQueue, ^{ SGWiredOutputPrepare(nil); });
    }
    _addonAsked = NO;
    [self tick];
}
- (void)downloadFinished:(NSNotification *)note {
    if (![_path isEqual:note.object] || SGLosslessPlaying()) return;
    // A native parser that could not use the growing prefix gets a complete-file retry,
    // without resolving the URL or downloading the recording again.
    _failures=0; _gaveUpEpoch=0; _retryAt=0;
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
    if (state.isPlaying && !state.isPaused && fabs(state.playbackSpeed-1)<.001 && !SGSingOn()) SGLosslessBeginCapture();
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
    if (SGFlag(SGKeyAddons, NO) && SGAddonPlaybackMode() != SGAddonPlaybackFast && !_path && _looked && !_addonAsked && track && state.isPlaying && !state.isPaused &&
        state.duration > 0 && state.track.trackTitle.length && state.track.artistName.length) {
        _addonAsked = YES;
        uint64_t occurrence = _occurrence;
        SGAddonBeginPlaybackWait(track);
        SGAddonPrepare(track, state.track.trackTitle, state.track.artistName, state.duration, ^(NSString *path) {
            if (occurrence != self->_occurrence) {
                if (path) [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
                return;
            }
            SGAddonFinishPlaybackWait();
            if (path) { self->_path = path; [self tick]; }
        });
    }
    // Use Spotify's already shuffled/queued order; never infer a playlist order ourselves.
    NSMutableArray *upcomingTracks = [NSMutableArray array];
    for (id value in [future isKindOfClass:NSArray.class] ? future : @[]) {
        if (![value isKindOfClass:objc_getClass("SPTPlayerTrack")]) continue;
        SPTPlayerTrack *item = value;
        NSString *uri = SGURIString(item.URI);
        if (!uri.length || !item.trackTitle.length || !item.artistName.length) continue;
        [upcomingTracks addObject:@{@"uri":uri, @"title":item.trackTitle, @"artist":item.artistName,
                                    @"duration":@([item.metadata[@"duration"] doubleValue] / 1000)}];
        if (upcomingTracks.count == SGAddonPrefetchMaxTracks) break;
    }
    [self updateUpcoming:upcomingTracks state:state];
    if (!_path || _busy || SGLosslessPlaying()) return;
    if (!state.isPlaying || state.isPaused || fabs(state.playbackSpeed - 1) > 0.001 || SGSingOn()) return;
    uint64_t epoch = SGPlayerSourceEpoch();
    if (_gaveUpEpoch && _gaveUpEpoch == epoch) return;
    double now = CFAbsoluteTimeGetCurrent();
    if (now < _retryAt) return;

    _busy = YES;
    SGAddonSetPreparationStage(SGAddonPreparationAligning,@"정렬 준비 중 · Spotify 소리 수집 대기");
    NSString *path = _path;
    uint64_t occurrence = _occurrence;
    double hint = state.position;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error;
        NSDictionary *anchored = nil;
        if (epoch != SGPlayerSourceEpoch()) error = @"the source changed before preparation";
        else {
            SGWiredOutputPrepare(path);
            anchored = SGLosslessAnchorWithProgress(path,hint,^(SGLosslessPreparationPhase phase) {
                uint64_t source=SGPlayerSourceEpoch();
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (occurrence!=self->_occurrence || ![path isEqual:self->_path] || source!=SGPlayerSourceEpoch()) return;
                    if (phase==SGLosslessPhaseDecode)
                        SGAddonSetPreparationStage(SGAddonPreparationDecoding,@"재생 위치 주변 음원 디코딩 중");
                    else if (phase==SGLosslessPhaseCapture)
                        SGAddonSetPreparationStage(SGAddonPreparationAligning,@"정렬 중 · Spotify 소리 수집 및 연속 구간 확인 중");
                    else SGAddonSetPreparationStage(SGAddonPreparationAligning,@"정렬 중 · Spotify 소리와 음원 비교 중");
                });
            },&error);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            if (occurrence != self->_occurrence || ![track isEqualToString:self->_track]) return;
            if (anchored) {
                SGAddonSetPlaybackStatus(@"오디오 정렬 완료 · 상세 재생 정보에서 최근 외부 출력 프레임을 확인하세요", YES);
                self->_failures = 0;
                // Addon files are transient, not entries in Documents/Lossless's local index.
                if ([path.stringByDeletingLastPathComponent isEqualToString:SGLosslessStoreDirectory()])
                    SGLosslessStoreRemember(track, path);
                SGLog(@"lossless: playing %@ from %.2f s", path.lastPathComponent, [anchored[@"file_seconds"] doubleValue]);
                return;
            }
            SGAddonSetPlaybackStatus([NSString stringWithFormat:@"오디오 정렬 실패: %@", error ?: @"일치하지 않는 녹음"], NO);
            self->_retryAt = CFAbsoluteTimeGetCurrent() + kRetrySeconds;
            if (++self->_failures >= kTries) {
                self->_failures = 0;
                self->_gaveUpEpoch = SGPlayerSourceEpoch();
                SGAddonSetPlaybackUnavailable();
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
        [NSNotificationCenter.defaultCenter addObserver:coordinator selector:@selector(downloadFinished:) name:SGAddonDownloadFinishedNotification object:nil];
        SGAddPlayerStateObserver(coordinator);
    });
}
