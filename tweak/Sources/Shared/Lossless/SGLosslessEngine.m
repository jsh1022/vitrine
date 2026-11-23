// The anchor comes from the sound itself: a few seconds of Spotify's own output are matched against the file by
// cross-correlation, so Spotify's position reports (1.2 s off after a false stall at 1.5x) only narrow the search.
//
// The first search decodes only the hint's neighborhood at 1/16 of the rate, then refines at full rate.
// Only a failed local search expands (a complete file can fall back to a whole-file search). Playback reads from a ring that a worker fills ahead of
// where Spotify plays; a block the ring does not hold yet keeps Spotify's sound.
#import "SGLossless.h"
#import "SGWiredOutput.h"
#import "SGSourceFileFormat.h"
#import "Shared/AudioSources/SGAddons.h"
#import "Shared/AudioSources/SGProgressiveFLAC.h"
#import "Core/SGCore.h"
#import "Shared/Player/SpeedPitch.h"
#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>
#import <mach/mach_time.h>
#import <sys/stat.h>

enum { kIdle, kArmed, kFull };
enum { kCoarse = 16 };                      // decimation for the coarse search
enum { kRing = 1 << 19 };                   // frames the ring holds, about 12 s at 44.1 kHz
enum { kChunk = 8192 };                     // frames per read
static const double kAnchorSeconds = 3, kCheckSeconds = 1, kHintWindow = 8;
static const float kMinMatch = 0.8f;        // normalized correlation below this is another recording or master

#pragma mark - capture (original Spotify PCM only, before replacement)

enum { kMaxCaptureRate = 192000, kHistoryFrames = 1 << 20 };
static float *sg_cap;
static uint32_t sg_capLength;
static _Atomic uint32_t sg_capFill;
static _Atomic int sg_capState;
static atomic_uint sg_captureReaders;
static atomic_flag sg_captureWriter = ATOMIC_FLAG_INIT;
static uint64_t sg_capStart, sg_capEpoch, sg_capNext, sg_capHost;
static AudioUnit sg_capUnit;
static double sg_capRate, sg_captureSeconds, sg_capReusedSeconds;
// Float bit patterns are atomic: a worker never races ordinary sample storage.
static atomic_uint sg_history[kHistoryFrames];
static atomic_uint_fast64_t sg_historySequence, sg_historyRun, sg_historyEpoch, sg_historyEnd, sg_historyHeld, sg_historyHost;
static _Atomic uintptr_t sg_historyUnit;
static _Atomic double sg_historyRate;
static atomic_flag sg_historyWriter = ATOMIC_FLAG_INIT;
static double sg_tickSeconds;

static void remember(AudioUnit output, uint64_t epoch, uint64_t start, double rate, UInt32 frames, AudioBufferList *data) {
    if (!frames || rate<=0 || rate>kMaxCaptureRate || frames>kHistoryFrames ||
        atomic_flag_test_and_set_explicit(&sg_historyWriter,memory_order_acquire)) return;
    atomic_fetch_add_explicit(&sg_historySequence,1,memory_order_acq_rel);
    uint64_t held=atomic_load_explicit(&sg_historyHeld,memory_order_relaxed);
    if (atomic_load(&sg_historyEpoch)!=epoch || atomic_load(&sg_historyUnit)!=(uintptr_t)output ||
        atomic_load(&sg_historyRate)!=rate || atomic_load(&sg_historyEnd)!=start) {
        held=0; atomic_fetch_add(&sg_historyRun,1);
    }
    const float *left=data->mBuffers[0].mData,*right=data->mBuffers[1].mData;
    for (UInt32 i=0;i<frames;++i) {
        float mono=.5f*(left[i]+right[i]); uint32_t bits; memcpy(&bits,&mono,sizeof bits);
        atomic_store_explicit(&sg_history[(start+i)%kHistoryFrames],bits,memory_order_relaxed);
    }
    atomic_store(&sg_historyEpoch,epoch); atomic_store(&sg_historyUnit,(uintptr_t)output);
    atomic_store(&sg_historyRate,rate); atomic_store(&sg_historyEnd,start+frames);
    atomic_store(&sg_historyHeld,MIN((uint64_t)kHistoryFrames,held+frames));
    atomic_store(&sg_historyHost,mach_absolute_time());
    atomic_fetch_add_explicit(&sg_historySequence,1,memory_order_release);
    atomic_flag_clear_explicit(&sg_historyWriter,memory_order_release);
}
static void capture(AudioUnit output, uint64_t epoch, double sourceFrame, double rate, UInt32 frames, AudioBufferList *data) {
    remember(output,epoch,(uint64_t)sourceFrame,rate,frames,data);
    atomic_fetch_add(&sg_captureReaders,1);
    if (atomic_load(&sg_capState)!=kArmed || rate<=0 || rate>kMaxCaptureRate ||
        atomic_flag_test_and_set_explicit(&sg_captureWriter,memory_order_acquire)) {
        atomic_fetch_sub(&sg_captureReaders,1); return;
    }
    const float *l=data->mBuffers[0].mData,*r=data->mBuffers[1].mData;
    uint32_t fill=atomic_load(&sg_capFill);
    if (fill && ((uint64_t)sourceFrame!=sg_capNext || epoch!=sg_capEpoch || output!=sg_capUnit || rate!=sg_capRate)) fill=0;
    if (!fill) {
        sg_capStart=(uint64_t)sourceFrame; sg_capEpoch=epoch; sg_capUnit=output; sg_capRate=rate; sg_capHost=mach_absolute_time();
        sg_capLength=(uint32_t)llround(sg_captureSeconds*rate);
        sg_capReusedSeconds=0;
    }
    UInt32 n=MIN(frames,sg_capLength-fill);
    for (UInt32 i=0;i<n;++i) sg_cap[fill+i]=.5f*(l[i]+r[i]);
    sg_capNext=(uint64_t)sourceFrame+n;
    atomic_store(&sg_capFill,fill+n);
    if (fill+n==sg_capLength) atomic_store(&sg_capState,kFull);
    atomic_flag_clear_explicit(&sg_captureWriter,memory_order_release);
    atomic_fetch_sub(&sg_captureReaders,1);
}
static void idleCapture(void) {
    atomic_store(&sg_capState,kIdle);
    while (atomic_load(&sg_captureReaders)) usleep(100);
}
// A partial history seeds the capture; only the still-missing samples are collected.
static BOOL recentCapture(double seconds) {
    for (unsigned attempt=0;attempt<4;++attempt) {
        uint64_t sequence=atomic_load_explicit(&sg_historySequence,memory_order_acquire);
        if (sequence&1) continue;
        uint64_t epoch=atomic_load(&sg_historyEpoch),end=atomic_load(&sg_historyEnd),held=atomic_load(&sg_historyHeld);
        uint64_t run=atomic_load(&sg_historyRun),host=atomic_load(&sg_historyHost);
        double rate=atomic_load(&sg_historyRate); AudioUnit unit=(AudioUnit)atomic_load(&sg_historyUnit);
        if (sequence!=atomic_load_explicit(&sg_historySequence,memory_order_acquire)) continue;
        if (!unit || epoch!=SGPlayerSourceEpoch() || !host || !held || rate<=0 || rate>kMaxCaptureRate ||
            (mach_absolute_time()-host)*sg_tickSeconds>.25) return NO;
        uint32_t needed=(uint32_t)llround(seconds*rate),count=(uint32_t)MIN(held,(uint64_t)needed);
        uint64_t start=end-count;
        for (uint32_t i=0;i<count;++i) {
            uint32_t bits=atomic_load_explicit(&sg_history[(start+i)%kHistoryFrames],memory_order_relaxed);
            memcpy(sg_cap+i,&bits,sizeof bits);
        }
        sequence=atomic_load_explicit(&sg_historySequence,memory_order_acquire);
        uint64_t latest=atomic_load(&sg_historyEnd);
        if ((sequence&1) || (count<needed && latest!=end) || run!=atomic_load(&sg_historyRun) || epoch!=SGPlayerSourceEpoch() ||
            latest<end || latest-start>kHistoryFrames || sequence!=atomic_load_explicit(&sg_historySequence,memory_order_acquire)) continue;
        sg_capStart=start; sg_capNext=end;
        sg_capHost=host-(uint64_t)(((double)count/rate)/sg_tickSeconds);
        sg_capEpoch=epoch; sg_capUnit=unit; sg_capRate=rate; sg_capLength=needed;
        sg_capReusedSeconds=(double)count/rate;
        atomic_store(&sg_capFill,count);
        atomic_store(&sg_capState,count==needed ? kFull : kArmed);
        return YES;
    }
    return NO;
}

#pragma mark - the ring (static, never freed: a render call never reads freed memory)

static float sg_ringL[kRing], sg_ringR[kRing];
// File frames [start, end) are in the ring, frame f at f % kRing. The writer moves both forward only.
static _Atomic uint64_t sg_ringStart, sg_ringEnd;
// Where the render thread reads, so the writer never overwrites it.
static _Atomic uint64_t sg_readAt;

static bool ringRead(uint64_t at, UInt32 frames, float *l, float *r) {
    atomic_store_explicit(&sg_readAt, at, memory_order_relaxed);
    uint64_t start = atomic_load(&sg_ringStart), end = atomic_load(&sg_ringEnd);
    if (at < start || at + frames > end || frames > kRing) return false;
    uint64_t i = at % kRing;
    UInt32 first = (UInt32)MIN((uint64_t)frames, kRing - i);
    memcpy(l, sg_ringL + i, first * sizeof(float));
    memcpy(r, sg_ringR + i, first * sizeof(float));
    memcpy(l + first, sg_ringL, (frames - first) * sizeof(float));
    memcpy(r + first, sg_ringR, (frames - first) * sizeof(float));
    return true;
}

#pragma mark - what plays (set off render only while no reader is admitted)

static _Atomic uint64_t sg_generation; // also revokes blocked growing-file reads
static atomic_bool sg_live;
static atomic_uint sg_readers;
static uint64_t sg_playEpoch, sg_playSource, sg_playAsset;
static AudioUnit sg_playUnit;
static double sg_playRate;
static atomic_uint_fast64_t sg_playGeneration;
static _Atomic uint32_t sg_gainBits;
static _Atomic uint64_t sg_replaced;
static _Atomic uint64_t sg_renderedAt;
static NSDictionary *sg_sourceInfo;

static void selector(AudioUnit output, uint64_t epoch, double sourceFrame, double rate, UInt32 frames, AudioBufferList *data) {
    if (data->mNumberBuffers != 2 || !data->mBuffers[0].mData || !data->mBuffers[1].mData
        || data->mBuffers[0].mDataByteSize < frames * sizeof(float) || data->mBuffers[1].mDataByteSize < frames * sizeof(float)) return;
    capture(output, epoch, sourceFrame, rate, frames, data);
    atomic_fetch_add(&sg_readers, 1);
    if (atomic_load(&sg_live) && epoch == sg_playEpoch && epoch == SGPlayerSourceEpoch() && output == sg_playUnit
        && rate == sg_playRate && atomic_load(&sg_playGeneration)==atomic_load(&sg_generation) && sourceFrame >= sg_playSource) {
        uint64_t at = sg_playAsset + ((uint64_t)sourceFrame - sg_playSource);
        float *l = data->mBuffers[0].mData, *r = data->mBuffers[1].mData;
        if (ringRead(at, frames, l, r)) {
            uint32_t bits = atomic_load(&sg_gainBits);
            float gain;
            memcpy(&gain, &bits, sizeof gain);
            if (gain != 1) {
                vDSP_vsmul(l, 1, &gain, l, 1, frames);
                vDSP_vsmul(r, 1, &gain, r, 1, frames);
            }
            atomic_fetch_add_explicit(&sg_replaced, frames, memory_order_relaxed);
            atomic_store_explicit(&sg_renderedAt, mach_absolute_time(), memory_order_relaxed);
        }
    }
    atomic_fetch_sub(&sg_readers, 1);
}

// Off render: no reader is inside the play fields after this returns.
static void quiesce(void) {
    atomic_store(&sg_live, false);
    while (atomic_load(&sg_readers)) usleep(100);
}

#pragma mark - the file


typedef struct {
    BOOL valid, progressive;
    uint64_t device, inode, size;
    int64_t seconds, nanos;
    uintptr_t rendition;
} SGFileIdentity;
static SGFileIdentity fileIdentity(NSString *path) {
    struct stat info;
    if (stat(path.fileSystemRepresentation,&info)) return (SGFileIdentity){0};
    NSDictionary *progressive=SGProgressiveFLACInfo(path);
    return (SGFileIdentity){YES,progressive!=nil,(uint64_t)info.st_dev,(uint64_t)info.st_ino,
        (uint64_t)info.st_size,info.st_mtimespec.tv_sec,info.st_mtimespec.tv_nsec,(uintptr_t)(__bridge void *)progressive};
}
static BOOL sameFile(SGFileIdentity a, SGFileIdentity b) {
    return a.valid && b.valid && a.device==b.device && a.inode==b.inode && a.progressive==b.progressive &&
        (a.progressive ? a.rendition==b.rendition : (a.size==b.size && a.seconds==b.seconds && a.nanos==b.nanos));
}
typedef struct {
    ExtAudioFileRef file;
    CFTypeRef owner;
    double fileRate, rate;
    uint64_t frames;                        // at the client rate
    uint64_t epoch, generation;
    SGFileIdentity identity;
    BOOL needsSeek;
} Reader;

static void closeReader(Reader *reader) {
    if (reader->file) ExtAudioFileDispose(reader->file);
    if (reader->owner) CFRelease(reader->owner);
    *reader = (Reader){0};
}

static BOOL openReader(Reader *reader, NSString *path, double rate, NSString **error) {
    closeReader(reader);
    SGFileIdentity identity=fileIdentity(path);
    ExtAudioFileRef file=NULL; CFTypeRef owner=NULL;
    BOOL growing=SGProgressiveFLACRegistered(path);
    uint64_t epoch=SGPlayerSourceEpoch(), generation=atomic_load(&sg_generation);
    BOOL opened=growing ? SGProgressiveFLACOpen(path,&file,&owner,^BOOL { return epoch!=SGPlayerSourceEpoch() || generation!=atomic_load(&sg_generation); }) : !ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &file);
    if (!opened) { *error = @"the file does not open"; return NO; }
    AudioStreamBasicDescription source = {0};
    UInt32 size = sizeof source;
    SInt64 frames = 0;
    OSStatus status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source);
    size = sizeof frames;
    if (!status) status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames);
    BOOL lossless = SGSourceFileSupported(file, source);
    if (rate<=0) rate=source.mSampleRate;
    AudioStreamBasicDescription client = {rate, kAudioFormatLinearPCM,
        kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, 4, 1, 4, 2, 32, 0};
    if (!status && lossless && source.mChannelsPerFrame == 2 && frames > 0)
        status = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client);
    if (status || !lossless || source.mChannelsPerFrame != 2 || frames <= 0 || !sameFile(identity,fileIdentity(path))) {
        ExtAudioFileDispose(file);
        if (owner) CFRelease(owner);
        *error = @"not supported stereo FLAC, ALAC or WAV/AIFF PCM";
        return NO;
    }
    *reader = (Reader){file, owner, source.mSampleRate, rate, (uint64_t)floor(frames * rate / source.mSampleRate), epoch, generation, identity, NO};
    return YES;
}

// Immutable stereo PCM prepared before a wired rate transition. Queue-owned; never read on render.
@interface SGOutputPCM : NSObject {
@public
    float *left, *right;
    uint64_t from, count;
    double rate;
    SGFileIdentity identity;
}
@property(nonatomic,copy) NSString *path;
@end
@implementation SGOutputPCM
- (void)dealloc { free(left); free(right); }
@end
static SGOutputPCM *sg_outputPCM;
static uint64_t sg_outputPreparedFrames;
static Reader sg_reader;
static UInt32 preparedRead(Reader *reader, uint64_t at, UInt32 count, float *l, float *r) {
    if (reader!=&sg_reader) return 0;
    SGOutputPCM *pcm=sg_outputPCM;
    if (!pcm || reader->rate!=pcm->rate || !sameFile(reader->identity,pcm->identity) ||
        at<pcm->from || at-pcm->from>pcm->count || count>pcm->count-(at-pcm->from)) return 0;
    memcpy(l,pcm->left+at-pcm->from,count*sizeof(float));
    memcpy(r,pcm->right+at-pcm->from,count*sizeof(float));
    sg_outputPreparedFrames+=count;
    return count;
}
// Up to `count` frames from file frame `at` into l and r; the frames read (0 at the end).
static UInt32 readAt(Reader *reader, uint64_t at, UInt32 count, float *l, float *r, BOOL seek) {
    if (preparedRead(reader,at,count,l,r)) {
        reader->needsSeek=YES;
        return count;
    }
    if ((seek || reader->needsSeek) && ExtAudioFileSeek(reader->file, (SInt64)llround(at * reader->fileRate / reader->rate))) return 0;
    reader->needsSeek=NO;
    struct { AudioBufferList list; AudioBuffer second; } buffers = {{2, {{1, count * 4, l}}}, {1, count * 4, r}};
    UInt32 frames = count;
    if (ExtAudioFileRead(reader->file, &frames, &buffers.list)) return 0;
    return frames;
}

// Mono of file frames [from, from + count), silence outside the file. The caller frees it.
static float *readMono(Reader *reader, int64_t from, uint32_t count) {
    float *mono = calloc(count, sizeof(float)), *l = malloc(kChunk * sizeof(float)), *r = malloc(kChunk * sizeof(float));
    if (!mono || !l || !r) { free(mono); free(l); free(r); return NULL; }
    int64_t at = MAX(from, 0);
    BOOL seek = YES;
    while (at < from + count && (uint64_t)at < reader->frames) {
        UInt32 want = (UInt32)MIN((int64_t)kChunk, from + count - at);
        UInt32 got = readAt(reader, at, want, l, r, seek);
        if (!got) break;
        seek = NO;
        for (UInt32 i = 0; i < got; i++) mono[at - from + i] = 0.5f * (l[i] + r[i]);
        at += got;
    }
    free(l); free(r);
    if (at<from+count && (uint64_t)at<reader->frames) { free(mono); return NULL; }
    return mono;
}

#pragma mark - the anchor's queue owns these

static dispatch_queue_t sg_queue;
static void (^sg_anchorProgress)(SGLosslessPreparationPhase);
static NSString *sg_path;
// sg_reader serves searches and checks; its declaration precedes preparedRead().
static float *sg_coarse;                    // the file's mono at 1/kCoarse of the rate
static uint64_t sg_coarseCount, sg_coarseStart;
static uint64_t sg_decodedFrames;
static BOOL sg_predecoded;
static _Atomic uint64_t sg_anchorEpoch;
static dispatch_queue_t queue(void);
static atomic_uint_fast64_t sg_proofRevision;
static NSString *sg_proofTrack, *sg_proofPath;
static SGFileIdentity sg_proofFile;
static uint64_t sg_proofAtRevision;
static double sg_proofOffset, sg_proofRate;
static float sg_proofGain;
static NSString *sg_requestTrack;
static uint64_t sg_requestHost, sg_requestRevision;
static atomic_uint sg_writers;              // writers still running

static void drop(void) {
    closeReader(&sg_reader);
    free(sg_coarse);
    sg_coarse = NULL;
    sg_coarseCount = 0;
    sg_path = nil;
    @synchronized (NSProcessInfo.processInfo) { sg_sourceInfo = nil; }
}

static NSDictionary *readerInfo(Reader *reader, NSString *path) {
    AudioStreamBasicDescription source={0}; UInt32 size=sizeof(source);
    ExtAudioFileGetProperty(reader->file,kExtAudioFileProperty_FileDataFormat,&size,&source);
    UInt32 bits=source.mBitsPerChannel;
    if (!bits && source.mFormatID==kAudioFormatAppleLossless && source.mFormatFlags>=1 && source.mFormatFlags<=4) {
        const UInt32 depths[]={0,16,20,24,32}; bits=depths[source.mFormatFlags];
    }
    if (!bits) bits=[(SGProgressiveFLACInfo(path) ?: SGMeasureLosslessFile(path,0))[@"bits"] unsignedIntValue];
    BOOL growing=SGProgressiveFLACRegistered(path) && !SGProgressiveFLACComplete(path);
    return @{@"codec":SGSourceFileCodec(source),@"rate":@(source.mSampleRate),@"bits":@(bits),
        @"channels":@(source.mChannelsPerFrame),@"clientRate":@(reader->rate),
        @"averageKbps":@(growing ? 0 : [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL].fileSize*8.0/(reader->frames/reader->rate)/1000)};
}
// Read only the requested window. Decimation is aligned to absolute file frames.
static float *coarseWindow(Reader *reader, uint64_t from, uint64_t to, uint64_t *count,
                          BOOL (^cancelled)(void), NSString **error) {
    *count=(to-from)/kCoarse;
    float *coarse=calloc(*count+1,sizeof(float)),*left=malloc(kChunk*sizeof(float)),*right=malloc(kChunk*sizeof(float));
    if (!coarse || !left || !right) { free(coarse); free(left); free(right); *error=@"decode allocation failed"; return NULL; }
    uint64_t at=from; float sum=0; BOOL seek=YES;
    while (at<to && !cancelled()) {
        UInt32 got=readAt(reader,at,(UInt32)MIN((uint64_t)kChunk,to-at),left,right,seek);
        if (!got) break;
        seek=NO;
        for (UInt32 i=0;i<got;++i) {
            uint64_t frame=at+i;
            sum+=.5f*(left[i]+right[i]);
            if (frame%kCoarse==kCoarse-1) {
                uint64_t index=(frame-from)/kCoarse;
                if (index<*count) coarse[index]=sum/kCoarse;
                sum=0;
            }
        }
        at+=got;
    }
    free(left); free(right);
    if (at<to || cancelled()) { free(coarse); *error=cancelled() ? @"source changed while decoding" : @"the file ended early"; return NULL; }
    return coarse;
}

@interface SGWarmLossless : NSObject {
@public
    Reader reader;
    float *coarse;
    uint64_t count;
}
@property(nonatomic,copy) NSString *path;
@property(nonatomic,copy) NSDictionary *info;
@end
@implementation SGWarmLossless
- (void)dealloc { closeReader(&reader); free(coarse); }
@end
static NSObject *warmLock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once,^{lock=[NSObject new];}); return lock;
}
static NSMutableArray<SGWarmLossless *> *sg_warm;
static NSString *sg_warmingPath;
static double sg_warmingRate;
static atomic_uint_fast64_t sg_warmGeneration;
void SGLosslessPrepareNext(NSString *path, double rate) {
    static dispatch_queue_t worker; static dispatch_once_t once;
    dispatch_once(&once,^{worker=dispatch_queue_create("spotifyglass.lossless.predecode",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));});
    uint64_t generation;
    @synchronized(warmLock()) {
        if (!path.length) {
            atomic_fetch_add(&sg_warmGeneration,1); sg_warmingPath=nil;
            NSArray *released=[sg_warm copy]; [sg_warm removeAllObjects];
            dispatch_async(worker, ^{ (void)released.count; }); return;
        }
        if ([sg_warmingPath isEqual:path] && sg_warmingRate==rate) return;
        for (SGWarmLossless *item in sg_warm) if ([item.path isEqual:path] && item->reader.rate==rate) return;
        generation=atomic_fetch_add(&sg_warmGeneration,1)+1; sg_warmingPath=[path copy]; sg_warmingRate=rate;
    }
    dispatch_async(worker,^{
        BOOL (^cancelled)(void)=^BOOL { return generation!=atomic_load(&sg_warmGeneration); };
        SGWarmLossless *item=[SGWarmLossless new]; item.path=path;
        NSString *error=nil;
        // Only complete immutable files; partial prefixes remain under the download worker.
        if (!cancelled() && !SGProgressiveFLACRegistered(path) && openReader(&item->reader,path,rate,&error)) {
            uint64_t to=MIN(item->reader.frames,(uint64_t)ceil((2*kHintWindow+kAnchorSeconds)*item->reader.rate/kCoarse)*kCoarse);
            item->coarse=coarseWindow(&item->reader,0,to,&item->count,cancelled,&error);
            if (item->coarse && !cancelled()) item.info=readerInfo(&item->reader,path);
        }
        @synchronized(warmLock()) {
            if (cancelled()) return;
            sg_warmingPath=nil;
            if (!item->coarse) return;
            if (!sg_warm) sg_warm=[NSMutableArray array];
            [sg_warm addObject:item];
            // Keep the promoted current file while its successor starts warming. Bounded to two prefixes.
            while (sg_warm.count>2) [sg_warm removeObjectAtIndex:0];
        }
    });
}
BOOL SGLosslessPrepareOutputBuffer(NSString *path, double rate, double hint, uint64_t expectedEpoch) {
    if (!path.length || !isfinite(rate) || rate<44100 || rate>192000 || !isfinite(hint) || hint<0) return NO;
    __block BOOL ready=NO;
    dispatch_sync(queue(), ^{
        uint64_t revision=atomic_load(&sg_proofRevision), generation=atomic_load(&sg_generation);
        if (SGPlayerSourceEpoch()!=expectedEpoch) return;
        uint64_t from=(uint64_t)floor(MAX(0,hint-2)*rate/kCoarse)*kCoarse;
        uint64_t to=(uint64_t)ceil((hint+2+kAnchorSeconds)*rate/kCoarse)*kCoarse;
        SGFileIdentity identity=fileIdentity(path);
        SGOutputPCM *cached=sg_outputPCM;
        if (cached && [cached.path isEqual:path] && cached->rate==rate && sameFile(cached->identity,identity) &&
            cached->from<=from && cached->from+cached->count>=to) { ready=YES; return; }
        Reader reader={0}; NSString *error=nil;
        if (!openReader(&reader,path,rate,&error)) return;
        SGOutputPCM *pcm=[SGOutputPCM new]; pcm.path=path; pcm->rate=rate; pcm->identity=reader.identity;
        pcm->from=from; to=MIN(to,reader.frames); pcm->count=to>from ? to-from : 0;
        if (!pcm->count || pcm->count>(uint64_t)(8*rate)) { closeReader(&reader); return; }
        pcm->left=malloc(pcm->count*sizeof(float)); pcm->right=malloc(pcm->count*sizeof(float));
        uint64_t at=from;
        if (pcm->left && pcm->right) while (at<to && SGPlayerSourceEpoch()==expectedEpoch &&
            generation==atomic_load(&sg_generation) && revision==atomic_load(&sg_proofRevision)) {
            UInt32 got=readAt(&reader,at,(UInt32)MIN((uint64_t)kChunk,to-at),pcm->left+at-from,pcm->right+at-from,at==from);
            if (!got) break;
            at+=got;
        }
        closeReader(&reader);
        if (at==to && SGPlayerSourceEpoch()==expectedEpoch && generation==atomic_load(&sg_generation) &&
            revision==atomic_load(&sg_proofRevision) && sameFile(identity,fileIdentity(path))) {
            sg_outputPCM=pcm; ready=YES;
        }
    });
    return ready;
}
static BOOL takeWarm(NSString *path, double rate) {
    SGWarmLossless *selected=nil;
    @synchronized(warmLock()) {
        for (SGWarmLossless *item in [sg_warm copy]) {
            if ([item.path isEqual:path] && item->reader.rate==rate && sameFile(item->reader.identity,fileIdentity(path))) { selected=item; [sg_warm removeObject:item]; break; }
        }
    }
    if (!selected) return NO;
    drop();
    sg_reader=selected->reader; selected->reader=(Reader){0};
    sg_coarse=selected->coarse; selected->coarse=NULL; sg_coarseCount=selected->count; sg_coarseStart=0;
    sg_path=[path copy]; sg_predecoded=YES;
    @synchronized(NSProcessInfo.processInfo) { sg_sourceInfo=selected.info; }
    return YES;
}
static BOOL loadWindow(NSString *path, double rate, double fromSeconds, double toSeconds, NSString **error) {
    if (sg_anchorProgress) sg_anchorProgress(SGLosslessPhaseDecode);
    BOOL same=sg_reader.file && [sg_path isEqual:path] && sg_reader.rate==rate && sameFile(sg_reader.identity,fileIdentity(path));
    if (same && sg_reader.owner && (sg_reader.epoch!=SGPlayerSourceEpoch() || sg_reader.generation!=atomic_load(&sg_generation))) same=NO;
    if (!same && !takeWarm(path,rate)) {
        drop();
        if (!openReader(&sg_reader,path,rate,error)) return NO;
        sg_path=[path copy];
        NSDictionary *info=readerInfo(&sg_reader,path);
        @synchronized(NSProcessInfo.processInfo) { sg_sourceInfo=info; }
    }
    uint64_t from=(uint64_t)MAX(0,floor(fromSeconds*rate/kCoarse))*kCoarse;
    uint64_t to=toSeconds<0 ? sg_reader.frames : MIN(sg_reader.frames,(uint64_t)ceil(toSeconds*rate/kCoarse)*kCoarse);
    if (from>=to) { *error=@"Spotify plays past the end of the file"; return NO; }
    if (sg_coarse && sg_coarseStart*kCoarse<=from && (sg_coarseStart+sg_coarseCount)*kCoarse>=to-to%kCoarse) return YES;
    free(sg_coarse); sg_coarse=NULL; sg_coarseCount=0; sg_predecoded=NO;
    uint64_t epoch=SGPlayerSourceEpoch(),generation=atomic_load(&sg_generation);
    sg_coarse=coarseWindow(&sg_reader,from,to,&sg_coarseCount,^BOOL {
        return epoch!=SGPlayerSourceEpoch() || generation!=atomic_load(&sg_generation);
    },error);
    sg_coarseStart=from/kCoarse;
    if (!sg_coarse) { drop(); return NO; }
    sg_decodedFrames+=to-from;
    return YES;
}

static float dot(const float *a, const float *b, vDSP_Length n) {
    float d;
    vDSP_dotpr(a, 1, b, 1, &d, n);
    return d;
}

// Normalized correlation of `capture` against `window` (both n long), and the gain that maps the file onto it.
static float match(const float *capture, const float *window, vDSP_Length n, float *gain) {
    float cc = dot(capture, window, n), aa = dot(window, window, n), ss = dot(capture, capture, n);
    if (gain) *gain = aa > 0 ? cc / aa : 0;
    return aa > 0 && ss > 0 ? cc / sqrtf(aa * ss) : 0;
}

// The file frame within [from, to] whose following frames best match the capture, read at full rate.
static uint64_t refine(int64_t from, int64_t to, float *score, float *gain) {
    from = MAX(from, 0);
    to = MAX(from, MIN(to, (int64_t)sg_reader.frames - (int64_t)sg_capLength));
    uint32_t span = (uint32_t)(to - from) + sg_capLength;
    float *window = readMono(&sg_reader, from, span);
    uint64_t best = from;
    *score = -2;
    if (!window) { *score=0; return best; }
    for (int64_t lag = from; lag <= to; lag++) {
        float s = match(sg_cap, window + (lag - from), sg_capLength, NULL);
        if (s > *score) { *score = s; best = lag; }
    }
    match(sg_cap, window + (best - from), sg_capLength, gain);
    free(window);
    return best;
}

// Coarse search of file frames [from, to), then exact around the winner.
static uint64_t search(uint64_t from, uint64_t to, float *score, float *gain, float *gap) {
    uint64_t lo = MAX(from / kCoarse,sg_coarseStart), hi = MIN(to / kCoarse, sg_coarseStart+sg_coarseCount);
    vDSP_Length capN = sg_capLength / kCoarse;
    if (gap) *gap=0;
    if (hi <= lo || hi - lo <= capN) { *score = 0; return 0; }
    float *cap = malloc(capN * sizeof(float));
    float filter[kCoarse], one = 1.0f / kCoarse;
    vDSP_vfill(&one, filter, 1, kCoarse);
    vDSP_desamp(sg_cap, kCoarse, filter, cap, capN, kCoarse);
    const float *file = sg_coarse + (lo-sg_coarseStart);
    vDSP_Length fileN = hi - lo, lags = fileN - capN + 1;
    float *corr = malloc(lags * sizeof(float));
    vDSP_conv(file, 1, cap, 1, corr, 1, lags, capN);
    double running = 0;
    for (vDSP_Length i = 0; i < capN; i++) running += (double)file[i] * file[i];
    vDSP_Length coarse = 0;
    float capNorm=sqrtf(dot(cap,cap,capN));
    float best = -INFINITY;
    for (vDSP_Length i = 0; i < lags; i++) {
        float s = running > 1e-9 && capNorm>0 ? corr[i] / (sqrtf((float)running)*capNorm) : 0;
        corr[i]=s;
        if (s > best) { best = s; coarse = i; }
        if (i + capN < fileN) running += (double)file[i + capN] * file[i + capN] - (double)file[i] * file[i];
    }
    if (gap) {
        float second=-INFINITY;
        uint64_t separate=(uint64_t)ceil(sg_reader.rate*.05/kCoarse);
        for (vDSP_Length i=0;i<lags;++i) if ((i>coarse ? i-coarse : coarse-i)>=separate) second=MAX(second,corr[i]);
        *gap=isfinite(second) ? best-second : 0;
    }
    free(cap); free(corr);
    int64_t center = (int64_t)(lo + coarse) * kCoarse;
    return refine(center - 2 * kCoarse, center + 2 * kCoarse, score, gain);
}

// Collect the requested continuous source window; initial alignment requests three seconds.
static BOOL record(double seconds, NSString **error) {
    static float *storage;
    if (!storage) storage=malloc((size_t)(kAnchorSeconds*kMaxCaptureRate)*sizeof(float));
    if (!storage) { *error=@"capture allocation failed"; return NO; }
    idleCapture(); sg_cap=storage; sg_captureSeconds=MIN(seconds,kAnchorSeconds); sg_capReusedSeconds=0;
    atomic_store(&sg_capFill,0);
    if (!recentCapture(sg_captureSeconds)) atomic_store(&sg_capState,kArmed);
    for (int i=0;i<(int)(seconds*20)+60 && atomic_load(&sg_capState)!=kFull;++i) usleep(50000);
    if (atomic_load(&sg_capState)==kFull) {
        while (atomic_load(&sg_captureReaders)) usleep(100);
        return YES;
    }
    idleCapture(); *error=@"Spotify's sound did not run unbroken long enough"; return NO;
}

#pragma mark - the writer

// Fills the ring from where the render thread reads until the generation or the source epoch changes or the file ends.
// Past the epoch the selector never reads this ring again (the epoch only grows), so there is nothing left to fill.
static void fill(NSString *path, double rate, uint64_t from, uint64_t generation, uint64_t epoch) {
    Reader reader = {0};
    NSString *error;
    if (!openReader(&reader, path, rate, &error)) {
        SGLog(@"lossless: the writer could not open the file: %@", error);
        atomic_fetch_sub(&sg_writers, 1);
        return;
    }
    float *l = malloc(kChunk * sizeof(float)), *r = malloc(kChunk * sizeof(float));
    uint64_t end = from;
    BOOL seek = YES;
    while (atomic_load(&sg_generation) == generation && SGPlayerSourceEpoch() == epoch) {
        uint64_t reading = MAX(atomic_load_explicit(&sg_readAt, memory_order_relaxed), atomic_load(&sg_ringStart));
        if (reading > end + (uint64_t)rate) {
            // Spotify plays ahead of what the ring holds: start again where it plays.
            end = reading + (uint64_t)(rate / 4);
            atomic_store(&sg_ringStart, end);
            atomic_store(&sg_ringEnd, end);
            seek = YES;
        }
        if (end + kChunk > reading + kRing - kChunk) { usleep(20000); continue; }
        UInt32 got = readAt(&reader, end, kChunk, l, r, seek);
        if (!got) {
            if (end<reader.frames && SGProgressiveFLACRegistered(path) && atomic_load(&sg_generation)==generation && SGPlayerSourceEpoch()==epoch) {
                atomic_store(&sg_live,false); atomic_store(&sg_anchorEpoch,0);
            }
            break;
        }
        seek = NO;
        uint64_t i = end % kRing;
        UInt32 first = (UInt32)MIN((uint64_t)got, kRing - i);
        memcpy(sg_ringL + i, l, first * sizeof(float));
        memcpy(sg_ringR + i, r, first * sizeof(float));
        memcpy(sg_ringL, l + first, (got - first) * sizeof(float));
        memcpy(sg_ringR, r + first, (got - first) * sizeof(float));
        end += got;
        // Frames the writer passed out of the ring's reach are gone.
        if (end > kRing && atomic_load(&sg_ringStart) < end - kRing) atomic_store(&sg_ringStart, end - kRing);
        atomic_store(&sg_ringEnd, end);
    }
    free(l); free(r);
    closeReader(&reader);
    atomic_fetch_sub(&sg_writers, 1);
}

#pragma mark - anchor, check, stop

static void stopPlaying(void) {
    atomic_fetch_add(&sg_generation, 1);
    quiesce();
    // A writer of the last anchor still inside its loop would write into the ring the next one resets.
    while (atomic_load(&sg_writers)) usleep(1000);
    atomic_store(&sg_anchorEpoch, 0);
}

// Existing full-window proof is reusable only after an unambiguous fresh waveform
// confirms the proposed position. Position reports never activate the replacement alone.
static BOOL confirmReconnect(uint64_t lag, float score, float gain, float gap) {
    if (score<.98f || gap<.025f || !isfinite(gain) || sg_proofGain<=0 || fabsf(gain-sg_proofGain)>MAX(.0001f,fabsf(sg_proofGain)*.05f)) return NO;
    float *window=readMono(&sg_reader,(int64_t)lag,sg_capLength);
    if (!window) return NO;
    BOOL accepted=YES;
    uint32_t part=sg_capLength/4;
    for (unsigned i=0;i<4 && accepted;++i) {
        float level=0;
        float local=match(sg_cap+i*part,window+i*part,part,&level);
        accepted=local>=.96f && isfinite(level) && fabsf(level-gain)<=MAX(.0001f,fabsf(gain)*.05f);
    }
    free(window); return accepted;
}
static double reportAtCapture(double hint) {
    double elapsed=sg_capHost>=sg_requestHost ? (sg_capHost-sg_requestHost)*sg_tickSeconds : -(double)(sg_requestHost-sg_capHost)*sg_tickSeconds;
    return hint+elapsed;
}
static NSDictionary *anchor(NSString *path, double hint, NSString **error) {
    SGLosslessBeginCapture();
    stopPlaying();
    uint64_t workGeneration=atomic_load(&sg_generation);
    sg_decodedFrames=0; sg_predecoded=NO; sg_outputPreparedFrames=0;
    BOOL reused=NO;
    double rate=0;
    float score=0,gain=0;
    uint64_t lag=0;
    NSString *scope=@"hint";
    CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
    BOOL cached=sg_requestTrack.length && [sg_requestTrack isEqual:sg_proofTrack] && [path isEqual:sg_proofPath]
        && sg_proofAtRevision==sg_requestRevision && sg_requestRevision==atomic_load(&sg_proofRevision)
        && isfinite(hint) && hint>=0 && sg_requestHost && sameFile(sg_proofFile,fileIdentity(path));
    if (cached) {
        if (sg_anchorProgress) sg_anchorProgress(SGLosslessPhaseReconnect);
        NSString *failure=nil;
        if (record(kCheckSeconds,&failure) && sg_capEpoch==SGPlayerSourceEpoch() && sg_capRate==sg_proofRate &&
            workGeneration==atomic_load(&sg_generation) && sg_requestRevision==atomic_load(&sg_proofRevision)) {
            rate=sg_capRate;
            double proposed=reportAtCapture(hint)+sg_proofOffset;
            if (isfinite(proposed) && proposed>=0 && loadWindow(path,rate,MAX(0,proposed-1.5),proposed+1.5+kCheckSeconds,&failure)) {
                float gap=0;
                lag=search((uint64_t)(MAX(0,proposed-1.5)*rate),(uint64_t)((proposed+1.5+kCheckSeconds)*rate),&score,&gain,&gap);
                reused=confirmReconnect(lag,score,gain,gap);
            }
        }
    }
    if (!reused) {
        // A refused reconnect cannot leave an older proof available for a different recording/master.
        sg_proofTrack=nil;
        if (sg_anchorProgress) sg_anchorProgress(SGLosslessPhaseCapture);
        if (!record(kAnchorSeconds,error)) return nil;
        if (sg_capEpoch!=SGPlayerSourceEpoch() || workGeneration!=atomic_load(&sg_generation) || sg_requestRevision!=atomic_load(&sg_proofRevision)) {
            *error=@"the source changed before decoding"; return nil;
        }
        rate=sg_capRate;
        double captureHint=isfinite(hint) && hint>=0 ? MAX(0,reportAtCapture(hint)) : -1;
        double fromSeconds=captureHint>=0 ? MAX(0,captureHint-2) : 0;
        double toSeconds=captureHint>=0 ? captureHint+2+kAnchorSeconds : -1;
        if (!loadWindow(path,rate,fromSeconds,toSeconds,error)) return nil;
        if (sg_reader.frames<=sg_capLength) { *error=@"the file is shorter than the capture"; return nil; }
        uint64_t from=(uint64_t)(fromSeconds*rate),to=toSeconds<0 ? sg_reader.frames : (uint64_t)(toSeconds*rate);
        scope=captureHint>=0 ? @"near" : @"wide";
        if (sg_anchorProgress) sg_anchorProgress(SGLosslessPhaseMatch);
        lag=search(from,to,&score,&gain,NULL);
        if (score<kMinMatch && captureHint>=0 && sg_capEpoch==SGPlayerSourceEpoch()) {
            fromSeconds=MAX(0,captureHint-kHintWindow);
            toSeconds=captureHint+kHintWindow+kAnchorSeconds;
            if (!loadWindow(path,rate,fromSeconds,toSeconds,error)) return nil;
            from=(uint64_t)(fromSeconds*rate); to=(uint64_t)(toSeconds*rate);
            if (sg_anchorProgress) sg_anchorProgress(SGLosslessPhaseMatch);
            lag=search(from,to,&score,&gain,NULL); scope=@"hint";
        }
        if (score<kMinMatch && captureHint>=0 && sg_capEpoch==SGPlayerSourceEpoch()) {
            BOOL growing=SGProgressiveFLACRegistered(path) && !SGProgressiveFLACComplete(path);
            fromSeconds=growing ? MAX(0,captureHint-4*kHintWindow) : 0;
            toSeconds=growing ? captureHint+4*kHintWindow+kAnchorSeconds : -1;
            if (!loadWindow(path,rate,fromSeconds,toSeconds,error)) return nil;
            from=(uint64_t)(fromSeconds*rate); to=toSeconds<0 ? sg_reader.frames : (uint64_t)(toSeconds*rate);
            if (sg_anchorProgress) sg_anchorProgress(SGLosslessPhaseMatch);
            lag=search(from,to,&score,&gain,NULL); scope=@"wide";
        }
    }
    if (score<kMinMatch) { *error=[NSString stringWithFormat:@"no match (%.3f)",score]; return nil; }
    if (sg_capEpoch!=SGPlayerSourceEpoch() || workGeneration!=atomic_load(&sg_generation) || sg_requestRevision!=atomic_load(&sg_proofRevision) || !sameFile(sg_reader.identity,fileIdentity(path))) {
        *error=@"the source changed while matching"; return nil;
    }
    if (!reused && sg_requestTrack.length && score>=.98f && isfinite(hint) && hint>=0 && sg_requestHost) {
        sg_proofTrack=[sg_requestTrack copy]; sg_proofPath=[path copy]; sg_proofFile=sg_reader.identity;
        sg_proofAtRevision=sg_requestRevision; sg_proofRate=rate; sg_proofGain=gain;
        sg_proofOffset=(double)lag/rate-reportAtCapture(hint);
    }
    double took=CFAbsoluteTimeGetCurrent()-start;
    SGLog(@"lossless: %@ match %.4f at %.3f s, gain %.3f",reused ? @"reconnect" : @"full",score,(double)lag/rate,gain);
    float alignmentGain = gain;
    if (SGWiredOutputPreserveLevel()) gain = 1;
    uint32_t bits;
    memcpy(&bits, &gain, sizeof bits);
    atomic_store(&sg_gainBits, bits);
    @synchronized (NSProcessInfo.processInfo) {
        NSMutableDictionary *info = [sg_sourceInfo mutableCopy];
        info[@"gain"] = @(gain); info[@"alignmentGain"] = @(alignmentGain); sg_sourceInfo = info;
    }
    sg_playEpoch = sg_capEpoch;
    sg_playSource = sg_capStart;
    sg_playAsset = lag;
    sg_playUnit = sg_capUnit;
    sg_playRate = rate;
    // The writer starts where Spotify plays by now, so the ring is not filled with frames already gone.
    uint64_t now = lag + (sg_capNext - sg_capStart);
    atomic_store(&sg_ringStart, now);
    atomic_store(&sg_ringEnd, now);
    atomic_store(&sg_readAt, now);
    // Decode a short startup buffer before publishing the anchor. Unready frames never
    // interrupt Spotify. The writer starts after this prefix rather than decoding it twice.
    UInt32 startup=(UInt32)MIN((uint64_t)kChunk,sg_reader.frames>now ? sg_reader.frames-now : 0);
    float *startupL=malloc(kChunk*sizeof(float)), *startupR=malloc(kChunk*sizeof(float));
    UInt32 buffered=startup && startupL && startupR ? readAt(&sg_reader,now,startup,startupL,startupR,YES) : 0;
    if (buffered && workGeneration==atomic_load(&sg_generation) && sg_capEpoch==SGPlayerSourceEpoch()) {
        uint64_t slot=now%kRing; UInt32 first=(UInt32)MIN((uint64_t)buffered,kRing-slot);
        memcpy(sg_ringL+slot,startupL,first*sizeof(float)); memcpy(sg_ringR+slot,startupR,first*sizeof(float));
        memcpy(sg_ringL,startupL+first,(buffered-first)*sizeof(float)); memcpy(sg_ringR,startupR+first,(buffered-first)*sizeof(float));
        atomic_store(&sg_ringEnd,now+buffered);
    }
    free(startupL); free(startupR);
    if (!buffered) { *error=@"the startup playback buffer is not ready"; return nil; }
    if (workGeneration!=atomic_load(&sg_generation) || sg_capEpoch!=SGPlayerSourceEpoch() || !sameFile(sg_reader.identity,fileIdentity(path))) {
        *error=@"the source changed while preparing the playback buffer"; return nil;
    }
    uint64_t generation = workGeneration, epoch = sg_playEpoch;
    atomic_store(&sg_playGeneration,workGeneration);
    atomic_fetch_add(&sg_writers, 1);
    // Its own thread: it runs for the rest of the song, which would hold a shared queue's thread that long.
    NSThread *writer = [[NSThread alloc] initWithBlock:^{ fill(path, rate, now+buffered, generation, epoch); }];
    writer.qualityOfService = NSQualityOfServiceUserInitiated;
    writer.name = @"spotifyglass.lossless.writer";
    [writer start];
    atomic_store(&sg_anchorEpoch, sg_capEpoch);
    atomic_store(&sg_live, true);
    return @{@"rate" : @(rate), @"source_frame":@(sg_capStart), @"file_frame" : @(lag), @"file_seconds" : @(lag / rate), @"match" : @(score),
             @"gain" : @(gain), @"search_s" : @(took), @"capture_reused_s":@(sg_capReusedSeconds),
             @"decoded_frames":@(sg_decodedFrames), @"predecoded":@(sg_predecoded), @"search_scope":scope,
             @"reused_alignment":@(reused), @"validation_s":@(reused ? kCheckSeconds : kAnchorSeconds),
             @"startup_frames":@(buffered), @"output_prepared_frames":@(sg_outputPreparedFrames)};
}

static NSDictionary *check(NSString **error) {
    uint64_t epoch = atomic_load(&sg_anchorEpoch);
    if (!sg_coarse || !epoch) { *error = @"nothing anchored"; return nil; }
    NSMutableDictionary *result = [@{@"replaced_s" : @(atomic_load(&sg_replaced) / sg_reader.rate),
                                     @"epoch_current" : @(epoch == SGPlayerSourceEpoch())} mutableCopy];
    if (!record(kCheckSeconds, error)) return nil;
    if (sg_capUnit != sg_playUnit || sg_capEpoch != epoch) {
        result[@"note"] = @"the source changed since the anchor: Spotify plays its own sound again";
        return result;
    }
    int64_t expected = (int64_t)sg_playAsset + (int64_t)(sg_capStart - sg_playSource);
    if (expected<0 || (uint64_t)expected + sg_capLength > sg_reader.frames) {
        result[@"note"] = @"past the end of the file";
        return result;
    }
    float score;
    uint64_t found = refine(expected - 2048, expected + 2048, &score, NULL);
    result[@"offset_frames"] = @((int64_t)found - expected);
    result[@"match"] = @(score);
    result[@"file_seconds"] = @(expected / sg_reader.rate);
    return result;
}

static dispatch_queue_t queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sg_queue = dispatch_queue_create("spotifyglass.lossless", DISPATCH_QUEUE_SERIAL); });
    return sg_queue;
}

void SGLosslessBeginCapture(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info_data_t base; mach_timebase_info(&base);
        sg_tickSeconds=(double)base.numer/base.denom/1e9;
        SGPlayerSetSourceSelector(selector);
    });
}

NSDictionary *SGLosslessAnchorForTrack(NSString *path, NSString *trackIdentity, double hintSeconds,
    uint64_t hintHostTime, void (^progress)(SGLosslessPreparationPhase), NSString **error) {
    __block NSDictionary *result;
    __block NSString *failure;
    uint64_t revision=atomic_load(&sg_proofRevision);
    dispatch_sync(queue(), ^{
        sg_anchorProgress=[progress copy]; sg_requestTrack=[trackIdentity copy];
        sg_requestHost=hintHostTime; sg_requestRevision=revision;
        @try { NSString *e=nil; result=anchor(path,hintSeconds,&e); failure=e; }
        @finally { sg_anchorProgress=nil; sg_requestTrack=nil; }
    });
    *error=failure; return result;
}
NSDictionary *SGLosslessAnchorWithProgress(NSString *path, double hintSeconds,
    void (^progress)(SGLosslessPreparationPhase), NSString **error) {
    return SGLosslessAnchorForTrack(path,@"",hintSeconds,mach_absolute_time(),progress,error);
}
NSDictionary *SGLosslessAnchor(NSString *path, double hintSeconds, NSString **error) {
    return SGLosslessAnchorWithProgress(path,hintSeconds,nil,error);
}
void SGLosslessForgetAlignment(void) {
    atomic_fetch_add(&sg_proofRevision,1);
    dispatch_async(queue(), ^{ sg_proofTrack=nil; sg_proofPath=nil; });
}

NSDictionary *SGLosslessCheck(NSString **error) {
    __block NSDictionary *result;
    __block NSString *failure;
    dispatch_sync(queue(), ^{ NSString *e; result = check(&e); failure = e; });
    *error = failure;
    return result;
}

void SGLosslessStop(BOOL release) {
    atomic_store(&sg_renderedAt, 0);
    atomic_fetch_add(&sg_generation, 1);
    atomic_store(&sg_live, false);
    atomic_store(&sg_anchorEpoch, 0);
    if (release) { SGLosslessForgetAlignment(); dispatch_async(queue(), ^{ drop(); sg_outputPCM=nil; }); }
}

BOOL SGLosslessPlaying(void) {
    uint64_t epoch = atomic_load(&sg_anchorEpoch);
    return epoch && epoch == SGPlayerSourceEpoch() && atomic_load(&sg_playGeneration)==atomic_load(&sg_generation);
}

NSDictionary *SGLosslessSourceInfo(void) {
    if (!SGLosslessPlaying()) return @{};
    @synchronized (NSProcessInfo.processInfo) { return sg_sourceInfo ?: @{}; }
}
BOOL SGLosslessRendering(void) {
    uint64_t at = atomic_load(&sg_renderedAt);
    if (!at || !SGLosslessPlaying()) return NO;
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    return (mach_absolute_time() - at) * (double)base.numer / base.denom < 5e8;
}
