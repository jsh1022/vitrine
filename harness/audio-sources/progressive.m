#import <Foundation/Foundation.h>
#import "Shared/AudioSources/SGProgressiveFLAC.h"
#include <stdatomic.h>
#include <math.h>

static atomic_bool cancelled;
static void require(BOOL ok, NSString *message) { if (!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
static OSStatus clientFormat(ExtAudioFileRef file) {
    AudioStreamBasicDescription pcm={44100,kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked,8,1,8,2,32,0};
    return ExtAudioFileSetProperty(file,kExtAudioFileProperty_ClientDataFormat,sizeof(pcm),&pcm);
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    require(argc==3,@"takes complete FLAC fixture and isolated temporary directory");
    NSData *encoded=[NSData dataWithContentsOfFile:@(argv[1])];
    require(encoded.length>256*1024,@"fixture must leave enough undecoded data after its prefix");
    NSString *path=[@(argv[2]) stringByAppendingPathComponent:@"growing.flac"];
    NSUInteger split=encoded.length/2;
    require([[encoded subdataWithRange:NSMakeRange(0,split)] writeToFile:path atomically:NO],@"write contiguous prefix");
    SGProgressiveFLAC *source=[[SGProgressiveFLAC alloc] initWithPath:path cancelled:^BOOL { return atomic_load(&cancelled); }];
    [source publishBytes:split total:encoded.length];
    require(![source probeDuration:999],@"mismatched recording duration is rejected before handoff");
    NSDictionary *info=[source probeDuration:12];
    require([info[@"codec"] isEqual:@"FLAC"] && [info[@"channels"] intValue]==2 && [info[@"bits"] intValue]==16 &&
            !SGProgressiveFLACComplete(path),@"native format verified while download is incomplete");
    ExtAudioFileRef file=NULL; CFTypeRef owner=NULL;
    require(SGProgressiveFLACOpen(path,&file,&owner,^BOOL { return atomic_load(&cancelled); }) && !clientFormat(file),@"open growing FLAC with owned callbacks");
    float samples[2048]; AudioBufferList buffers={1,{{2,sizeof(samples),samples}}}; UInt32 frames=1024;
    require(!ExtAudioFileRead(file,&frames,&buffers) && frames==1024 && !SGProgressiveFLACComplete(path),@"decode PCM before the remaining bytes arrive");
    __block uint64_t decoded=frames;
    dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        float block[8192]; AudioBufferList data={1,{{2,sizeof(block),block}}}; UInt32 count;
        OSStatus status=0;
        do { count=4096; status=ExtAudioFileRead(file,&count,&data); decoded+=count; } while (!status && count);
        require(!status && decoded==529200,@"growing edge never becomes premature EOF; complete frame count preserved");
        dispatch_semaphore_signal(finished);
    });
    require(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/4))!=0,@"reader waits at the growing edge instead of ending early");
    // A separate writer owns the file while the native reader is waiting for more bytes.
    NSFileHandle *writer=[NSFileHandle fileHandleForWritingAtPath:path]; [writer seekToEndReturningOffset:NULL error:NULL];
    NSUInteger at=split;
    while (at<encoded.length) {
        NSUInteger size=MIN((NSUInteger)16*1024,encoded.length-at);
        require([writer writeData:[encoded subdataWithRange:NSMakeRange(at,size)] error:NULL],@"append one rendition only");
        at+=size; [source publishBytes:at total:encoded.length];
    }
    [writer closeFile]; [source finish:YES];
    require(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0,@"reader completes after final bytes");
    require(SGProgressiveFLACComplete(path),@"complete transfer is recorded");
    ExtAudioFileDispose(file); CFRelease(owner);
    // Network/profile edits may revoke HTTP work; a fully validated immutable rendition survives.
    atomic_store(&cancelled,true);
    file=NULL; owner=NULL; OSStatus openingStatus=noErr;
    require(SGProgressiveFLACOpenWithStatus(path,&file,&owner,^BOOL { return NO; },&openingStatus) && !clientFormat(file),
            @"completed rendition remains readable after its network generation is revoked");
    frames=1024;
    require(!ExtAudioFileRead(file,&frames,&buffers) && frames==1024,
            @"retained completed rendition still decodes real PCM");
    ExtAudioFileDispose(file); CFRelease(owner);
    file=NULL; owner=NULL;
    require(!SGProgressiveFLACOpenWithStatus(path,&file,&owner,^BOOL { return YES; },&openingStatus) && openingStatus!=noErr,
            @"output epoch cancellation still rejects a reader of the completed rendition");
    atomic_store(&cancelled,false);
    SGProgressiveFLACForgetAll();
    // Transfer truncation is a hard failure, not a successful short recording.
    require([[encoded subdataWithRange:NSMakeRange(0,split)] writeToFile:path atomically:NO],@"reset partial fixture");
    source=[[SGProgressiveFLAC alloc] initWithPath:path cancelled:^BOOL { return atomic_load(&cancelled); }];
    [source publishBytes:split total:encoded.length];
    require([source probeDuration:12]!=nil,@"second partial file can be probed");
    [source finish:YES];
    require(!SGProgressiveFLACComplete(path),@"success flag cannot conceal a truncated response");
    file=NULL; owner=NULL;
    require(!SGProgressiveFLACOpen(path,&file,&owner,^BOOL { return NO; }),@"failed transfer refuses new native readers");
    SGProgressiveFLACForgetAll();
    // A skip/seek must interrupt a worker waiting for bytes, without waiting for HTTP completion.
    require([[encoded subdataWithRange:NSMakeRange(0,split)] writeToFile:path atomically:NO],@"reset cancellation fixture");
    source=[[SGProgressiveFLAC alloc] initWithPath:path cancelled:^BOOL { return atomic_load(&cancelled); }];
    [source publishBytes:split total:encoded.length];
    require([source probeDuration:12]!=nil,@"cancellation fixture can be probed");
    file=NULL; owner=NULL;
    require(SGProgressiveFLACOpen(path,&file,&owner,^BOOL { return atomic_load(&cancelled); }) && !clientFormat(file),@"open cancellable worker reader");
    dispatch_semaphore_t started=dispatch_semaphore_create(0),stopped=dispatch_semaphore_create(0);
    __block OSStatus readStatus=0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        dispatch_semaphore_signal(started);
        readStatus=ExtAudioFileSeek(file,44100*10);
        if (!readStatus) {
            float block[2048]; AudioBufferList data={1,{{2,sizeof(block),block}}}; UInt32 count=1024;
            readStatus=ExtAudioFileRead(file,&count,&data);
        }
        dispatch_semaphore_signal(stopped);
    });
    require(!dispatch_semaphore_wait(started,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)),@"worker began a future-range read");
    atomic_store(&cancelled,true);
    require(!dispatch_semaphore_wait(stopped,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC)) && readStatus!=noErr,@"cancellation wakes blocked native reads as an error");
    ExtAudioFileDispose(file); CFRelease(owner); SGProgressiveFLACForgetAll();
    NSLog(@"PASS: progressive FLAC partial decode, continuation, duration, truncation and cancellation checks");
} return 0; }
