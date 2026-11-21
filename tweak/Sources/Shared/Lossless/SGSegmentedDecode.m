#import "SGSegmentedDecode.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>

BOOL SGDecodeSegmentedLossless(NSString *input, NSString *output, BOOL (^cancelled)(void)) {
    if (NSThread.isMainThread || cancelled()) return NO;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:input] options:nil];
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    __block NSArray<AVAssetTrack *> *tracks;
    [asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *value, NSError *error) {
        tracks = error ? nil : value; dispatch_semaphore_signal(loaded);
    }];
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent()+20;
    while (dispatch_semaphore_wait(loaded, dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/10))) {
        if (cancelled() || CFAbsoluteTimeGetCurrent()>deadline) { [asset cancelLoading]; return NO; }
    }
    if (tracks.count != 1 || cancelled()) return NO;
    AVAssetTrack *track = tracks.firstObject;
    AudioStreamBasicDescription source = {0}; UInt32 bits=0;
    if (!track.formatDescriptions.count) return NO;
    for (id description in track.formatDescriptions) {
        const AudioStreamBasicDescription *f = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)description);
        if (!f || (f->mFormatID!=kAudioFormatFLAC && f->mFormatID!=kAudioFormatAppleLossless && f->mFormatID!=kAudioFormatLinearPCM) ||
            (f->mFormatID==kAudioFormatLinearPCM && (f->mFormatFlags&kAudioFormatFlagIsFloat)) ||
            f->mChannelsPerFrame!=2 || !isfinite(f->mSampleRate) || f->mSampleRate<8000 || f->mSampleRate>192000) return NO;
        UInt32 depth=f->mBitsPerChannel;
        if (!depth && f->mFormatID==kAudioFormatAppleLossless && f->mFormatFlags>=1 && f->mFormatFlags<=4) {
            const UInt32 depths[]={0,16,20,24,32}; depth=depths[f->mFormatFlags];
        }
        // Unknown depths and format switches are not guessed or silently converted.
        if ((depth!=16 && depth!=24 && depth!=32) || (source.mSampleRate && (source.mSampleRate!=f->mSampleRate || bits!=depth || source.mFormatID!=f->mFormatID))) return NO;
        source=*f; bits=depth;
    }
    AVAssetReader *reader=[AVAssetReader assetReaderWithAsset:asset error:NULL];
    AVAssetReaderTrackOutput *pcm=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
        AVFormatIDKey:@(kAudioFormatLinearPCM), AVLinearPCMBitDepthKey:@32,
        AVLinearPCMIsFloatKey:@NO, AVLinearPCMIsBigEndianKey:@NO, AVLinearPCMIsNonInterleaved:@NO}];
    if (!reader || ![reader canAddOutput:pcm]) return NO;
    [reader addOutput:pcm];
    if (![reader startReading]) return NO;
    AudioStreamBasicDescription destination={source.mSampleRate,kAudioFormatLinearPCM,kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked,
        2*(bits/8),1,2*(bits/8),2,bits,0};
    ExtAudioFileRef file=NULL;
    OSStatus status=ExtAudioFileCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:output],kAudioFileWAVEType,&destination,NULL,kAudioFileFlags_EraseFile,&file);
    AudioStreamBasicDescription client={source.mSampleRate,kAudioFormatLinearPCM,kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked,8,1,8,2,32,0};
    if (!status) status=ExtAudioFileSetProperty(file,kExtAudioFileProperty_ClientDataFormat,sizeof(client),&client);
    uint64_t frames=0;
    while (!status && !cancelled()) {
        CMSampleBufferRef sample=[pcm copyNextSampleBuffer]; if (!sample) break;
        CMTime timestamp=CMSampleBufferGetPresentationTimeStamp(sample);
        double at=CMTimeGetSeconds(timestamp);
        const AudioStreamBasicDescription *actual=CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
        CMItemCount count=CMSampleBufferGetNumSamples(sample);
        CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);
        // A non-zero start/gap/overlap needs an edit timeline; do not concatenate it out of sync.
        if (!actual || actual->mFormatID!=kAudioFormatLinearPCM || actual->mSampleRate!=source.mSampleRate || actual->mChannelsPerFrame!=2 ||
            actual->mBitsPerChannel!=32 || actual->mBytesPerFrame!=8 || count<=0 || !isfinite(at) ||
            fabs(at-frames/source.mSampleRate)>2/source.mSampleRate || !block || CMBlockBufferGetDataLength(block)!=(size_t)count*8 ||
            frames+(uint64_t)count>128*1024*1024/(2*(bits/8))) { CFRelease(sample); status=kAudio_ParamError; break; }
        NSMutableData *bytes=[NSMutableData dataWithLength:64*1024];
        for (CMItemCount copied=0;copied<count && !status && !cancelled();) {
            UInt32 amount=(UInt32)MIN((CMItemCount)8192,count-copied);
            status=CMBlockBufferCopyDataBytes(block,(size_t)copied*8,amount*8,bytes.mutableBytes);
            if (!status) {
                AudioBufferList buffers={1,{{2,amount*8,bytes.mutableBytes}}};
                status=ExtAudioFileWrite(file,amount,&buffers);
                frames+=amount; copied+=amount;
            }
        }
        CFRelease(sample);
    }
    BOOL ok=!status && !cancelled() && frames>0 && reader.status==AVAssetReaderStatusCompleted;
    [reader cancelReading];
    if (file && ExtAudioFileDispose(file)) ok=NO;
    if (!ok) [NSFileManager.defaultManager removeItemAtPath:output error:NULL];
    return ok;
}
