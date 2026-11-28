// Laya-compatible broker protocol, reimplemented for Vitrine's bounded network/Keychain path.
// References: Laya LosslessProviders.kt/ZarzSession.kt; Mornye/SpotiFLAC signed_session (LGPL-3.0).
#import "SGHostedLossless.h"
#import "SGSourceSecrets.h"
#import "SGWireGuard.h"
#import "SGAddonProtocol.h"
#import "Core/SGPrefs.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const broker = @"https://api.zarz.moe/v2";
static NSString *str(id v) { return [v isKindOfClass:NSString.class] ? v : @""; }
static NSDictionary *dict(id v) { return [v isKindOfClass:NSDictionary.class] ? v : @{}; }
static NSArray *array(id v) { return [v isKindOfClass:NSArray.class] ? v : @[]; }
static BOOL truth(id v) { return ([v isKindOfClass:NSNumber.class] || [v isKindOfClass:NSString.class]) && [v boolValue]; }
NSArray<NSString *> *SGHostedProviderIdentifiers(void) { return @[@"qobuz",@"tidal",@"deezer"]; }
BOOL SGHostedProvider(NSString *p) { return p && [SGHostedProviderIdentifiers() containsObject:p]; }
NSString *SGHostedProviderName(NSString *p) { return @{@"qobuz":@"Qobuz",@"tidal":@"Tidal",@"deezer":@"Deezer"}[p ?: @""] ?: @"내장 소스"; }
// Adapter protocol versions, not a claim to be an official Qobuz/Tidal application.
NSString *SGHostedAppVersion(NSString *p) { return @{@"qobuz":@"qobuz-web@1.2.21",@"tidal":@"tidal-web@1.2.5",@"deezer":@"deezer@1.3.5"}[p ?: @""]; }
static NSObject *lock(void) { static NSObject *v; static dispatch_once_t once; dispatch_once(&once, ^{v=[NSObject new];}); return v; }
static NSMutableDictionary *attempts;
static NSDate *serverQuietUntil;
BOOL SGHostedServerWaiting(void) { @synchronized(lock()) { return serverQuietUntil.timeIntervalSinceNow>0; } }
void SGHostedServerResponse(NSInteger status, NSString *header) {
    if (status!=429 && status<500) return;
    double wait=header.doubleValue;
    if (wait<=0) { NSDateFormatter *f=[NSDateFormatter new]; f.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat=@"EEE',' dd MMM yyyy HH':'mm':'ss z"; wait=[[f dateFromString:header] timeIntervalSinceNow]; }
    if (wait>0) @synchronized(lock()) {
        NSDate *until=[NSDate dateWithTimeIntervalSinceNow:wait];
        if (!serverQuietUntil || [until compare:serverQuietUntil]==NSOrderedDescending) serverQuietUntil=until;
    }
}
static NSString *newAttempt(NSString *p) {
    @synchronized(lock()) { if(!attempts)attempts=[NSMutableDictionary dictionary]; NSString *v=NSUUID.UUID.UUIDString; attempts[p]=v; return v; }
}
void SGHostedCancelAuthentication(NSString *p) { if (SGHostedProvider(p)) newAttempt(p); }
static NSString *account(NSString *p) { return [@"hosted-lossless." stringByAppendingString:p]; }
static NSDictionary *record(NSString *p) {
    @synchronized(lock()) {
        NSData *d=[SGSourceSecret(account(p)) dataUsingEncoding:NSUTF8StringEncoding];
        return dict(d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil);
    }
}
static BOOL save(NSString *p, NSDictionary *r) {
    NSData *d=[NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingSortedKeys error:NULL];
    @synchronized(lock()) { return d && SGSaveSourceSecret(account(p),[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]); }
}
static NSDate *expiry(NSDictionary *r) {
    NSString *text=str(r[@"expires_at"]); if (!text.length) return nil;
    NSISO8601DateFormatter *f=[NSISO8601DateFormatter new];
    f.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;
    NSDate *d=[f dateFromString:text]; if (d) return d;
    f.formatOptions=NSISO8601DateFormatWithInternetDateTime; return [f dateFromString:text];
}
static BOOL usable(NSDictionary *r) {
    NSDate *end=expiry(r);
    return str(r[@"session_id"]).length && str(r[@"session_secret"]).length &&
        (!str(r[@"expires_at"]).length || (end && end.timeIntervalSinceNow>0));
}
BOOL SGHostedVerified(NSString *p) { return SGHostedProvider(p) && usable(record(p)); }
NSDate *SGHostedAuthenticationExpiry(NSString *p) { return SGHostedProvider(p) ? expiry(record(p)) : nil; }
BOOL SGHostedAuthenticationExpired(NSString *p) {
    if (!SGHostedProvider(p)) return NO;
    NSDictionary *r=record(p);
    if ([r[@"authentication_expired"] boolValue]) return YES;
    NSDate *end=expiry(r);
    return str(r[@"session_id"]).length && str(r[@"session_secret"]).length && end && end.timeIntervalSinceNow<=0;
}
void SGHostedForget(NSString *p) {
    if (!SGHostedProvider(p)) return;
    @synchronized(lock()) {
        SGHostedCancelAuthentication(p);
        NSString *install=str(record(p)[@"install_id"]);
        save(p,install.length ? @{@"install_id":install} : @{});
    }
}
static NSString *sha(NSData *d) {
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes,(CC_LONG)d.length,bytes);
    NSMutableString *v=[NSMutableString string]; for (NSUInteger i=0;i<sizeof(bytes);i++) [v appendFormat:@"%02x",bytes[i]]; return v;
}
static NSData *utf(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
static NSString *hmac(NSString *key, NSString *text) {
    NSData *k=utf(key), *d=utf(text); unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256,k.bytes,k.length,d.bytes,d.length,bytes);
    NSString *s=[[NSData dataWithBytes:bytes length:sizeof(bytes)] base64EncodedStringWithOptions:0];
    return [[[s stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
NSDictionary *SGHostedSignedHeaders(NSDictionary *r, NSString *version, NSString *method, NSString *path, NSData *body, NSDate *date, NSString *nonce) {
    NSISO8601DateFormatter *f=[NSISO8601DateFormatter new];
    f.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;
    NSString *time=[f stringFromDate:date], *hash=sha(body ?: [NSData data]);
    NSString *sid=str(r[@"session_id"]);
    NSString *rolling=hmac(str(r[@"session_secret"]),[NSString stringWithFormat:@"%lld:%@",(long long)(date.timeIntervalSince1970/300),sid]);
    NSString *text=[@[@"ZARZ-HMAC-V1",method,path,@"",hash,time,nonce,sid,version,@"extension"] componentsJoinedByString:@"\n"];
    return @{@"X-Zarz-Session":sid,@"X-Zarz-Timestamp":time,@"X-Zarz-Nonce":nonce,@"X-Zarz-Body-SHA256":hash,
        @"X-Zarz-Signature":hmac(rolling,text),@"X-Zarz-App-Version":version,@"X-Zarz-Platform":@"extension"};
}
static NSString *nonce(void) { return [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString]; }
static NSMutableURLRequest *makeRequest(NSString *url, NSDictionary *body) {
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.timeoutInterval=25; [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [r setValue:@"Vitrine/1.0" forHTTPHeaderField:@"User-Agent"];
    if (body) {
        r.HTTPMethod=@"POST"; r.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingSortedKeys error:NULL];
        [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    return r;
}
static NSDictionary *call(NSString *p, NSString *path, NSDictionary *body, NSDictionary *extra, SGHostedRequest send, NSString **error) {
    NSDictionary *r=record(p);
    if (!usable(r)) { if(error)*error=@"내장 소스의 웹 인증이 필요하거나 만료되었습니다. 소스 목록에서 다시 인증하세요."; return nil; }
    NSMutableURLRequest *q=makeRequest([broker stringByAppendingString:path],body);
    NSDictionary *headers=SGHostedSignedHeaders(r,SGHostedAppVersion(p),q.HTTPMethod,q.URL.path,q.HTTPBody,NSDate.date,nonce());
    for (NSString *key in headers) [q setValue:headers[key] forHTTPHeaderField:key];
    for (NSString *key in extra) [q setValue:extra[key] forHTTPHeaderField:key];
    NSDictionary *reply=send(q);
    NSInteger status=[reply[@"_http"] integerValue];
    NSString *code=str(reply[@"code"]).uppercaseString, *origin=str(reply[@"origin"]).lowercaseString;
    if ((!origin.length || [origin isEqual:@"gateway"]) && ((status==401 && [code isEqual:@"SESSION_INVALID"]) || (status==428 && [code isEqual:@"VERIFY_REQUIRED"]))) {
        @synchronized(lock()) {
            if ([record(p)[@"session_id"] isEqual:r[@"session_id"]]) {
                SGHostedForget(p);
                NSMutableDictionary *expired=[record(p) mutableCopy];
                expired[@"authentication_expired"]=@YES; save(p,expired);
            }
        }
        if(error)*error=@"내장 소스 인증이 거부되거나 만료되었습니다. 웹 인증을 다시 진행하세요.";
        return nil;
    }
    if (!reply || status>=300) { if(error && !*error)*error=status ? [NSString stringWithFormat:@"내장 소스 요청 실패(HTTP %ld)",(long)status] : @"내장 소스 요청 실패 또는 대기 시간 초과"; return nil; }
    return reply;
}
static NSString *queryURL(NSString *base, NSDictionary *params) { return SGAddonEndpoint([NSURL URLWithString:base],@[],params).absoluteString; }
static NSDictionary *currentSession(NSString *p, SGHostedRequest send) {
    NSDictionary *old=record(p); NSDate *end=expiry(old);
    // Renew near expiry without replacing a still-valid session if the network fails.
    if (!usable(old) || !end || end.timeIntervalSinceNow>3600) return old;
    static NSMutableDictionary *lastRefresh;
    @synchronized(lock()) {
        if (!lastRefresh) lastRefresh=[NSMutableDictionary dictionary];
        if (lastRefresh[p] && [lastRefresh[p] timeIntervalSinceNow]>-60) return old;
        lastRefresh[p]=NSDate.date;
    }
    NSMutableURLRequest *q=makeRequest([broker stringByAppendingString:@"/session/refresh"],@{@"install_id":str(old[@"install_id"])});
    NSDictionary *headers=SGHostedSignedHeaders(old,SGHostedAppVersion(p),q.HTTPMethod,q.URL.path,q.HTTPBody,NSDate.date,nonce());
    for (NSString *key in headers) [q setValue:headers[key] forHTTPHeaderField:key];
    NSDictionary *reply=send(q);
    if (reply && !reply[@"_http"]) {
        @synchronized(lock()) {
            if ([record(p)[@"session_id"] isEqual:old[@"session_id"]]) {
                NSMutableDictionary *updated=[old mutableCopy];
                for (NSString *key in @[@"session_id",@"session_secret",@"expires_at"]) if (str(reply[key]).length) updated[key]=reply[key];
                if (usable(updated)) save(p,updated);
            }
        }
    }
    return record(p);
}
NSDictionary *SGHostedSearch(NSString *p, NSString *query, SGHostedRequest send, NSString **error) {
    if (!SGHostedProvider(p)) return nil;
    currentSession(p,send);
    if (!SGHostedVerified(p)) { if(error)*error=@"내장 소스 웹 인증이 필요합니다."; return nil; }
    NSDictionary *reply;
    if ([p isEqual:@"qobuz"]) {
        NSString *url=queryURL([broker stringByAppendingString:@"/qbz/track/search"],@{@"query":query,@"limit":@"10",@"offset":@"0",@"app_id":@"798273057"});
        reply=call(p,[url substringFromIndex:broker.length],nil,@{},send,error);
    } else if ([p isEqual:@"deezer"]) {
        reply=send(makeRequest(queryURL(@"https://api.deezer.com/search",@{@"q":query,@"limit":@"10"}),nil));
    } else {
        // Public signed-out catalogue credentials used by Laya; never a user's account/token.
        static NSString *token; static NSDate *until;
        if (!token.length || until.timeIntervalSinceNow<=0) {
            NSMutableURLRequest *r=makeRequest(@"https://auth.tidal.com/v1/oauth2/token",nil); r.HTTPMethod=@"POST";
            NSURLComponents *form=[NSURLComponents new]; form.queryItems=@[
                [NSURLQueryItem queryItemWithName:@"client_id" value:@"txNoH4kkV41MfH25"],
                [NSURLQueryItem queryItemWithName:@"client_secret" value:@"dQjy0MinCEvxi1O4UmxvxWnDjt4cgHBPw8ll6nYBk98="],
                [NSURLQueryItem queryItemWithName:@"grant_type" value:@"client_credentials"]];
            r.HTTPBody=utf(form.percentEncodedQuery); [r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
            NSDictionary *auth=send(r); token=str(auth[@"access_token"]);
            until=[NSDate dateWithTimeIntervalSinceNow:MAX(60,[auth[@"expires_in"] doubleValue]-60)];
        }
        if (!token.length) { if(error && !*error)*error=@"Tidal 공개 카탈로그 인증에 실패했습니다."; return nil; }
        NSMutableURLRequest *r=makeRequest(queryURL(@"https://tidal.com/v1/search/tracks",@{@"query":query,@"limit":@"10",@"offset":@"0",@"countryCode":@"US",@"locale":@"en_US",@"deviceType":@"BROWSER"}),nil);
        [r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"]; reply=send(r);
        if ([reply[@"_http"] integerValue]==401) token=nil;
    }
    if (!reply || [reply[@"_http"] integerValue]>=300) return nil;
    NSMutableArray *rows=[NSMutableArray array];
    NSArray *items=[p isEqual:@"qobuz"] ? array(dict(reply[@"tracks"])[@"items"]) : [p isEqual:@"deezer"] ? array(reply[@"data"]) : array(reply[@"items"]);
    for (id item in items) {
        NSDictionary *t=dict(item), *album=dict(t[@"album"]);
        if ([t[@"streamable"] isEqual:@NO] || [t[@"streamReady"] isEqual:@NO]) continue;
        NSString *identifier=[t[@"id"] respondsToSelector:@selector(stringValue)] ? [t[@"id"] stringValue] : str(t[@"id"]);
        NSString *artist=str(dict(t[@"performer"])[@"name"]);
        if (!artist.length) artist=str(dict(t[@"artist"] ?: album[@"artist"])[@"name"]);
        if (!artist.length) { NSMutableArray *names=[NSMutableArray array]; for(id a in array(t[@"artists"])) if(str(dict(a)[@"name"]).length) [names addObject:str(dict(a)[@"name"])]; artist=[names componentsJoinedByString:@", "]; }
        NSString *title=str(t[@"title"]), *version=str(t[@"version"]);
        if (version.length) title=[title stringByAppendingFormat:@" (%@)",version];
        if (!identifier.length || !title.length) continue;
        [rows addObject:@{@"id":identifier,@"title":title,@"artist":artist,@"duration":t[@"duration"] ?: @0}];
    }
    return @{@"tracks":rows};
}
NSDictionary *SGHostedStreamResponse(NSString *p, NSDictionary *payload) {
    if (!SGHostedProvider(p)) return nil;
    if ([p isEqual:@"deezer"]) {
        if (![payload[@"success"] isEqual:@YES]) return nil;
        NSString *format=str(payload[@"deezer_source_format"] ?: payload[@"deezer_format"]).lowercaseString;
        if (format.length && ![format hasPrefix:@"flac"]) return nil;
        BOOL direct=truth(payload[@"direct_downloadable"]);
        NSString *url=direct ? str(payload[@"direct_download_url"]) : @"";
        if (!url.length) url=str(payload[@"download_url"]); if(!url.length)url=str(payload[@"direct_download_url"]);
        if (!SGAddonBaseURL(url)) return nil;
        NSMutableDictionary *stream=[@{@"url":url,@"codec":@"flac"} mutableCopy];
        BOOL encrypted=payload[@"requires_client_decryption"] ? truth(payload[@"requires_client_decryption"]) :
            payload[@"direct_downloadable"] ? !direct : truth(payload[@"deezer_encrypted"]);
        if (encrypted) {
            NSString *track=[payload[@"deezer_track_id"] respondsToSelector:@selector(stringValue)] ? [payload[@"deezer_track_id"] stringValue] : str(payload[@"deezer_track_id"]);
            if (!track.length) {
                NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"/media/(?:[0-9]+/){1,6}([0-9]{3,})/[0-9a-f]{16,}\\.[a-z0-9]+" options:NSRegularExpressionCaseInsensitive error:NULL];
                NSTextCheckingResult *match=[re firstMatchInString:url options:0 range:NSMakeRange(0,url.length)];
                if(match)track=[url substringWithRange:[match rangeAtIndex:1]];
            }
            if (!track.length) track=str(payload[@"requested_track_id"]);
            if (!track.length || [track rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location!=NSNotFound) return nil;
            stream[@"hostedTransform"]=@"deezer"; stream[@"mediaTrackID"]=track;
        }
        return stream;
    }
    if ([p isEqual:@"qobuz"]) {
        for (NSDictionary *o in @[payload,dict(payload[@"data"])]) for (NSString *key in @[@"download_url",@"url",@"link"]) {
            NSString *url=str(o[key]); if (SGAddonBaseURL(url)) return @{@"url":url,@"codec":@"flac"};
        }
        return nil;
    }
    NSDictionary *d=dict(payload[@"data"]); if ([str(d[@"assetPresentation"]) caseInsensitiveCompare:@"PREVIEW"]==NSOrderedSame) return nil;
    NSData *manifest=[[NSData alloc] initWithBase64EncodedString:str(d[@"manifest"]) options:0];
    if (!manifest.length || manifest.length>1024*1024) return nil;
    NSString *text=[[NSString alloc] initWithData:manifest encoding:NSUTF8StringEncoding];
    if ([[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] hasPrefix:@"<"])
        return @{@"url":broker,@"codec":@"flac",@"manifest":@"dash",@"manifestText":text};
    NSDictionary *bts=dict([NSJSONSerialization JSONObjectWithData:manifest options:0 error:NULL]);
    NSString *mime=str(bts[@"mimeType"]).lowercaseString;
    if (![mime containsString:@"flac"] && ![mime containsString:@"alac"]) return nil;
    NSString *url=str(array(bts[@"urls"]).firstObject);
    return SGAddonBaseURL(url) ? @{@"url":url,@"codec":[mime containsString:@"alac"] ? @"alac" : @"flac"} : nil;
}
NSDictionary *SGHostedStream(NSString *p, NSString *track, SGHostedRequest send, NSString **error) {
    if (!track.length || track.length>128 || !SGHostedProvider(p)) return nil;
    currentSession(p,send);
    NSString *provider=@{@"qobuz":@"qbz",@"tidal":@"tid",@"deezer":@"dzr"}[p];
    NSString *resource=[p isEqual:@"qobuz"] ? [@"https://open.qobuz.com/track/" stringByAppendingString:track] :
        [p isEqual:@"deezer"] ? [@"https://www.deezer.com/track/" stringByAppendingString:track] : track;
    NSDictionary *ticket=call(p,@"/tickets",@{@"capability":@"download_ticket",@"provider":provider,
        @"resource_hash":sha(utf([NSString stringWithFormat:@"%@:track:%@",provider,resource.lowercaseString]))},@{},send,error);
    NSString *key=str(ticket[@"ticket_id"]); if (!key.length) key=str(ticket[@"ticket"]); if (!key.length) return nil;
    NSDictionary *body=[p isEqual:@"qobuz"] ? @{@"quality":@"hi-res-max",@"upload_to_r2":@NO,@"id":track,@"type":@"track",@"url":resource} :
        [p isEqual:@"deezer"] ? @{@"id":track,@"type":@"track",@"platform":@"deezer",@"url":resource} :
        @{@"id":track,@"quality":@"LOSSLESS"};
    NSDictionary *reply=call(p,[@"/dl/" stringByAppendingString:provider],body,@{@"X-Zarz-Ticket":key},send,error);
    if ([p isEqual:@"deezer"] && reply) { NSMutableDictionary *v=[reply mutableCopy];v[@"requested_track_id"]=track;reply=v; }
    NSDictionary *stream=reply ? SGHostedStreamResponse(p,reply) : nil;
    if (reply && !stream && error) *error=@"내장 소스가 지원되는 무손실 음원 주소·코덱·변환 정보를 반환하지 않았습니다.";
    return stream;
}

// Auth uses its own bounded delegate: no bearer/signature/grant ever follows a redirect or enters diagnostics.
@interface SGHostedAuthTransfer : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) NSMutableData *bytes;
@property(nonatomic) NSInteger status;
@property(nonatomic) dispatch_semaphore_t done;
@property(nonatomic) BOOL failed;
@property(nonatomic,copy) NSString *retryAfter;
@end
@implementation SGHostedAuthTransfer
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    self.status=[(NSHTTPURLResponse *)r statusCode]; self.retryAfter=[(NSHTTPURLResponse *)r valueForHTTPHeaderField:@"Retry-After"];
    completion(r.expectedContentLength>1024*1024 ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d {
    if (self.bytes.length+d.length>1024*1024) { self.failed=YES; [t cancel]; } else [self.bytes appendData:d];
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e { self.failed |= e!=nil; dispatch_semaphore_signal(self.done); }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)q completionHandler:(void (^)(NSURLRequest *))completion { completion(nil); }
@end
static dispatch_queue_t authQueue(void) { static dispatch_queue_t q; static dispatch_once_t once; dispatch_once(&once, ^{q=dispatch_queue_create("spotifyglass.hosted-auth",DISPATCH_QUEUE_SERIAL);}); return q; }
static NSDictionary *authSend(NSURLRequest *r, NSString **error) {
    if (SGHostedServerWaiting()) { if(error)*error=@"인증 서버가 지정한 재시도 대기 중입니다."; return nil; }
    NSString *reason; NSURLSessionConfiguration *config=SGSourceSessionConfiguration(&reason);
    if (!config) { if(error)*error=@"WireGuard를 사용할 수 없어 인증 요청을 차단했습니다."; return nil; }
    config.allowsCellularAccess=SGFlag(@"spotifyglass.sources.cellular",NO); config.allowsExpensiveNetworkAccess=config.allowsCellularAccess; config.allowsConstrainedNetworkAccess=NO;
    config.timeoutIntervalForRequest=25; config.timeoutIntervalForResource=30;
    SGHostedAuthTransfer *d=[SGHostedAuthTransfer new]; d.done=dispatch_semaphore_create(0); d.bytes=[NSMutableData data];
    NSURLSession *session=[NSURLSession sessionWithConfiguration:config delegate:d delegateQueue:nil];
    NSURLSessionDataTask *task=[session dataTaskWithRequest:r]; [task resume];
    if (dispatch_semaphore_wait(d.done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))) { [session invalidateAndCancel]; if(error)*error=@"인증 요청 시간이 초과되었습니다."; return nil; }
    [session finishTasksAndInvalidate];
    SGHostedServerResponse(d.status,d.retryAfter);
    if (d.failed || d.status<200 || d.status>=300) { if(error)*error=[NSString stringWithFormat:@"인증 요청에 실패했습니다(HTTP %ld).",(long)d.status]; return nil; }
    id v=[NSJSONSerialization JSONObjectWithData:d.bytes options:0 error:NULL];
    if (![v isKindOfClass:NSDictionary.class]) { if(error)*error=@"인증 서버가 올바른 응답을 보내지 않았습니다."; return nil; }
    return v;
}
static BOOL acceptSession(NSString *p, NSDictionary *r, NSDictionary *reply) {
    if (!str(reply[@"session_id"]).length || !str(reply[@"session_secret"]).length) return NO;
    NSMutableDictionary *v=[r mutableCopy];
    for (NSString *key in @[@"session_id",@"session_secret",@"expires_at"]) if ([reply[key] isKindOfClass:NSString.class]) v[key]=reply[key];
    [v removeObjectForKey:@"authentication_expired"];
    return usable(v) && save(p,v);
}
void SGHostedBeginAuthentication(NSString *p, void (^completion)(NSURL *,NSString *)) {
    if (!SGHostedProvider(p)) { completion(nil,@"지원하지 않는 내장 소스입니다."); return; }
    NSString *attempt=newAttempt(p);
    dispatch_async(authQueue(), ^{
        NSMutableDictionary *r=[record(p) mutableCopy]; NSString *error=nil;
        if (!str(r[@"install_id"]).length) r[@"install_id"]=NSUUID.UUID.UUIDString;
        @synchronized(lock()) {
            if (![attempts[p] isEqual:attempt]) return;
            if (!save(p,r)) { dispatch_async(dispatch_get_main_queue(), ^{completion(nil,@"인증 정보를 Keychain에 저장하지 못했습니다.");}); return; }
        }
        NSDictionary *reply=authSend(makeRequest(queryURL([broker stringByAppendingString:@"/bootstrap"],@{@"app_version":SGHostedAppVersion(p),@"install_id":r[@"install_id"]}),nil),&error);
        NSURL *challenge=nil;
        BOOL accepted=NO;
        @synchronized(lock()) { if (![attempts[p] isEqual:attempt]) return; if(reply)accepted=acceptSession(p,r,reply); }
        if (reply && !accepted) {
            NSString *url=str(reply[@"auth_url"]); if (!url.length) url=str(reply[@"challenge_url"]);
            if (!url.length && str(reply[@"challenge_id"]).length) url=queryURL([broker stringByAppendingString:@"/challenge"],@{@"id":reply[@"challenge_id"],@"cb":@"mornye://session-grant?cb_version=v2grant"});
            challenge=[NSURL URLWithString:url];
            // The broker page is the only entry point trusted to deliver a grant.
            if (![challenge.scheme.lowercaseString isEqual:@"https"] || ![challenge.host.lowercaseString isEqual:@"api.zarz.moe"] || challenge.user || challenge.password || challenge.fragment) { challenge=nil; error=@"인증 서버가 허용되지 않은 웹 주소를 반환했습니다."; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{completion(challenge,error);});
    });
}
void SGHostedCompleteAuthentication(NSString *p, NSString *grant, void (^completion)(NSString *)) {
    if (!SGHostedProvider(p) || !grant.length || grant.length>16384) { completion(@"올바르지 않은 인증 결과입니다."); return; }
    NSString *attempt; @synchronized(lock()) { attempt=attempts[p]; }
    if (!attempt) { completion(@"인증을 처음부터 진행하세요."); return; }
    dispatch_async(authQueue(), ^{
        NSDictionary *r=record(p); NSString *error=nil;
        if (!str(r[@"install_id"]).length) error=@"인증을 처음부터 다시 진행하세요.";
        NSDictionary *reply=error ? nil : authSend(makeRequest([broker stringByAppendingString:@"/session/exchange"],@{@"grant":grant,@"install_id":r[@"install_id"],@"app_version":SGHostedAppVersion(p),@"platform":@"extension"}),&error);
        @synchronized(lock()) {
            if (![attempts[p] isEqual:attempt]) return;
            if (reply && !acceptSession(p,r,reply)) error=@"유효한 인증 세션을 저장하지 못했습니다.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{completion(error);});
    });
}
