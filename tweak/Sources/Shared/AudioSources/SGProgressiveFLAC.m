#import "SGProgressiveFLAC.h"
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <string.h>

@interface SGProgressiveFLAC ()
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) BOOL (^cancelled)(void);
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic) uint64_t available, total;
@property(nonatomic) BOOL finished, failed, probing;
@property(nonatomic) int descriptor;
@property(nonatomic) CFAbsoluteTime expires;
@property(nonatomic) CFAbsoluteTime probeDeadline;
@property(nonatomic, copy) NSDictionary *information;
@end

@interface SGProgressiveFLACOwner : NSObject
@property(nonatomic, strong) SGProgressiveFLAC *source;
@property(nonatomic) AudioFileID audioFile;
@property(nonatomic, copy) BOOL (^cancelled)(void);
@end
@implementation SGProgressiveFLACOwner
- (void)dealloc { if (_audioFile) AudioFileClose(_audioFile); }
@end

static NSLock *registryLock(void) {
    static NSLock *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock=[NSLock new]; }); return lock;
}
static NSMutableDictionary<NSString *,SGProgressiveFLAC *> *registry(void) {
    static NSMutableDictionary *values; static dispatch_once_t once;
    dispatch_once(&once, ^{ values=[NSMutableDictionary dictionary]; }); return values;
}
static SGProgressiveFLAC *sourceForPath(NSString *path) {
    if (!path.length) return nil;
    [registryLock() lock]; SGProgressiveFLAC *value=registry()[path]; [registryLock() unlock]; return value;
}
static OSStatus readBytes(void *context, SInt64 position, UInt32 requested, void *buffer, UInt32 *actual) {
    SGProgressiveFLACOwner *holder=(__bridge SGProgressiveFLACOwner *)context;
    SGProgressiveFLAC *source=holder.source;
    *actual=0;
    if (position<0 || (uint64_t)position>UINT64_MAX-requested) return kAudioFilePositionError;
    [source.condition lock];
    uint64_t end=(uint64_t)position+requested;
    // A short read at the true end is EOF; the growing edge must never masquerade as EOF.
    CFAbsoluteTime limit=source.probing ? MIN(source.expires,source.probeDeadline) : source.expires;
    while (!source.failed && !source.finished && !source.cancelled() && !(holder.cancelled && holder.cancelled()) &&
           source.available<MIN(end,source.total) && CFAbsoluteTimeGetCurrent()<limit)
        [source.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    BOOL failed=source.failed || (!source.finished && source.cancelled()) || (holder.cancelled && holder.cancelled()) || (!source.finished && CFAbsoluteTimeGetCurrent()>=limit);
    uint64_t count=(uint64_t)position<source.available ? MIN((uint64_t)requested,source.available-(uint64_t)position) : 0;
    [source.condition unlock];
    if (failed) return kAudioFileUnspecifiedError;
    if (count) {
        ssize_t n=pread(source.descriptor,buffer,(size_t)count,(off_t)position);
        if (n<0 || (uint64_t)n!=count) return kAudioFileUnspecifiedError;
        *actual=(UInt32)n;
    }
    return noErr;
}
static SInt64 sizeOfSource(void *context) {
    SGProgressiveFLAC *source=((__bridge SGProgressiveFLACOwner *)context).source;
    [source.condition lock]; uint64_t total=source.total; [source.condition unlock]; return (SInt64)total;
}
static BOOL openSource(SGProgressiveFLAC *source, ExtAudioFileRef *file, CFTypeRef *owner, BOOL (^cancelled)(void), OSStatus *failure) {
    if (failure) *failure=noErr;
    *file=NULL; *owner=NULL;
    SGProgressiveFLACOwner *holder=[SGProgressiveFLACOwner new]; holder.source=source; holder.cancelled=cancelled;
    AudioFileID audio=NULL;
    OSStatus status=AudioFileOpenWithCallbacks((__bridge void *)holder,readBytes,NULL,sizeOfSource,NULL,kAudioFileFLACType,&audio);
    if (status) { if (failure) *failure=status; return NO; }
    holder.audioFile=audio;
    status=ExtAudioFileWrapAudioFileID(audio,false,file);
    if (status) { if (failure) *failure=status; return NO; }
    *owner=CFBridgingRetain(holder); return YES;
}
@implementation SGProgressiveFLAC
- (instancetype)initWithPath:(NSString *)path cancelled:(BOOL (^)(void))cancelled {
    if ((self=[super init])) {
        _path=[path copy]; _cancelled=[cancelled copy]; _condition=[NSCondition new];
        if (!_cancelled) _cancelled=^BOOL { return NO; };
        _descriptor=open(path.fileSystemRepresentation,O_RDONLY);
        _expires=CFAbsoluteTimeGetCurrent()+120;
        if (_descriptor<0) return nil;
    }
    return self;
}
- (void)dealloc { if (_descriptor>=0) close(_descriptor); }
- (void)publishBytes:(uint64_t)bytes total:(uint64_t)total {
    [_condition lock];
    if (bytes<_available || total>128*1024*1024 || (total && bytes>total) || (_total && total!=_total)) _failed=YES;
    else { _available=bytes; _total=total; }
    [_condition broadcast]; [_condition unlock];
}
- (void)finish:(BOOL)success {
    [_condition lock]; _finished=YES; _failed|=!success || !_total || _available!=_total;
    [_condition broadcast]; [_condition unlock];
}
- (NSDictionary *)probeDuration:(double)expected {
    [_condition lock]; uint64_t available=_available,total=_total; BOOL failed=_failed || _finished; [_condition unlock];
    if (failed || !total || available<64*1024 || available>=total || _cancelled()) return nil;
    uint8_t header[42];
    if (pread(_descriptor,header,sizeof(header),0)!=(ssize_t)sizeof(header) || memcmp(header,"fLaC",4) || (header[4]&0x7f)!=0 ||
        header[5]!=0 || header[6]!=0 || header[7]!=34) return nil;
    // All metadata blocks must already be present. Their absence is not an audio EOF.
    uint64_t offset=4;
    for (NSUInteger n=0;n<256;n++) {
        uint8_t block[4];
        if (offset>available-4 || pread(_descriptor,block,4,(off_t)offset)!=4) return nil;
        uint64_t length=((uint64_t)block[1]<<16)|((uint64_t)block[2]<<8)|block[3];
        offset+=4+length;
        if (offset>available) return nil;
        if (block[0]&0x80) break;
        if (n==255) return nil;
    }
    uint64_t fields=0; for (int i=18;i<26;i++) fields=(fields<<8)|header[i];
    UInt32 rate=(UInt32)(fields>>44),channels=(UInt32)((fields>>41)&7)+1,bits=(UInt32)((fields>>36)&31)+1;
    uint64_t frames=fields&0xfffffffffULL;
    double duration=rate ? (double)frames/rate : 0;
    if (channels!=2 || rate<8000 || rate>192000 || !frames || !isfinite(duration) || duration<=0 ||
        (expected>0 && fabs(duration-expected)>30) || available-offset<32*1024) return nil;
    ExtAudioFileRef file=NULL; CFTypeRef owner=NULL;
    [_condition lock]; _probing=YES; _probeDeadline=CFAbsoluteTimeGetCurrent()+2; [_condition unlock];
    BOOL opened=openSource(self,&file,&owner,nil,NULL);
    [_condition lock]; _probing=NO; [_condition unlock];
    if (!opened) return nil;
    AudioStreamBasicDescription format={0}; UInt32 size=sizeof(format);
    OSStatus status=ExtAudioFileGetProperty(file,kExtAudioFileProperty_FileDataFormat,&size,&format);
    ExtAudioFileDispose(file); CFRelease(owner);
    if (status || format.mFormatID!=kAudioFormatFLAC || format.mChannelsPerFrame!=channels || format.mSampleRate!=rate ||
        (format.mBitsPerChannel && format.mBitsPerChannel!=bits)) return nil;
    _information=@{@"codec":@"FLAC",@"rate":@(rate),@"bits":@(bits),@"channels":@(channels),@"duration":@(duration),@"progressive":@YES};
    [registryLock() lock]; registry()[_path]=self; [registryLock() unlock];
    return _information;
}
@end
BOOL SGProgressiveFLACOpen(NSString *path, ExtAudioFileRef *file, CFTypeRef *owner, BOOL (^cancelled)(void)) {
    return SGProgressiveFLACOpenWithStatus(path,file,owner,cancelled,NULL);
}
BOOL SGProgressiveFLACOpenWithStatus(NSString *path, ExtAudioFileRef *file, CFTypeRef *owner, BOOL (^cancelled)(void), OSStatus *failure) {
    SGProgressiveFLAC *source=sourceForPath(path);
    if (!source) { *file=NULL; *owner=NULL; if (failure) *failure=kAudioFileFileNotFoundError; return NO; }
    return openSource(source,file,owner,cancelled,failure);
}
NSDictionary *SGProgressiveFLACState(NSString *path) {
    SGProgressiveFLAC *source=sourceForPath(path); if (!source) return @{};
    [source.condition lock];
    NSDictionary *state=@{@"receivedBytes":@(source.available),@"expectedBytes":@(source.total),
        @"complete":@(source.finished && !source.failed),@"growing":@(!source.finished),
        @"cancelled":@(!source.finished && source.cancelled())};
    [source.condition unlock]; return state;
}
BOOL SGProgressiveFLACRegistered(NSString *path) { return sourceForPath(path)!=nil; }
NSDictionary *SGProgressiveFLACInfo(NSString *path) { return sourceForPath(path).information; }
BOOL SGProgressiveFLACComplete(NSString *path) {
    SGProgressiveFLAC *source=sourceForPath(path); if (!source) return NO;
    [source.condition lock]; BOOL complete=source.finished && !source.failed; [source.condition unlock]; return complete;
}
void SGProgressiveFLACForgetAll(void) {
    [registryLock() lock]; NSArray *values=registry().allValues; [registry() removeAllObjects]; [registryLock() unlock];
    for (SGProgressiveFLAC *source in values) [source finish:NO];
}
