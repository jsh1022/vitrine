#define SG_REAL_PROGRESSIVE_FLAC 1
#define main SGSettingsFixtureMain
#include "settings.m"
#undef main
#include <stdatomic.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>

static NSData *lowAudio, *highAudio, *highPlain;
static BOOL deezerMode;
static NSData *encryptDeezer(NSData *plain) {
    NSData *track=[@"123456" dataUsingEncoding:NSUTF8StringEncoding]; uint8_t md5[16];
    CC_MD5(track.bytes,(CC_LONG)track.length,md5);
    char hex[33];for(int i=0;i<16;i++)snprintf(hex+i*2,3,"%02x",md5[i]);
    const char *secret="g4el58wc0zvf9na1";uint8_t key[16];
    for(int i=0;i<16;i++)key[i]=(uint8_t)(hex[i]^hex[i+16]^secret[i]);
    NSMutableData *result=[plain mutableCopy];
    for(NSUInteger offset=0,index=0;offset+2048<=plain.length;offset+=2048,index++) if(index%3==0) {
        uint8_t iv[]={0,1,2,3,4,5,6,7},encoded[2048];size_t moved=0;
        require(CCCrypt(kCCEncrypt,kCCAlgorithmBlowfish,0,key,16,iv,(const uint8_t *)plain.bytes+offset,2048,encoded,2048,&moved)==kCCSuccess && moved==2048,@"independent encrypted fixture block");
        [result replaceBytesInRange:NSMakeRange(offset,2048) withBytes:encoded];
    }
    return result;
}
static atomic_int lowRequests, highRequests, lowCancelled;
static atomic_bool highFinished;
@interface SGQualityFixtureProtocol : NSURLProtocol
@property(atomic) BOOL stopped;
@end
@implementation SGQualityFixtureProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host hasSuffix:@"quality.test"] || [@[@"api.zarz.moe",@"api.deezer.com"] containsObject:request.URL.host]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    BOOL high=[self.request.URL.host hasPrefix:@"high"];
    NSString *path=self.request.URL.path;
    NSData *body=nil;
    BOOL media=[path isEqual:@"/audio"];
    if(media) {
        body=high ? highAudio : lowAudio;
        atomic_fetch_add(high ? &highRequests : &lowRequests,1);
    } else {
        id json=[path hasSuffix:@"manifest.json"] ? @{@"id":@"fixture",@"name":high?@"High":@"Low"} :
            [path containsString:@"/search"] ? @{@"tracks":@[@{@"id":@"one",@"title":@"Song",@"artist":@"Artist",@"duration":@12}]} :
            @{@"url":[NSString stringWithFormat:@"https://%@/audio",self.request.URL.host],@"format":@"flac"};
        if([self.request.URL.host isEqual:@"api.deezer.com"]) json=@{@"data":@[@{@"id":@123456,@"title":@"Song",@"artist":@{@"name":@"Artist"},@"duration":@12}]};
        if([path isEqual:@"/v2/tickets"]) json=@{@"ticket_id":@"fixture-ticket"};
        if([path isEqual:@"/v2/dl/dzr"]) json=@{@"success":@YES,@"deezer_source_format":@"FLAC",@"direct_downloadable":@NO,@"deezer_encrypted":@YES,@"deezer_track_id":@123456,@"download_url":@"https://high.quality.test/audio"};
        body=[NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    }
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Length":@(body.length).stringValue,@"Content-Type":media?@"audio/flac":@"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if(!media) {
        [self.client URLProtocol:self didLoadData:body]; [self.client URLProtocolDidFinishLoading:self]; return;
    }
    // Neither download can complete before the early-selection assertion.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(high?400:0)*NSEC_PER_MSEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        @synchronized(self) {
            if(self.stopped)return;
            [self.client URLProtocol:self didLoadData:[body subdataWithRange:NSMakeRange(0,256*1024)]];
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        @synchronized(self) {
            if(self.stopped)return;
            [self.client URLProtocol:self didLoadData:[body subdataWithRange:NSMakeRange(256*1024,body.length-256*1024)]];
            if(high)atomic_store(&highFinished,true);
            [self.client URLProtocolDidFinishLoading:self];
        }
    });
}
- (void)stopLoading {
    @synchronized(self) {
        self.stopped=YES;
        if([self.request.URL.host hasPrefix:@"low"] && [self.request.URL.path isEqual:@"/audio"])
            atomic_fetch_add(&lowCancelled,1);
    }
}
@end
static void pumpUntil(BOOL (^done)(void), double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(!done() && end.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    require(done(),@"streaming preparation completes within its test deadline");
}
int main(int argc,const char *argv[]) { @autoreleasepool {
    require(argc==3 || argc==4,@"takes low and high resolution FLAC fixtures plus optional Deezer mode");
    deezerMode=argc==4;
    lowAudio=[NSData dataWithContentsOfFile:@(argv[1])]; highAudio=[NSData dataWithContentsOfFile:@(argv[2])];
    highPlain=highAudio; if(deezerMode)highAudio=encryptDeezer(highPlain);
    require(lowAudio.length>512*1024 && highAudio.length>512*1024,@"fixtures leave substantial bytes after the probe");
    prefs=[@{SGKeyAddons:@YES,SGKeyAddonCellular:@YES,SGKeyAddonPlaybackMode:@(SGAddonPlaybackContinuous),
        SGKeyAddonAutoSwitch:@YES,SGKeyAddonParallelQuality:@YES,SGKeyAddonPrefetchEnabled:@NO} mutableCopy];
    secrets=[@{@"addons":@"[{\"id\":\"low\",\"url\":\"https://low.quality.test\",\"enabled\":true},{\"id\":\"high\",\"url\":\"https://high.quality.test\",\"enabled\":true}]"} mutableCopy];
    if(deezerMode) {
        NSMutableArray *list=[NSJSONSerialization JSONObjectWithData:[secrets[@"addons"] dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingMutableContainers error:nil];
        list[1][@"builtin"]=@"deezer";
        secrets[@"addons"]=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:list options:0 error:nil] encoding:NSUTF8StringEncoding];
        secrets[@"hosted-lossless.deezer"]=@"{\"expires_at\":\"2099-01-01T00:00:00Z\",\"session_id\":\"session-fixture\",\"session_secret\":\"fixture-secret\",\"install_id\":\"fixture-install\"}";
    }
    fixtureSessionConfiguration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    fixtureSessionConfiguration.protocolClasses=@[SGQualityFixtureProtocol.class];
    __block NSString *selected=nil; __block NSUInteger callbacks=0; __block BOOL finished=NO,failed=NO;
    [NSNotificationCenter.defaultCenter addObserverForName:SGAddonDownloadFinishedNotification object:nil queue:nil usingBlock:^(NSNotification *note){
        require([note.object isEqual:selected],@"completion belongs to selected in-flight file"); finished=YES;
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:SGAddonDownloadFailedNotification object:nil queue:nil usingBlock:^(NSNotification *note){failed=YES;}];
    CFAbsoluteTime began=CFAbsoluteTimeGetCurrent();
    SGAddonPrepare(@"spotify:track:fixture",@"Song",@"Artist",12,^(NSString *path){selected=path;callbacks++;});
    pumpUntil(^BOOL {return callbacks>0;},4);
    require(selected.length && callbacks==1 && !atomic_load(&highFinished),@"winner published from prefix before full download");
    require(atomic_load(&lowRequests)==1 && atomic_load(&highRequests)==1,@"both candidates download concurrently exactly once");
    require([SGAddonMediaInfo()[@"bits"] intValue]==24 && [SGAddonMediaInfo()[@"rate"] intValue]==96000,
        @"higher measured prefix wins over lower-quality prefix");
    require(CFAbsoluteTimeGetCurrent()-began<4,@"selection does not wait for the five-second download completion");
    pumpUntil(^BOOL{return finished || failed;},8);
    require(finished && !failed && callbacks==1 && atomic_load(&highRequests)==1,@"same winner request continues without another download or callback");
    require(atomic_load(&lowCancelled)>0,@"losing download cancelled");
    require([NSFileManager.defaultManager attributesOfItemAtPath:selected error:nil].fileSize==highAudio.length,
        @"winner completes into the original selected path");
    require([[NSData dataWithContentsOfFile:selected] isEqual:highPlain],@"completed winner preserves exact original FLAC, including streamed Deezer decryption");
    NSLog(@"PASS: concurrent FLAC prefixes, measured selection, early handoff, loser cancellation and single-request continuation");
}return 0;}
