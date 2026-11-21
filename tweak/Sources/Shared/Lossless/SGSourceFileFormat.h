#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>

// Inspect decoded file metadata, never an extension or provider's format claim.
static inline BOOL SGSourceFileSupported(ExtAudioFileRef file, AudioStreamBasicDescription source) {
    if (source.mChannelsPerFrame != 2 || !isfinite(source.mSampleRate) || source.mSampleRate <= 0) return NO;
    if (source.mFormatID == kAudioFormatFLAC || source.mFormatID == kAudioFormatAppleLossless) return YES;
    if (source.mFormatID != kAudioFormatLinearPCM || !source.mBitsPerChannel) return NO;
    AudioFileID audioFile = NULL;
    UInt32 size = sizeof(audioFile);
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &size, &audioFile)) return NO;
    AudioFileTypeID container = 0;
    size = sizeof(container);
    if (AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &size, &container)) return NO;
    return container == kAudioFileWAVEType || container == kAudioFileAIFFType || container == kAudioFileAIFCType;
}

static inline NSString *SGSourceFileCodec(AudioStreamBasicDescription source) {
    switch (source.mFormatID) {
        case kAudioFormatFLAC: return @"FLAC";
        case kAudioFormatAppleLossless: return @"ALAC";
        case kAudioFormatLinearPCM: return @"PCM";
        default: return @"알 수 없음";
    }
}
