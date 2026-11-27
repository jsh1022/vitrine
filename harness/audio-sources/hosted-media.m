#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import "Shared/AudioSources/SGHostedMedia.h"
#import "Shared/AudioSources/SGProgressiveFLAC.h"

static void require(BOOL ok, NSString *message) { if (!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
static NSData *readFile(NSString *path) { return [NSData dataWithContentsOfFile:path]; }
static void writeFile(NSData *data, NSString *path) { require([data writeToFile:path options:NSDataWritingAtomic error:NULL], [@"write " stringByAppendingString:path.lastPathComponent]); }
static NSData *deezerKey(NSString *trackID) {
    NSData *input=[trackID dataUsingEncoding:NSUTF8StringEncoding]; unsigned char digest[CC_MD5_DIGEST_LENGTH]; CC_MD5(input.bytes,(CC_LONG)input.length,digest);
    static const char alphabet[]="0123456789abcdef"; char chars[32];
    for (NSUInteger i=0;i<sizeof(digest);i++) { chars[i*2]=alphabet[digest[i]>>4]; chars[i*2+1]=alphabet[digest[i]&15]; }
    NSData *secret=[@"g4el58wc0zvf9na1" dataUsingEncoding:NSASCIIStringEncoding]; const uint8_t *sec=secret.bytes;
    uint8_t key[16]; for (NSUInteger i=0;i<16;i++) key[i]=(uint8_t)(chars[i]^chars[i+16]^sec[i]);
    return [NSData dataWithBytes:key length:sizeof(key)];
}
static NSData *blowfish(NSData *input, NSData *key, BOOL encrypt) {
    NSMutableData *output=[NSMutableData dataWithLength:input.length]; const uint8_t ivBytes[]={0,1,2,3,4,5,6,7};
    size_t moved=0; CCCryptorStatus status=CCCrypt(encrypt?kCCEncrypt:kCCDecrypt,kCCAlgorithmBlowfish,0,key.bytes,key.length,ivBytes,
        input.bytes,input.length,output.mutableBytes,output.length,&moved);
    require(status==kCCSuccess && moved==input.length,@"Blowfish CBC fixture operation succeeds without padding"); return output;
}
static NSData *makeDeezerFixture(NSData *plain, NSString *trackID) {
    NSMutableData *out=[plain mutableCopy]; NSData *key=deezerKey(trackID);
    for (NSUInteger offset=0,index=0;offset<out.length;offset+=2048,index++) {
        NSUInteger count=MIN((NSUInteger)2048,out.length-offset);
        if (index%3==0 && count==2048) {
            // Blowfish CBC restarts with the fixed IV for every encrypted 2048-byte block.
            NSData *block=[out subdataWithRange:NSMakeRange(offset,count)]; NSData *encrypted=blowfish(block,key,YES);
            [out replaceBytesInRange:NSMakeRange(offset,count) withBytes:encrypted.bytes];
        }
    }
    return out;
}
static NSData *decodedPCM(NSString *path) {
    ExtAudioFileRef file=NULL; OSStatus status=ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],&file);
    if (status || !file) return nil;
    AudioStreamBasicDescription source={0}; UInt32 size=sizeof(source);
    status=ExtAudioFileGetProperty(file,kExtAudioFileProperty_FileDataFormat,&size,&source);
    if (status || source.mChannelsPerFrame<1 || source.mChannelsPerFrame>8 || source.mSampleRate<=0) { ExtAudioFileDispose(file); return nil; }
    AudioStreamBasicDescription pcm={0}; pcm.mSampleRate=source.mSampleRate; pcm.mFormatID=kAudioFormatLinearPCM;
    pcm.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked; pcm.mBytesPerPacket=4*source.mChannelsPerFrame;
    pcm.mFramesPerPacket=1; pcm.mBytesPerFrame=pcm.mBytesPerPacket; pcm.mChannelsPerFrame=source.mChannelsPerFrame; pcm.mBitsPerChannel=32;
    status=ExtAudioFileSetProperty(file,kExtAudioFileProperty_ClientDataFormat,sizeof(pcm),&pcm);
    if (status) { ExtAudioFileDispose(file); return nil; }
    NSMutableData *result=[NSMutableData data]; float samples[4096*8];
    for (;;) {
        UInt32 frames=4096; AudioBufferList list={0}; list.mNumberBuffers=1;
        list.mBuffers[0]=(AudioBuffer){source.mChannelsPerFrame,(UInt32)(sizeof(float)*source.mChannelsPerFrame*frames),samples};
        status=ExtAudioFileRead(file,&frames,&list);
        if (status) { ExtAudioFileDispose(file); return nil; }
        if (!frames) break;
        [result appendBytes:samples length:(NSUInteger)frames*source.mChannelsPerFrame*sizeof(float)];
    }
    ExtAudioFileDispose(file); return result;
}
static void checkDeezerFixture(NSString *sourcePath, NSString *trackID, NSString *label, NSString *directory) {
    NSData *source=readFile(sourcePath); require(source.length>8192,[label stringByAppendingString:@" fixture has multiple complete 2048-byte blocks and a tail"]);
    NSData *baseline=decodedPCM(sourcePath); require(baseline.length>0,[label stringByAppendingString:@" original FLAC decodes to PCM"]);
    NSData *encrypted=makeDeezerFixture(source,trackID); require(![encrypted isEqual:source],[label stringByAppendingString:@" fixture contains encrypted blocks"]);
    SGHostedDeezerDecoder *incremental=[[SGHostedDeezerDecoder alloc] initWithTrackID:trackID];
    require(incremental!=nil,@"stream decoder accepts validated track identifier");
    NSMutableData *streamed=[NSMutableData data];
    const NSUInteger chunks[]={1,7,2047,2048,4099,65537};
    BOOL probed=NO; NSString *prefixPath=[directory stringByAppendingPathComponent:[label stringByAppendingString:@"-prefix.flac"]];
    for(NSUInteger offset=0,index=0;offset<encrypted.length;index++) {
        NSUInteger count=MIN(chunks[index%6],encrypted.length-offset);
        NSData *clear=[incremental appendData:[encrypted subdataWithRange:NSMakeRange(offset,count)] final:NO];
        require(clear!=nil,@"arbitrary network chunk boundaries decrypt");[streamed appendData:clear];offset+=count;
        require(streamed.length<=offset && offset-streamed.length<2048,@"only an incomplete block remains buffered");
        if(!probed && streamed.length>=128*1024 && offset<encrypted.length) {
            writeFile(streamed,prefixPath);
            SGProgressiveFLAC *prefix=[[SGProgressiveFLAC alloc] initWithPath:prefixPath cancelled:^BOOL{return NO;}];
            [prefix publishBytes:streamed.length total:source.length];
            NSDictionary *format=[prefix probeDuration:3];
            require(format && [format[@"codec"] isEqual:@"FLAC"] && !SGProgressiveFLACComplete(prefixPath),
                @"incrementally decrypted Deezer prefix is recognized by native decoder before full download");
            [prefix finish:NO]; probed=YES;
        }
    }
    require(probed,@"both resolution fixtures support partial format verification");
    NSData *tail=[incremental appendData:NSData.data final:YES]; require(tail!=nil,@"short final block flush succeeds");
    [streamed appendData:tail];require([streamed isEqual:source],@"incremental decryption restores exact FLAC before and after final tail");
    require([incremental appendData:NSData.data final:YES]==nil,@"completed decoder cannot be reused");
    require([[SGHostedDeezerDecoder alloc] initWithTrackID:@"not-a-track"]==nil,@"invalid track identifier is rejected");
    NSString *cancelPath=[directory stringByAppendingPathComponent:[label stringByAppendingString:@"-cancel.bin"]]; writeFile(encrypted,cancelPath);
    __block NSUInteger polls=0;
    BOOL cancelled=SGHostedPrepareMedia(@{@"hostedTransform":@"deezer",@"mediaTrackID":trackID},cancelPath,^BOOL{return ++polls>2;},NULL);
    require(!cancelled && polls>=3 && [readFile(cancelPath) isEqual:encrypted],[label stringByAppendingString:@" mid-stream cancellation preserves encrypted source"]);
    NSString *output=[directory stringByAppendingPathComponent:[label stringByAppendingString:@"-decrypted.flac"]]; writeFile(encrypted,output);
    BOOL ok=SGHostedPrepareMedia(@{@"hostedTransform":@"deezer",@"mediaTrackID":trackID},output,^BOOL{return NO;},NULL);
    require(ok,[label stringByAppendingString:@" three-block Blowfish fixture decrypts"]);
    NSData *plain=readFile(output); require([plain isEqual:source],[label stringByAppendingString:@" decryption restores exact FLAC bytes, interspersed clear blocks and tail"]);
    NSData *decoded=decodedPCM(output); require(decoded.length==baseline.length && [decoded isEqual:baseline],[label stringByAppendingString:@" native AudioToolbox PCM matches the original"]);
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    require(argc==4,@"takes 16/44.1 source FLAC, 24/96 source FLAC and output directory");
    NSString *directory=@(argv[3]);
    checkDeezerFixture(@(argv[1]),@"123456789",@"16-44k",directory);
    checkDeezerFixture(@(argv[2]),@"987654321",@"24-96k",directory);
    NSLog(@"PASS: Deezer block decryption for 16/44.1 and 24/96, native PCM verification and atomic cancellation");
} return 0; }
