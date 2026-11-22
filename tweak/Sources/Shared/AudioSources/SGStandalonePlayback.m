#import "SGStandalonePlayback.h"
#import "SGAddons.h"
#import "SGProgressiveFLAC.h"
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/Lossless/SGSourceFileFormat.h"
#import "Shared/Lossless/SGWiredOutput.h"
#import "Shared/Sing/Sing.h"
#import "Shared/AudioEffects/AudioEffects.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/message.h>
#import <stdatomic.h>

static atomic_bool sg_ready, sg_owned, sg_busy;
static atomic_uint_fast64_t sg_transportGeneration;
static _Thread_local BOOL sg_internal;
static NSString *sg_armedURI;
static uint64_t sg_intent;
static NSDictionary *sg_clock, *sg_info;
static NSObject *snapshotLock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; }); return lock;
}
static id get(id object, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    return [object respondsToSelector:sel] ? ((id(*)(id,SEL))objc_msgSend)(object,sel) : nil;
}
static SPTPlayerState *nativeState(void) { return (SPTPlayerState *)get(SGPlayer(), @"state"); }
static NSString *uid(id state) { return [get(get(state,@"track"),@"UID") description] ?: @""; }
static NSString *uri(id state) { return SGURIString(get(get(state,@"track"),@"URI")) ?: @""; }
static void later(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),block);
}
static void nativeCommand(NSString *selector) {
    id player=SGPlayer(); SEL sel=NSSelectorFromString(selector);
    if (![player respondsToSelector:sel]) return;
    BOOL previous=sg_internal; sg_internal=YES;
    ((id(*)(id,SEL,id))objc_msgSend)(player,sel,nil);
    sg_internal=previous;
}
BOOL SGStandaloneInternalCommand(void) { return sg_internal; }
uint64_t SGStandaloneCommandEpoch(void) { return sg_intent; }
void SGStandaloneSetHooksReady(BOOL ready) { atomic_store(&sg_ready,ready); }
BOOL SGStandaloneEnabled(void) { return atomic_load(&sg_ready) && SGRedesignedUI() && SGFlag(SGKeyAddons,NO); }
BOOL SGStandaloneEligible(void) {
    return SGStandaloneEnabled() && SGAddonPlaybackMode()!=SGAddonPlaybackFast && !SGSingOn()
        && fabs(SGPlayerSpeed()-1)<.001 && fabs(SGPlayerPitch())<.001
        && SGPlayerReverb()<=0 && !SGFlag(SGKeyDSP,NO);
}
BOOL SGStandaloneActive(void) { return atomic_load(&sg_owned); }

@interface SGStandaloneDecodeRun : NSObject { @public atomic_uint pending; }
@end
@implementation SGStandaloneDecodeRun
@end

@interface SGStandaloneSession : NSObject {
@public
    atomic_bool cancelled;
    atomic_uint_fast64_t decodeGeneration;
    atomic_uint queued;
    atomic_uint_fast64_t scheduledFrames;
    atomic_bool eof;
}
@property(nonatomic,copy) NSString *path, *uri, *uid;
@property(nonatomic,strong) AVAudioEngine *engine;
@property(nonatomic,strong) AVAudioPlayerNode *node;
@property(nonatomic,strong) AVAudioFormat *format;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) dispatch_queue_t decoder;
@property(nonatomic,copy) void (^completion)(BOOL);
@property(nonatomic) BOOL wanted, started, recovering, interrupted, hasPendingSeek;
@property(nonatomic) double base, position, duration, lastSample, renderedAt, emptyAt, pendingSeek;
- (void)openAt:(double)position;
- (void)tick;
- (void)publish;
- (void)close;
- (void)recover:(NSString *)reason;
- (void)finishStart:(BOOL)success;
@end
static SGStandaloneSession *sg_session;
static __weak SGStandaloneSession *sg_rateOwner;
static double sg_previousRate, sg_requestedRate;
static dispatch_queue_t rateQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue=dispatch_queue_create("spotifyglass.addon.output-rate",DISPATCH_QUEUE_SERIAL); }); return queue;
}
// Serial worker only. Own a preference, never Spotify's AudioUnit or device volume.
static void restoreRate(SGStandaloneSession *session) {
    if (sg_rateOwner!=session) return;
    AVAudioSession *audio=AVAudioSession.sharedInstance;
    if (fabs(audio.preferredSampleRate-sg_requestedRate)<.5) [audio setPreferredSampleRate:sg_previousRate error:NULL];
    sg_rateOwner=nil; sg_requestedRate=0;
}
static void prepareRate(SGStandaloneSession *session, double rate) {
    if (atomic_load(&session->cancelled)) return;
    AVAudioSession *audio=AVAudioSession.sharedInstance;
    NSArray *outputs=audio.currentRoute.outputs;
    NSString *port=outputs.count==1 ? [(AVAudioSessionPortDescription *)outputs[0] portType] : nil;
    BOOL wired=port && [@[AVAudioSessionPortUSBAudio,AVAudioSessionPortHeadphones,AVAudioSessionPortLineOut] containsObject:port];
    if (!SGFlag(SGKeyWiredSourceOutput,NO) || !wired) { restoreRate(session); return; }
    if (sg_rateOwner==session && fabs(rate-sg_requestedRate)<.5) return;
    if (sg_rateOwner) restoreRate(sg_rateOwner);
    double previous=audio.preferredSampleRate;
    if ([audio setPreferredSampleRate:rate error:NULL]) {
        sg_rateOwner=session; sg_previousRate=previous; sg_requestedRate=rate;
        if (atomic_load(&session->cancelled)) restoreRate(session);
    }
}

BOOL SGStandaloneRecovering(NSString *track) { return sg_session.recovering && [sg_session.uri isEqual:track]; }
BOOL SGStandaloneBusy(NSString *track) {
    return atomic_load(&sg_busy) && [sg_session.uri isEqual:track]; // coordinator: main only
}
NSDictionary *SGStandaloneClock(id state) {
    if (!atomic_load(&sg_owned)) return nil;
    @synchronized(snapshotLock()) {
        return [sg_clock[@"uri"] isEqual:uri(state)] && [sg_clock[@"uid"] isEqual:uid(state)] ? sg_clock : nil;
    }
}
NSDictionary *SGStandaloneSourceInfo(void) {
    if (!atomic_load(&sg_owned)) return @{};
    @synchronized(snapshotLock()) { return sg_info ?: @{}; }
}
BOOL SGStandaloneRendering(void) {
    if (!atomic_load(&sg_owned)) return NO;
    @synchronized(snapshotLock()) {
        return [sg_clock[@"playing"] boolValue] && CFAbsoluteTimeGetCurrent()-[sg_clock[@"renderedAt"] doubleValue]<.5;
    }
}
BOOL SGStandaloneOutputFormat(AudioStreamBasicDescription *format) {
    if (!NSThread.isMainThread || !atomic_load(&sg_owned) || !sg_session.engine) return NO;
    AVAudioFormat *output=[sg_session.engine.mainMixerNode outputFormatForBus:0];
    if (!output || output.sampleRate<=0) return NO;
    *format=*output.streamDescription; return YES;
}
static BOOL current(SGStandaloneSession *session) {
    return session==sg_session && !atomic_load(&session->cancelled) && [session.uri isEqual:uri(nativeState())] && (session.recovering || [session.uid isEqual:uid(nativeState())]);
}
@implementation SGStandaloneSession
- (void)finishStart:(BOOL)success {
    void (^done)(BOOL)=self.completion; self.completion=nil;
    if (done) done(success);
}
- (void)close {
    atomic_store(&cancelled,true); atomic_fetch_add(&decodeGeneration,1);
    [self.timer invalidate]; self.timer=nil;
    [self.node stop]; [self.engine stop];
    dispatch_async(rateQueue(), ^{ restoreRate(self); });
    [self finishStart:NO];
}
- (void)publish {
    BOOL playing=self.started && self.wanted && !self.interrupted && self.node.isPlaying && !self.recovering && atomic_load(&queued)>0;
    @synchronized(snapshotLock()) {
        sg_clock=@{@"uri":self.uri,@"uid":self.uid,@"position":@(self.position),@"stamp":@(CFAbsoluteTimeGetCurrent()),
            @"playing":@(playing),@"duration":@(self.duration),@"renderedAt":@(self.renderedAt)};
    }
    SGStandalonePublish();
    NSMutableDictionary *info=[MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo mutableCopy];
    if (info) {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime]=@(self.position);
        info[MPNowPlayingInfoPropertyPlaybackRate]=@(playing ? 1 : 0);
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=info;
    }
    MPNowPlayingInfoCenter.defaultCenter.playbackState=playing ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
}
- (void)tick {
    if (!current(self)) { SGStandaloneCancel(); return; }
    if (self.recovering) return;
    if (!SGStandaloneEligible()) { [self recover:@"재생 처리 설정 변경"]; return; }
    if (!SGStandaloneNativePaused(nativeState())) { SGStandaloneCancel(); return; }
    self.node.volume=SGPlayerGain();
    AVAudioTime *time=self.node.lastRenderTime;
    AVAudioTime *played=time ? [self.node playerTimeForNodeTime:time] : nil;
    if (self.started && played && played.sampleTime>=0 && played.sampleRate>0) {
        double sample=MIN((double)played.sampleTime/played.sampleRate,(double)atomic_load(&scheduledFrames)/self.format.sampleRate);
        if (self.wanted && sample>self.lastSample) self.renderedAt=CFAbsoluteTimeGetCurrent();
        self.lastSample=sample;
        self.position=MIN(self.duration,self.base+sample);
    }
    [self publish];
    if (self.started && self.wanted && !atomic_load(&queued)) {
        if (atomic_load(&eof)) {
            if ([nativeState() options].repeatingTrack) { [self openAt:0]; return; }
            BOOL more=[[nativeState() future] count]>0 || [nativeState() options].repeatingContext;
            if (more) {
                SGStandaloneCancel();
                [(id<SPTPlayer>)SGPlayer() skipToNextTrackWithOptions:nil];
            } else { self.wanted=NO; [self recover:@"재생 목록 끝"]; }
            return;
        }
        // Do not keep a running node clock across an empty output queue.
        self.position=MIN(self.duration,self.base+(double)atomic_load(&scheduledFrames)/self.format.sampleRate);
        [self recover:@"음원 버퍼 부족"];
    }
}
- (void)openAt:(double)position {
    if (!current(self) || self.recovering) return;
    uint64_t generation=atomic_fetch_add(&decodeGeneration,1)+1;
    [self.node stop]; self.started=NO; self.base=self.position=MAX(0,MIN(position,self.duration));
    self.lastSample=0; self.renderedAt=0; self.emptyAt=0;
    atomic_store(&queued,0); atomic_store(&scheduledFrames,0); atomic_store(&eof,false);
    [self publish];
    NSString *path=self.path;
    position=self.base;
    SGStandaloneDecodeRun *run=[SGStandaloneDecodeRun new];
    dispatch_async(self.decoder, ^{
        ExtAudioFileRef file=NULL; CFTypeRef owner=NULL;
        BOOL (^stale)(void)=^BOOL { return atomic_load(&self->cancelled) || generation!=atomic_load(&self->decodeGeneration); };
        OSStatus error=SGProgressiveFLACRegistered(path)
            ? (SGProgressiveFLACOpen(path,&file,&owner,stale) ? noErr : kAudioFileUnspecifiedError)
            : ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],&file);
        AudioStreamBasicDescription source={0}; UInt32 size=sizeof(source);
        if (!error) error=ExtAudioFileGetProperty(file,kExtAudioFileProperty_FileDataFormat,&size,&source);
        if (!error && !SGSourceFileSupported(file,source)) error=kAudioFileUnsupportedDataFormatError;
        if (!error && !stale()) dispatch_sync(rateQueue(), ^{ prepareRate(self,source.mSampleRate); });
        AudioStreamBasicDescription pcm={0};
        pcm.mSampleRate=source.mSampleRate; pcm.mFormatID=kAudioFormatLinearPCM;
        pcm.mFormatFlags=kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved;
        pcm.mChannelsPerFrame=2; pcm.mBitsPerChannel=32; pcm.mBytesPerFrame=pcm.mBytesPerPacket=4; pcm.mFramesPerPacket=1;
        if (!error) error=ExtAudioFileSetProperty(file,kExtAudioFileProperty_ClientDataFormat,sizeof(pcm),&pcm);
        if (!error) error=ExtAudioFileSeek(file,(SInt64)llround(position*source.mSampleRate));
        AVAudioFormat *format=!error ? [[AVAudioFormat alloc]initWithStreamDescription:&pcm] : nil;
        while (!error && !stale()) {
            if (atomic_load(&run->pending)>=8) { [NSThread sleepForTimeInterval:.02]; continue; }
            @autoreleasepool {
                AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc]initWithPCMFormat:format frameCapacity:8192];
                UInt32 frames=8192;
                error=buffer ? ExtAudioFileRead(file,&frames,buffer.mutableAudioBufferList) : kAudio_MemFullError;
                if (error || stale()) break;
                if (!frames) {
                    if (SGProgressiveFLACRegistered(path) && !SGProgressiveFLACComplete(path)) error=kAudioFileEndOfFileError;
                    else dispatch_async(dispatch_get_main_queue(), ^{ if (current(self) && !stale()) atomic_store(&self->eof,true); });
                    break;
                }
                buffer.frameLength=frames;
                atomic_fetch_add(&run->pending,1);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!current(self) || stale()) { atomic_fetch_sub(&run->pending,1); return; }
                    atomic_fetch_add(&self->queued,1);
                    atomic_fetch_add(&self->scheduledFrames,frames);
                    @try {
                    if (!self.engine) {
                        self.format=format; self.engine=[AVAudioEngine new]; self.node=[AVAudioPlayerNode new];
                        self.node.volume=SGPlayerGain();
                        [self.engine attachNode:self.node];
                        [self.engine connect:self.node to:self.engine.mainMixerNode format:format];
                    }
                    [self.node scheduleBuffer:buffer completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
                        atomic_fetch_sub(&run->pending,1);
                        if (!stale()) atomic_fetch_sub(&self->queued,1);
                    }];
                    if (!self.started && (atomic_load(&self->queued)>=2 || self.duration-self.base<.4)) {
                        NSError *failure=nil;
                        if (![AVAudioSession.sharedInstance setActive:YES error:&failure] || ![self.engine startAndReturnError:&failure]) {
                            [self recover:@"자체 오디오 출력 시작 실패"]; return;
                        }
                        self.started=YES;
                        if (self.wanted && !self.interrupted) [self.node play];
                        SGAddonSetPlaybackStatus(@"자체 엔진으로 무손실 음원 재생 중",YES);
                        [self finishStart:YES];
                        [self publish];
                    }
                    } @catch (NSException *exception) { [self recover:@"자체 오디오 출력 구성 실패"]; }
                });
            }
        }
        if (file) ExtAudioFileDispose(file);
        if (owner) CFRelease(owner);
        if (error && !stale()) dispatch_async(dispatch_get_main_queue(), ^{ if (current(self) && !stale()) [self recover:@"무손실 디코딩 실패"]; });
    });
}
- (void)recover:(NSString *)reason {
    if (!current(self) || self.recovering) return;
    self.recovering=YES;
    [NSNotificationCenter.defaultCenter postNotificationName:SGStandaloneFailedNotification object:self.path];
    uint64_t recoveryGeneration=atomic_fetch_add(&decodeGeneration,1)+1;
    double target=self.position;
    [self.node stop]; [self.engine stop]; [self publish];
    SGAddonSetPlaybackStatus([NSString stringWithFormat:@"%@ · Spotify 재생 위치 복구 중",reason],NO);
    id state=nativeState(),track=get(state,@"track");
    if (!track) { SGStandaloneCancel(); return; }
    Class contextClass=NSClassFromString(@"SPTPlayerContext"),optionClass=NSClassFromString(@"SPTPlayOptions"),skipClass=NSClassFromString(@"SPTSkipToTrack");
    SEL contextSelector=NSSelectorFromString(@"contextWithTracks:");
    if (![contextClass respondsToSelector:contextSelector] || !optionClass || ![skipClass instancesRespondToSelector:NSSelectorFromString(@"initWithTrackURI:")]) {
        SGAddonSetPlaybackStatus(@"Spotify 위치 복구 API 없음 · 일시정지를 유지합니다",NO); SGStandaloneCancel(); return;
    }
    NSMutableArray *tracks=[NSMutableArray arrayWithObject:track]; [tracks addObjectsFromArray:get(state,@"future") ?: @[]];
    id context=((id(*)(id,SEL,id))objc_msgSend)(contextClass,contextSelector,tracks);
    for (NSArray *pair in @[@[@"setURI:",@"contextURI"],@[@"setURL:",@"contextURL"],@[@"setMetadata:",@"contextMetadata"]])
        ((void(*)(id,SEL,id))objc_msgSend)(context,NSSelectorFromString(pair[0]),get(state,pair[1]));
    id options=[optionClass new];
    ((void(*)(id,SEL,BOOL))objc_msgSend)(options,NSSelectorFromString(@"setInitiallyPaused:"),YES);
    ((void(*)(id,SEL,id))objc_msgSend)(options,NSSelectorFromString(@"setSeekTo:"),@(target));
    void *allocated=((void*(*)(id,SEL))objc_msgSend)(skipClass,@selector(alloc));
    void *initialized=((void*(*)(void*,SEL,id))objc_msgSend)(allocated,NSSelectorFromString(@"initWithTrackURI:"),get(track,@"URI"));
    ((void(*)(id,SEL,id))objc_msgSend)(options,NSSelectorFromString(@"setSkipTo:"),CFBridgingRelease(initialized));
    BOOL previous=sg_internal; sg_internal=YES;
    ((id(*)(id,SEL,id,id))objc_msgSend)(SGPlayer(),NSSelectorFromString(@"playContext:options:"),context,options);
    sg_internal=previous;
    __weak SGStandaloneSession *weakSelf=self;
    __block void (^poll)(unsigned);
    poll=^(unsigned attempt) {
        SGStandaloneSession *session=weakSelf;
        if (!session || !current(session) || !session.recovering || recoveryGeneration!=atomic_load(&session->decodeGeneration)) { poll=nil; return; }
        id observed=nativeState();
        if (SGStandaloneNativePaused(observed) && fabs(SGStandaloneNativePosition(observed)-target)<.15) {
            BOOL resume=session.wanted && !session.interrupted;
            SGStandaloneCancel(); if (resume) nativeCommand(@"resume:");
            SGAddonSetPlaybackStatus(@"Spotify 기본 스트림으로 재생 위치 복구 완료",NO); SGAddonSetPlaybackUnavailable(); poll=nil;
        } else if (attempt>=60) {
            nativeCommand(@"pause:"); SGStandaloneCancel();
            SGAddonSetPlaybackStatus(@"같은 위치 복구를 확인하지 못해 일시정지를 유지합니다",NO); SGAddonSetPlaybackUnavailable(); poll=nil;
        } else later(.05,^{ if (poll) poll(attempt+1); });
    };
    poll(0);
}
@end

void SGStandaloneCancel(void) {
    NSCAssert(NSThread.isMainThread,@"standalone transport runs on main");
    atomic_fetch_add(&sg_transportGeneration,1);
    atomic_store(&sg_owned,false); atomic_store(&sg_busy,false);
    SGStandaloneSession *session=sg_session; sg_session=nil;
    [session close];
    @synchronized(snapshotLock()) { sg_clock=nil; sg_info=nil; }
}
void SGStandaloneRecover(NSString *reason) {
    dispatch_block_t f=^{ [sg_session recover:reason]; };
    if (NSThread.isMainThread) f(); else dispatch_async(dispatch_get_main_queue(),f);
}
void SGStandaloneStart(NSString *path, NSString *track, BOOL localPauseLease, void (^completion)(BOOL)) {
    if (!SGStandaloneEligible() || (!SGPlayerMusicOutput() && !localPauseLease) || ![track isEqual:uri(nativeState())]) { completion(NO); return; }
    SGStandaloneCancel(); sg_armedURI=nil; ++sg_intent;
    SGStandaloneSession *session=[SGStandaloneSession new]; sg_session=session;
    session.path=path; session.uri=track; session.uid=uid(nativeState()); session.wanted=YES;
    session.duration=[nativeState() duration]; session.position=SGStandaloneNativePosition(nativeState());
    session.completion=completion; session.decoder=dispatch_queue_create("spotifyglass.addon.decode",DISPATCH_QUEUE_SERIAL);
    atomic_store(&sg_busy,true);
    // The transport owns a pause lease only until another user command or source replaces it.
    nativeCommand(@"pause:");
    __block void (^wait)(unsigned);
    wait=^(unsigned attempt) {
        if (!current(session)) { wait=nil; return; }
        if (SGStandaloneNativePaused(nativeState())) {
            session.position=session.hasPendingSeek ? session.pendingSeek : SGStandaloneNativePosition(nativeState());
            NSDictionary *info=SGAddonMediaInfo();
            if ([info[@"duration"] doubleValue]>0) session.duration=[info[@"duration"] doubleValue];
            @synchronized(snapshotLock()) { sg_info=info; }
            atomic_store(&sg_owned,true);
            __weak SGStandaloneSession *weak=session;
            session.timer=[NSTimer timerWithTimeInterval:.05 repeats:YES block:^(NSTimer *timer){ [weak tick]; }];
            [NSRunLoop.mainRunLoop addTimer:session.timer forMode:NSRunLoopCommonModes];
            [session openAt:session.position]; wait=nil;
            later(4,^{ if (current(session) && !session.started && !session.recovering) [session recover:@"자체 엔진 준비 시간 초과"]; });
        } else if (attempt>=30) { SGStandaloneCancel(); SGAddonSetPlaybackStatus(@"Spotify 일시정지를 확인하지 못해 기본 스트림을 유지합니다",NO); SGAddonSetPlaybackUnavailable(); wait=nil; }
        else later(.05,^{ if (wait) wait(attempt+1); });
    };
    wait(0);
}
BOOL SGStandalonePause(BOOL paused) {
    if (sg_internal) return NO;
    BOOL handled=atomic_load(&sg_busy);
    if (!handled) {
        if (NSThread.isMainThread) { sg_armedURI=nil; ++sg_intent; }
        else dispatch_async(dispatch_get_main_queue(), ^{ sg_armedURI=nil; ++sg_intent; });
        return NO;
    }
    uint64_t generation=atomic_load(&sg_transportGeneration);
    dispatch_block_t f=^{
        if (generation!=atomic_load(&sg_transportGeneration)) return;
        sg_armedURI=nil; ++sg_intent;
        SGStandaloneSession *s=sg_session; if (!s) return;
        s.wanted=!paused;
        if (!atomic_load(&sg_owned)) return; // the native pause acknowledgement still owns preparation
        if (paused) [s.node pause]; else if (!s.interrupted && s.started) [s.node play];
        if (s.recovering && paused) { SGStandaloneCancel(); nativeCommand(@"pause:"); }
        else [s tick];
    };
    if (NSThread.isMainThread) f(); else dispatch_async(dispatch_get_main_queue(),f);
    return YES;
}
BOOL SGStandaloneSeek(double seconds, long long relative) {
    if (sg_internal || !atomic_load(&sg_busy)) return NO;
    uint64_t generation=atomic_load(&sg_transportGeneration);
    dispatch_block_t f=^{
        if (generation!=atomic_load(&sg_transportGeneration)) return;
        SGStandaloneSession *s=sg_session; if (!s || !isfinite(seconds)) return;
        double target=relative==2 ? s.position+seconds : relative==1 ? s.duration+seconds : seconds;
        target=MAX(0,MIN(target,MAX(0,s.duration-.01)));
        if (!atomic_load(&sg_owned)) { s.pendingSeek=target; s.hasPendingSeek=YES; return; }
        if (s.recovering) { s.recovering=NO; atomic_fetch_add(&s->decodeGeneration,1); }
        [s openAt:target];
    };
    if (NSThread.isMainThread) f(); else dispatch_async(dispatch_get_main_queue(),f);
    return YES;
}
void SGStandaloneObserveNativeState(id state) {
    if (!NSThread.isMainThread) return;
    if (sg_session && (!current(sg_session) || (sg_session.started && !sg_session.recovering && !SGStandaloneNativePaused(nativeState())))) SGStandaloneCancel();
}
void SGStandaloneWillSkip(NSString *track) {
    if (sg_internal) return;
    BOOL local=SGStandaloneActive() || SGPlayerMusicOutput()!=NULL;
    SGStandaloneCancel(); sg_armedURI=local && SGStandaloneEligible() && SGAddonHasPrepared(track) ? [track copy] : nil; ++sg_intent;
}
void SGStandaloneDidSkip(void) {
    if (!sg_armedURI) return;
    nativeCommand(@"pause:");
    uint64_t intent=sg_intent;
    later(3,^{
        if (intent!=sg_intent || !sg_armedURI) return;
        sg_armedURI=nil; ++sg_intent;
        if (!atomic_load(&sg_busy) && SGStandaloneNativePaused(nativeState())) nativeCommand(@"resume:");
    });
}
BOOL SGStandaloneTakeStartIntent(NSString *track) {
    BOOL expected=[sg_armedURI isEqual:track];
    // Retain the bounded pause lease until Start, a user command, or its timeout.
    return expected;
}

__attribute__((constructor)) static void standaloneNotifications(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
        [center addObserverForName:AVAudioEngineConfigurationChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SGStandaloneSession *s=sg_session;
                if (s && note.object==s.engine && s.started && !s.engine.isRunning && !s.recovering) [s openAt:s.position];
            });
        }];
        [center addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                SGStandaloneSession *s=sg_session; if (!s) return;
                BOOL began=[note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]==AVAudioSessionInterruptionTypeBegan;
                s.interrupted=began;
                if (began) [s.node pause];
                else if (s.wanted && ([note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue]&AVAudioSessionInterruptionOptionShouldResume)) [s openAt:s.position];
                else s.wanted=NO;
                [s publish];
            });
        }];
        [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSUInteger reason=[note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
            if (reason!=AVAudioSessionRouteChangeReasonOldDeviceUnavailable && reason!=AVAudioSessionRouteChangeReasonNewDeviceAvailable) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                SGStandaloneSession *s=sg_session; if (!s || s.recovering) return;
                if (reason==AVAudioSessionRouteChangeReasonOldDeviceUnavailable) s.wanted=NO;
                [s.engine stop]; [s openAt:s.position];
            });
        }];
    });
}
