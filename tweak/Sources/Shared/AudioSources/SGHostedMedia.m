// Provider transport details informed by Mornye-Extension's Deezer adapter (LGPL-3.0).
// Only server-authorized media and supplied keys enter this bounded local transform.
#import "SGHostedMedia.h"
#include <libavutil/blowfish.h>
#include <libavutil/md5.h>
#include <libavutil/mem.h>

enum { byteLimit=128*1024*1024 };
static BOOL numeric(NSString *v) { return [v isKindOfClass:NSString.class] && v.length && v.length<=32 && [v rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location==NSNotFound; }
@implementation SGHostedDeezerDecoder {
    AVBlowfish *_cipher;
    NSMutableData *_tail;
    NSUInteger _index, _received;
    BOOL _finished;
}
- (instancetype)initWithTrackID:(NSString *)track {
    if (!(self=[super init])) return nil;
    if (!numeric(track)) return nil;
    NSData *t=[track dataUsingEncoding:NSUTF8StringEncoding]; uint8_t md5[16]; av_md5_sum(md5,t.bytes,t.length);
    char hex[33]; for(int i=0;i<16;i++) snprintf(hex+i*2,3,"%02x",md5[i]);
    const char *secret="g4el58wc0zvf9na1"; uint8_t key[16];
    for(int i=0;i<16;i++) key[i]=(uint8_t)(hex[i]^hex[i+16]^secret[i]);
    _cipher=av_blowfish_alloc(); if(!_cipher)return nil;
    av_blowfish_init(_cipher,key,16); memset(key,0,sizeof(key));
    _tail=[NSMutableData data]; return self;
}
- (void)dealloc { if(_cipher) {memset(_cipher,0,sizeof(*_cipher));av_free(_cipher);} }
- (NSData *)appendData:(NSData *)data final:(BOOL)final {
    if(_finished || data.length>byteLimit-_received) {_finished=YES;return nil;}
    _received+=data.length;
    NSMutableData *input=[_tail mutableCopy];[input appendData:data];
    NSUInteger length=input.length/2048*2048;
    NSMutableData *output=[NSMutableData dataWithLength:length];
    for(NSUInteger offset=0;offset<length;offset+=2048,_index++) {
        const uint8_t *bytes=(const uint8_t *)input.bytes+offset;
        uint8_t *clear=(uint8_t *)output.mutableBytes+offset;
        if(_index%3==0) {
            uint8_t iv[]={0,1,2,3,4,5,6,7};
            av_blowfish_crypt(_cipher,clear,bytes,2048/8,iv,1);
        } else memcpy(clear,bytes,2048);
    }
    _tail=[[input subdataWithRange:NSMakeRange(length,input.length-length)] mutableCopy];
    if(final) { [output appendData:_tail];[_tail setLength:0];_finished=YES; }
    return output;
}
@end
static BOOL deezer(NSString *input, NSString *output, NSString *track, BOOL (^cancelled)(void)) {
    if (!numeric(track)) return NO;
    NSData *t=[track dataUsingEncoding:NSUTF8StringEncoding]; uint8_t md5[16]; av_md5_sum(md5,t.bytes,t.length);
    char hex[33]; for(int i=0;i<16;i++) snprintf(hex+i*2,3,"%02x",md5[i]);
    const char *secret="g4el58wc0zvf9na1"; uint8_t key[16];
    for(int i=0;i<16;i++) key[i]=(uint8_t)(hex[i]^hex[i+16]^secret[i]);
    AVBlowfish *cipher=av_blowfish_alloc(); if(!cipher)return NO; av_blowfish_init(cipher,key,16);
    memset(key,0,sizeof(key));
    NSFileHandle *reader=[NSFileHandle fileHandleForReadingAtPath:input];
    [NSFileManager.defaultManager createFileAtPath:output contents:nil attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}];
    NSFileHandle *writer=[NSFileHandle fileHandleForWritingAtPath:output]; BOOL ok=reader && writer; NSUInteger index=0,bytes=0;
    while(ok && !cancelled()) {
        NSError *error=nil; NSData *data=[reader readDataUpToLength:2048 error:&error];
        if(error) {ok=NO;break;} if(!data.length)break;
        if(bytes>byteLimit-data.length){ok=NO;break;} bytes+=data.length;
        if(index++%3==0 && data.length==2048) {
            NSMutableData *clear=[NSMutableData dataWithLength:data.length]; uint8_t iv[]={0,1,2,3,4,5,6,7};
            av_blowfish_crypt(cipher,clear.mutableBytes,data.bytes,(int)data.length/8,iv,1); data=clear;
        }
        if(![writer writeData:data error:&error]) {ok=NO;break;}
    }
    [reader closeFile]; [writer closeFile]; av_free(cipher);
    return ok && bytes>0 && !cancelled();
}
BOOL SGHostedPrepareMedia(NSDictionary *stream, NSString *path, BOOL (^cancelled)(void), NSString **error) {
    NSString *kind=stream[@"hostedTransform"];
    if(!kind)return YES;
    if(!cancelled || cancelled())return NO;
    NSFileManager *files=NSFileManager.defaultManager;
    NSDictionary *attrs=[files attributesOfItemAtPath:path error:NULL];
    if(!attrs || attrs.fileSize==0 || attrs.fileSize>byteLimit)return NO;
    NSString *temp=[path stringByAppendingFormat:@".%@.clear",NSUUID.UUID.UUIDString];
    BOOL ok=[kind isEqual:@"deezer"] ? deezer(path,temp,stream[@"mediaTrackID"],cancelled) : NO;
    if(ok && !cancelled()) ok=rename(temp.fileSystemRepresentation,path.fileSystemRepresentation)==0;
    else ok=NO;
    [files removeItemAtPath:temp error:NULL];
    if(!ok && error)*error=cancelled() ? @"곡 또는 설정 변경으로 음원 변환을 취소했습니다." : @"서버가 제공한 키로 무손실 음원을 준비하지 못했습니다. 암호화 형식·파일 완전성·키 유효성을 확인하세요.";
    return ok;
}
