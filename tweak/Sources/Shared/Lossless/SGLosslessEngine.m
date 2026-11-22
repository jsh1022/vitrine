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

enum { kIdle, kArmed, kFull };
enum { kCoarse = 16 };                      // decimation for the coarse search
enum { kRing = 1 << 19 };                   // frames the ring holds, about 12 s at 44.1 kHz
enum { kChunk = 8192 };                     // frames per read
static const double kAnchorSeconds = 4, kCheckSeconds = 1, kHintWindow = 8;
static const float kMinMatch = 0.8f;        // normalized correlation below this is another recording or master

#pragma mark - capture (original Spotify PCM only, before replacement)

enum { kMaxCaptureRate = 192000, kHistoryFrames = 1 << 20 };
static float *sg_cap;
static uint32_t sg_capLength;
static _Atomic uint32_t sg_capFill;
static _Atomic int sg_capState;
static atomic_uint sg_captureReaders;
static atomic_flag sg_captureWriter = ATOMIC_FLAG_INIT;
static uint64_t sg_capStart, sg_capEpoch, sg_capNext;
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
        sg_capStart=(uint64_t)sourceFrame; sg_capEpoch=epoch; sg_capUnit=output; sg_capRate=rate;
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
        sg_capStart=start; sg_capNext=end; sg_capEpoch=epoch; sg_capUnit=unit; sg_capRate=rate; sg_capLength=needed;
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

static atomic_bool sg_live;
static atomic_uint sg_readers;
static uint64_t sg_playEpoch, sg_playSource, sg_playAsset;
static AudioUnit sg_playUnit;
static double sg_playRate;
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
        && rate == sg_playRate && sourceFrame >= sg_playSource) {
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

static _Atomic uint64_t sg_generation; // also revokes blocked growing-file reads

typedef struct {
    ExtAudioFileRef file;
    CFTypeRef owner;
    double fileRate, rate;
    uint64_t frames;                        // at the client rate
    uint64_t epoch, generation;
} Reader;

static void closeReader(Reader *reader) {
    if (reader->file) ExtAudioFileDispose(reader->file);
    if (reader->owner) CFRelease(reader->owner);
    *reader = (Reader){0};
}

static BOOL openReader(Reader *reader, NSString *path, double rate, NSString **error) {
    closeReader(reader);
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
    if (status || !lossless || source.mChannelsPerFrame != 2 || frames <= 0) {
        ExtAudioFileDispose(file);
        if (owner) CFRelease(owner);
        *error = @"not supported stereo FLAC, ALAC or WAV/AIFF PCM";
        return NO;
    }
    *reader = (Reader){file, owner, source.mSampleRate, rate, (uint64_t)floor(frames * rate / source.mSampleRate), epoch, generation};
    return YES;
}

// Up to `count` frames from file frame `at` into l and r; the frames read (0 at the end).
static UInt32 readAt(Reader *reader, uint64_t at, UInt32 count, float *l, float *r, BOOL seek) {
    if (seek && ExtAudioFileSeek(reader->file, (SInt64)llround(at * reader->fileRate / reader->rate))) return 0;
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
static Reader sg_reader;                    // for searches and checks
static float *sg_coarse;                    // the file's mono at 1/kCoarse of the rate
static uint64_t sg_coarseCount, sg_coarseStart;
static uint64_t sg_decodedFrames;
static BOOL sg_predecoded;
static _Atomic uint64_t sg_anchorEpoch;
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
static BOOL takeWarm(NSString *path, double rate) {
    SGWarmLossless *selected=nil;
    @synchronized(warmLock()) {
        for (SGWarmLossless *item in [sg_warm copy]) {
            if ([item.path isEqual:path] && item->reader.rate==rate) { selected=item; [sg_warm removeObject:item]; break; }
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
    BOOL same=sg_reader.file && [sg_path isEqual:path] && sg_reader.rate==rate;
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
static uint64_t search(uint64_t from, uint64_t to, float *score, float *gain) {
    uint64_t lo = MAX(from / kCoarse,sg_coarseStart), hi = MIN(to / kCoarse, sg_coarseStart+sg_coarseCount);
    vDSP_Length capN = sg_capLength / kCoarse;
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
    float best = -INFINITY;
    for (vDSP_Length i = 0; i < lags; i++) {
        float s = running > 1e-9 ? corr[i] / sqrtf((float)running) : 0;
        if (s > best) { best = s; coarse = i; }
        if (i + capN < fileN) running += (double)file[i + capN] * file[i + capN] - (double)file[i] * file[i];
    }
    free(cap); free(corr);
    int64_t center = (int64_t)(lo + coarse) * kCoarse;
    return refine(center - 2 * kCoarse, center + 2 * kCoarse, score, gain);
}

// Four seconds of continuous source audio are still required, even when reused.
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

static NSDictionary *anchor(NSString *path, double hint, NSString **error) {
    SGLosslessBeginCapture();
    stopPlaying();
    if (sg_anchorProgress) sg_anchorProgress(SGLosslessPhaseCapture);
    if (!record(kAnchorSeconds, error)) return nil;
    if (sg_capEpoch!=SGPlayerSourceEpoch()) { *error=@"the source changed before decoding"; return nil; }
    double rate=sg_capRate;
    sg_decodedFrames=0; sg_predecoded=NO;
    double captureHint=isfinite(hint) && hint>=0 ? MAX(0,hint-sg_capReusedSeconds) : -1;
    double fromSeconds=captureHint>=0 ? MAX(0,captureHint-kHintWindow) : 0;
    double toSeconds=captureHint>=0 ? captureHint+kHintWindow+kAnchorSeconds : -1;
    if (!loadWindow(path,rate,fromSeconds,toSeconds,error)) return nil;
    if (sg_reader.frames<=sg_capLength) { *error=@"the file is shorter than the capture"; return nil; }
    CFAbsoluteTime start=CFAbsoluteTimeGetCurrent();
    uint64_t from=(uint64_t)(fromSeconds*rate),to=toSeconds<0 ? sg_reader.frames : (uint64_t)(toSeconds*rate);
    if (from+sg_capLength>=sg_reader.frames) { *error=@"Spotify plays past the end of the file"; return nil; }
    float score=0,gain=0;
    NSString *scope=captureHint>=0 ? @"hint" : @"wide";
    if (sg_anchorProgress) sg_anchorProgress(SGLosslessPhaseMatch);
    uint64_t lag=search(from,to,&score,&gain);
    if (score<kMinMatch && captureHint>=0 && sg_capEpoch==SGPlayerSourceEpoch()) {
        // Complete files may search globally; a growing source expands only around the hint.
        BOOL growing=SGProgressiveFLACRegistered(path) && !SGProgressiveFLACComplete(path);
        fromSeconds=growing ? MAX(0,captureHint-4*kHintWindow) : 0;
        toSeconds=growing ? captureHint+4*kHintWindow+kAnchorSeconds : -1;
        if (!loadWindow(path,rate,fromSeconds,toSeconds,error)) return nil;
        from=(uint64_t)(fromSeconds*rate); to=toSeconds<0 ? sg_reader.frames : (uint64_t)(toSeconds*rate);
        if (sg_anchorProgress) sg_anchorProgress(SGLosslessPhaseMatch);
        lag=search(from,to,&score,&gain); scope=@"wide";
    }
    double took = CFAbsoluteTimeGetCurrent() - start;
    SGLog(@"lossless: match %.4f at file %.3f s (hint %.1f s), gain %.3f, search %.2f s", score, lag / rate, hint, gain, took);
    if (score < kMinMatch) { *error = [NSString stringWithFormat:@"no match (%.3f)", score]; return nil; }
    if (sg_capEpoch != SGPlayerSourceEpoch()) { *error = @"the source changed while matching"; return nil; }

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
    uint64_t generation = atomic_load(&sg_generation), epoch = sg_playEpoch;
    atomic_fetch_add(&sg_writers, 1);
    // Its own thread: it runs for the rest of the song, which would hold a shared queue's thread that long.
    NSThread *writer = [[NSThread alloc] initWithBlock:^{ fill(path, rate, now, generation, epoch); }];
    writer.qualityOfService = NSQualityOfServiceUserInitiated;
    writer.name = @"spotifyglass.lossless.writer";
    [writer start];
    atomic_store(&sg_anchorEpoch, sg_capEpoch);
    atomic_store(&sg_live, true);
    return @{@"rate" : @(rate), @"source_frame":@(sg_capStart), @"file_frame" : @(lag), @"file_seconds" : @(lag / rate), @"match" : @(score),
             @"gain" : @(gain), @"search_s" : @(took), @"capture_reused_s":@(sg_capReusedSeconds),
             @"decoded_frames":@(sg_decodedFrames), @"predecoded":@(sg_predecoded), @"search_scope":scope};
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

NSDictionary *SGLosslessAnchorWithProgress(NSString *path, double hintSeconds,
    void (^progress)(SGLosslessPreparationPhase), NSString **error) {
    __block NSDictionary *result;
    __block NSString *failure;
    dispatch_sync(queue(), ^{
        sg_anchorProgress=[progress copy];
        @try { NSString *e=nil; result=anchor(path,hintSeconds,&e); failure=e; }
        @finally { sg_anchorProgress=nil; }
    });
    *error=failure; return result;
}
NSDictionary *SGLosslessAnchor(NSString *path, double hintSeconds, NSString **error) {
    return SGLosslessAnchorWithProgress(path,hintSeconds,nil,error);
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
    if (release) dispatch_async(queue(), ^{ drop(); });
}

BOOL SGLosslessPlaying(void) {
    uint64_t epoch = atomic_load(&sg_anchorEpoch);
    return epoch && epoch == SGPlayerSourceEpoch();
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
