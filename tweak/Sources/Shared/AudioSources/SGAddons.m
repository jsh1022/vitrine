#import "SGAddons.h"
#import "SGAddonProtocol.h"
#import "SGAddonSegments.h"
#import "SGProgressiveFLAC.h"
#import "SGSourceSecrets.h"
#import "SGWireGuard.h"
#import "Core/SGCore.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/Lossless/SGSourceFileFormat.h"
#import "Shared/Lossless/SGSegmentedDecode.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Player/PlayerState.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Network/Network.h>
#import <stdatomic.h>
#import <math.h>

static _Atomic uint64_t sg_generation;
static NSString *sg_status = @"대기 중";
static SGAddonPreparationState sg_preparation;
static NSDictionary *sg_media;
static NSString *sg_failure; // worker-owned, fixed diagnostics only
// Serial-worker owned cache; never contains playable partial files.
static NSMutableDictionary<NSString *, NSDictionary *> *sg_prepared;
static NSArray *sg_upcomingPlan;
static _Atomic uint64_t sg_prefetchGeneration;
static _Atomic NSUInteger sg_foregroundPending;
static uint64_t sg_activePlan;
static NSString *sg_lastMediaURL, *sg_lastMediaETag;
static BOOL sg_background; // worker only
static BOOL sg_prefix;     // media requests only, worker only
static double sg_requestDeadline;
// Worker only. Invoked once when a direct FLAC can be handed to the native growing-file reader.
static void (^sg_progressiveReady)(NSString *, NSDictionary *);
static double sg_progressiveDuration;
static BOOL sg_progressiveOffered;
static NSString *sg_progressiveName;
static NSString *sg_progressivePath; // main only
// Cross-thread handoff identity. The serial worker still owns all transfer/file state.
static NSObject *handoffLock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock=[NSObject new]; }); return lock;
}
static NSString *sg_inflightURI;
static uint64_t sg_inflightGeneration, sg_inflightSerial;
static BOOL sg_inflightPromoted, sg_inflightPending;
static void (^sg_inflightReady)(NSString *,NSDictionary *);
static BOOL keepingInflight(uint64_t generation) {
    @synchronized(handoffLock()) {
        return sg_inflightURI.length && sg_inflightGeneration==generation &&
            (sg_inflightPromoted || sg_inflightPending);
    }
}
static void discard(NSDictionary *entry);
static void clearLookupCache(void);
static dispatch_queue_t worker(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("spotifyglass.addons", DISPATCH_QUEUE_SERIAL); });
    return q;
}
NSArray<NSDictionary *> *SGAddonSources(void) {
    NSData *data = [SGSourceSecret(@"addons") dataUsingEncoding:NSUTF8StringEncoding];
    id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    return [result isKindOfClass:NSArray.class] ? result : @[];
}
static BOOL save(NSArray *sources) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:sources options:0 error:NULL];
    return data && SGSaveSourceSecret(@"addons", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}
NSArray<NSDictionary *> *SGAddonEnabledSources(void) {
    return [SGAddonSources() filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *source, NSDictionary *bindings) {
        return ![source[@"enabled"] isEqual:@NO];
    }]];
}
BOOL SGAddonSetSourceEnabled(NSString *identifier, BOOL enabled) {
    NSMutableArray *sources = [SGAddonSources() mutableCopy];
    NSUInteger index = [sources indexOfObjectPassingTest:^BOOL(NSDictionary *source, NSUInteger i, BOOL *stop) { return [source[@"id"] isEqual:identifier]; }];
    if (index == NSNotFound) return NO;
    NSMutableDictionary *source = [sources[index] mutableCopy]; source[@"enabled"] = @(enabled); sources[index] = source;
    BOOL ok = save(sources); if (ok) SGAddonRetryCurrentTrack(); return ok;
}
BOOL SGAddonMoveSource(NSString *identifier, NSUInteger index) {
    NSMutableArray *sources = [SGAddonSources() mutableCopy];
    NSUInteger old = [sources indexOfObjectPassingTest:^BOOL(NSDictionary *source, NSUInteger i, BOOL *stop) { return [source[@"id"] isEqual:identifier]; }];
    if (old == NSNotFound || index >= sources.count) return NO;
    id source = sources[old]; [sources removeObjectAtIndex:old]; [sources insertObject:source atIndex:index];
    BOOL ok = save(sources); if (ok) SGAddonRetryCurrentTrack(); return ok;
}
BOOL SGAddonAddSource(NSString *input) {
    NSURL *url = SGAddonBaseURL(input);
    if (!url) return NO;
    NSMutableArray *sources = [SGAddonSources() mutableCopy];
    if (sources.count >= 8) return NO;
    for (NSDictionary *source in sources) if ([source[@"url"] isEqual:url.absoluteString]) return YES;
    [sources addObject:@{@"id": NSUUID.UUID.UUIDString, @"url": url.absoluteString, @"enabled": @YES}];
    BOOL ok = save(sources);
    if (ok) SGAddonRetryCurrentTrack();
    return ok;
}
BOOL SGAddonRemoveSource(NSString *identifier) {
    NSMutableArray *sources = [SGAddonSources() mutableCopy];
    NSIndexSet *indices = [sources indexesOfObjectsPassingTest:^BOOL(NSDictionary *s, NSUInteger i, BOOL *stop) { return [s[@"id"] isEqual:identifier]; }];
    [sources removeObjectsAtIndexes:indices];
    BOOL ok = save(sources);
    if (ok) SGAddonRetryCurrentTrack();
    return ok;
}
NSString *SGAddonStatus(void) { return sg_status; }
NSString *SGAddonStatusSummary(void) {
    if (SGLosslessRendering()) return @"재생 중";
    switch (sg_preparation) {
        case SGAddonPreparationSearching: return @"조회 중";
        case SGAddonPreparationDownloading: return @"다운로드 중";
        case SGAddonPreparationDecoding: return @"디코딩 중";
        case SGAddonPreparationAligning: return @"정렬 중";
        case SGAddonPreparationAligned: return @"정렬됨";
        case SGAddonPreparationUnavailable: return @"사용 불가";
        default: return @"대기 중";
    }
}
SGAddonPreparationState SGAddonPreparation(void) { return sg_preparation; }
void SGAddonSetPlaybackUnavailable(void) { sg_preparation = SGAddonPreparationUnavailable; }
void SGAddonSetPreparationStage(SGAddonPreparationState stage, NSString *status) {
    sg_status=status; sg_preparation=stage;
}
void SGAddonSetPlaybackStatus(NSString *status, BOOL aligned) {
    sg_status = status;
    sg_preparation = aligned ? SGAddonPreparationAligned : SGAddonPreparationAligning;
}
NSDictionary *SGAddonMediaInfo(void) { return sg_media ?: @{}; }
void SGAddonInvalidateRequests(void) {
    @synchronized(handoffLock()) {
        atomic_fetch_add(&sg_generation, 1);
        atomic_fetch_add(&sg_prefetchGeneration, 1);
        sg_inflightPromoted=NO; sg_inflightPending=NO; sg_inflightReady=nil;
    }
}
void SGAddonWillChangeTrack(void) {
    // Skip targets may be absent from command arguments. Keep just the active candidate
    // until the next state report identifies the new track; stop/settings always revoke.
    __block uint64_t serial=0;
    @synchronized(handoffLock()) {
        if (sg_inflightURI.length && sg_inflightGeneration==atomic_load(&sg_generation)) {
            sg_inflightPending=YES; serial=sg_inflightSerial;
        }
    }
    if (!serial) { SGAddonInvalidateRequests(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @synchronized(handoffLock()) {
            if (serial==sg_inflightSerial && sg_inflightPending) {
                sg_inflightPending=NO;
                SGAddonInvalidateRequests();
            }
        }
    });
}
void SGAddonTrackChanged(NSString *uri) {
    BOOL retained=NO;
    @synchronized(handoffLock()) {
        retained=uri.length && [uri isEqual:sg_inflightURI] &&
            sg_inflightGeneration==atomic_load(&sg_generation) && SGFlag(SGKeyAddons,NO) &&
            SGAddonPlaybackMode()==SGAddonPlaybackContinuous;
        if (retained) { sg_inflightPromoted=YES; sg_inflightPending=NO; }
    }
    if (!retained) { SGAddonCancel(); return; }
    // The old current-track file is released by the coordinator. Keep this candidate's
    // HTTP task, generation and received bytes, while cancelling the rest of its plan.
    atomic_fetch_add(&sg_prefetchGeneration,1);
    // No progressive callback has been attached to this background candidate yet.
    SGProgressiveFLACForgetAll();
    sg_upcomingPlan=nil; sg_progressivePath=nil; sg_media=nil;
    sg_status=@"사전 준비 중인 음원을 이어받는 중";
    sg_preparation=SGAddonPreparationDownloading;
}
void SGAddonCancel(void) {
    SGAddonInvalidateRequests();
    SGProgressiveFLACForgetAll();
    sg_progressivePath=nil;
    sg_upcomingPlan = nil;
    sg_media = nil;
    sg_status = @"대기 중";
    sg_preparation = SGAddonPreparationIdle;
}
void SGAddonRetryCurrentTrack(void) {
    SGLosslessPrepareNext(nil,0);
    SGAddonFinishPlaybackWait();
    SGAddonCancel();
    // A source/transport/policy edit invalidates cached authorizations and renditions too.
    dispatch_async(worker(), ^{
        clearLookupCache();
        for (NSDictionary *entry in sg_prepared.allValues) discard(entry);
        [sg_prepared removeAllObjects];
    });
    [NSNotificationCenter.defaultCenter postNotificationName:SGAddonRetryNotification object:nil];
}

// A bounded request. The worker can cancel while URLSession's delegate writes a file on its own
// serial queue. URLs, HTTP error bodies and provider error strings never reach diagnostics.
@interface SGAddonTransfer : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) NSUInteger limit, received;
@property(nonatomic) BOOL failed, prefix, prefixSatisfied;
@property(nonatomic) NSInteger status;
@property(nonatomic) NSUInteger offset;
@property(nonatomic) NSUInteger expectedBytes;
@property(nonatomic, strong) NSValue *boundedRange;
@property(nonatomic) BOOL mediaRequest;
@property(nonatomic, strong) NSURL *responseURL;
@property(nonatomic, strong) SGProgressiveFLAC *progressive;
@property(nonatomic, copy) NSString *entityTag;
@property(nonatomic, copy) NSString *retryAfter;
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, strong) NSFileHandle *file;
@property(nonatomic, strong) dispatch_semaphore_t done;
@end
@implementation SGAddonTransfer
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    self.status = [(NSHTTPURLResponse *)response statusCode];
    self.responseURL = response.URL;
    self.retryAfter = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Retry-After"];
    self.entityTag = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"ETag"];
    self.failed = self.boundedRange ? self.status != 206 : self.status != 200 && !((self.prefix || self.offset) && self.status == 206);
    if (self.status == 206) {
        NSString *range = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Content-Range"];
        unsigned long long start = 0, end = 0, total = 0;
        if (self.boundedRange) {
            NSRange requested = self.boundedRange.rangeValue;
            if (sscanf(range.UTF8String ?: "", "bytes %llu-%llu/%llu", &start, &end, &total) != 3 ||
                start != requested.location || end < start || end >= total || end-start+1 != requested.length) self.failed = YES;
            self.expectedBytes = requested.length;
        } else {
        if (sscanf(range.UTF8String ?: "", "bytes %llu-%llu/%llu", &start, &end, &total) != 3 ||
            start != self.offset || end < start || end >= total || (!self.prefix && (total > self.limit || end != total - 1)) ||
            (self.prefix && end != MIN(total, self.limit) - 1)) self.failed = YES;
        self.expectedBytes = self.prefix ? MIN(total, self.limit) : total;
        }
    } else if (self.status == 200 && self.offset) {
        // If-Range mismatch or a server ignoring Range: replace the prefix, never append it twice.
        [self.file truncateAtOffset:0 error:NULL]; [self.file seekToOffset:0 error:NULL];
        self.received = self.offset = 0;
    }
    if (!self.prefix && response.expectedContentLength > (int64_t)(self.limit - self.received)) self.failed = YES;
    if (self.status == 200 && response.expectedContentLength > 0)
        self.expectedBytes = self.prefix ? MIN((NSUInteger)response.expectedContentLength, self.limit) : (NSUInteger)response.expectedContentLength;
    completion(self.failed ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (self.failed) return;
    if (data.length > self.limit - self.received) {
        if (!self.prefix) { self.failed = YES; [task cancel]; return; }
        data = [data subdataWithRange:NSMakeRange(0, self.limit - self.received)];
    }
    self.received += data.length;
    if (self.file) {
        NSError *error;
        if (![self.file writeData:data error:&error]) { self.failed = YES; [task cancel]; }
    } else [self.body appendData:data];
    if (!self.failed) [self.progressive publishBytes:self.received total:self.expectedBytes];
    if (self.prefix && self.received == self.limit) { self.prefixSatisfied = YES; [task cancel]; }
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error && !(self.prefixSatisfied && error.code == NSURLErrorCancelled && [error.domain isEqual:NSURLErrorDomain])) self.failed = YES;
    if (self.expectedBytes && self.received != self.expectedBytes) self.failed = YES;
    [self.file closeFile];
    [self.progressive finish:!self.failed && self.received>0];
    dispatch_semaphore_signal(self.done);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
 newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    // Preserve secrets on addon API calls: no JSON redirects, even to another HTTPS host.
    // Media redirects carry no application auth header; refuse every downgrade.
    BOOL allowed = self.mediaRequest && [request.URL.scheme.lowercaseString isEqualToString:@"https"] && !request.URL.user && !request.URL.password && !request.URL.fragment;
    if (!allowed) self.failed = YES;
    completion(allowed ? request : nil);
}
@end

// Worker-confined server cooldowns and bounded in-memory lookup cache. There is
// no fixed requests/minute quota. Source changes never clear server cooldowns.
static NSMutableDictionary *sg_quiet, *sg_manifests, *sg_jsonCache;
static void initialize(void) {
    if (sg_quiet) return;
    sg_quiet = [NSMutableDictionary dictionary];
    sg_manifests = [NSMutableDictionary dictionary]; sg_jsonCache = [NSMutableDictionary dictionary];
}
static void clearLookupCache(void) {
    initialize(); [sg_manifests removeAllObjects]; [sg_jsonCache removeAllObjects];
}
static void invalidateSourceLookups(NSString *identifier) {
    initialize();
    [sg_manifests removeObjectForKey:identifier];
    NSString *prefix = [identifier stringByAppendingString:@"|"];
    for (NSString *key in sg_jsonCache.allKeys) if ([key hasPrefix:prefix]) [sg_jsonCache removeObjectForKey:key];
}
static BOOL sourceReady(NSString *identifier) {
    initialize();
    return [sg_quiet[identifier] doubleValue] <= NSDate.date.timeIntervalSince1970;
}
static double retryAfterSeconds(NSString *header) {
    if (!header.length) return -1;
    NSScanner *scanner = [NSScanner scannerWithString:header];
    double seconds = 0;
    if ([scanner scanDouble:&seconds] && scanner.isAtEnd && isfinite(seconds) && seconds >= 0) return seconds;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
    NSDate *date = [formatter dateFromString:header];
    return date ? MAX(0, date.timeIntervalSinceNow) : -1;
}
static BOOL superseded(uint64_t generation) {
    return generation != atomic_load(&sg_generation) ||
        (sg_background && !keepingInflight(generation) && (sg_activePlan != atomic_load(&sg_prefetchGeneration) || atomic_load(&sg_foregroundPending) > 0));
}
static void foregroundFinished(void) {
    atomic_fetch_sub(&sg_foregroundPending, 1);
    dispatch_async(dispatch_get_main_queue(), ^{
        // Re-submit only the current plan once foreground work has drained. No
        // polling timer or old captured queue is allowed to restart prefetch.
        if (atomic_load(&sg_foregroundPending) || !sg_upcomingPlan.count) return;
        NSArray *latest = sg_upcomingPlan;
        sg_upcomingPlan = nil;
        SGAddonUpdateUpcoming(latest);
    });
}
static BOOL networkAllowed(BOOL *unmetered) {
    // Check the current network before every request, including the media download.
    nw_path_monitor_t monitor = nw_path_monitor_create();
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block BOOL allowed = NO;
    __block BOOL received = NO;
    __block BOOL wifi = NO;
    nw_path_monitor_set_queue(monitor, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        if (received) return;
        received = YES;
        wifi = nw_path_uses_interface_type(path, nw_interface_type_wifi) && !nw_path_is_expensive(path) && !nw_path_is_constrained(path);
        allowed = nw_path_get_status(path) == nw_path_status_satisfied && !nw_path_is_constrained(path) &&
            (SGFlag(SGKeyAddonCellular, NO) || (!nw_path_is_expensive(path) && !nw_path_uses_interface_type(path, nw_interface_type_cellular)));
        dispatch_semaphore_signal(ready);
    });
    nw_path_monitor_start(monitor);
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    nw_path_monitor_cancel(monitor);
    if (unmetered) *unmetered = wifi;
    return allowed;
}
static SGAddonTransfer *fetchBounded(NSURL *url, NSString *path, NSString *identifier, uint64_t generation, NSDictionary *resume, NSValue *range, NSUInteger limit, NSString *accept, BOOL progressive) {
    if (superseded(generation)) return nil;
    if (!networkAllowed(NULL)) { sg_failure = @"네트워크 정책: 비과금 Wi-Fi를 사용하거나 셀룰러 다운로드를 허용하세요"; return nil; }
    if (!sourceReady(identifier)) { sg_failure = @"서버 재시도 대기 중입니다. 잠시 후 다시 시도하세요"; return nil; }
    NSString *reason;
    NSURLSessionConfiguration *config = SGSourceSessionConfiguration(&reason);
    if (!config) { sg_failure = @"WireGuard를 사용할 수 없어 애드온 요청을 차단했습니다"; return nil; } // enabled WireGuard never falls back to a direct session
    BOOL cellular = SGFlag(SGKeyAddonCellular, NO) &&
        (!sg_background || !path || sg_prefix || SGFlag(SGKeyAddonPrefetchCellular, NO));
    config.allowsCellularAccess = cellular;
    config.allowsExpensiveNetworkAccess = cellular;
    config.allowsConstrainedNetworkAccess = NO;
    SGAddonTransfer *transfer = [SGAddonTransfer new];
    transfer.prefix = path && sg_prefix;
    transfer.limit = limit;
    transfer.boundedRange = range;
    transfer.mediaRequest = path != nil || ![accept isEqual:@"application/json"];
    transfer.done = dispatch_semaphore_create(0);
    if (path) {
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}];
        if ([resume[@"url"] isEqual:url.absoluteString] && [resume[@"etag"] length] && ![resume[@"etag"] hasPrefix:@"W/"]) {
            if ([NSFileManager.defaultManager copyItemAtPath:resume[@"path"] toPath:[path stringByAppendingString:@".prefix"] error:NULL]) {
                [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
                [NSFileManager.defaultManager moveItemAtPath:[path stringByAppendingString:@".prefix"] toPath:path error:NULL];
                transfer.offset = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL].fileSize;
                if (transfer.offset >= transfer.limit) transfer.offset = 0;
                transfer.received = transfer.offset;
            }
        }
        transfer.file = [NSFileHandle fileHandleForWritingAtPath:path];
        if (transfer.offset) [transfer.file seekToEndReturningOffset:NULL error:NULL];
        if (!transfer.file) return nil;
        if (progressive) transfer.progressive=[[SGProgressiveFLAC alloc] initWithPath:path cancelled:^BOOL { return generation!=atomic_load(&sg_generation); }];
    } else transfer.body = [NSMutableData data];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:transfer delegateQueue:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if (range) {
        NSRange r = range.rangeValue;
        if (!r.length || r.location > NSUIntegerMax-r.length || r.length>limit) { [transfer.file closeFile]; [session invalidateAndCancel]; return nil; }
        [request setValue:[NSString stringWithFormat:@"bytes=%lu-%lu",(unsigned long)r.location,(unsigned long)NSMaxRange(r)-1] forHTTPHeaderField:@"Range"];
    } else if (transfer.prefix) [request setValue:@"bytes=0-2097151" forHTTPHeaderField:@"Range"];
    else if (transfer.offset) {
        [request setValue:[NSString stringWithFormat:@"bytes=%lu-", (unsigned long)transfer.offset] forHTTPHeaderField:@"Range"];
        [request setValue:resume[@"etag"] forHTTPHeaderField:@"If-Range"];
    }
    [request setValue:accept forHTTPHeaderField:@"Accept"];
    // Match BitChord iOS's addon compatibility header; this is not app proof.
    [request setValue:@"BitChord/v1.8" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    nw_path_monitor_t monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t network) {
        if (nw_path_is_constrained(network) || (!cellular && (nw_path_is_expensive(network) || nw_path_uses_interface_type(network, nw_interface_type_cellular)))) [task cancel];
    });
    nw_path_monitor_start(monitor);
    [task resume];
    double fullDeadline = CFAbsoluteTimeGetCurrent() + (path ? 120 : 20);
    double deadline = fullDeadline;
    if (sg_requestDeadline > 0) deadline = MIN(deadline, sg_requestDeadline);
    BOOL deadlineExpired = NO;
    BOOL offered = NO;
    double nextProbe=0;
    while (dispatch_semaphore_wait(transfer.done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10))) {
        void (^ready)(NSString *,NSDictionary *)=sg_progressiveReady;
        if (!ready && sg_background && keepingInflight(generation)) {
            @synchronized(handoffLock()) { ready=[sg_inflightReady copy]; }
        }
        if (!offered && transfer.progressive && ready && CFAbsoluteTimeGetCurrent()>=nextProbe && CFAbsoluteTimeGetCurrent()<deadline && !superseded(generation)) {
            nextProbe=CFAbsoluteTimeGetCurrent()+1;
            NSDictionary *info=[transfer.progressive probeDuration:sg_progressiveDuration];
            if (info && CFAbsoluteTimeGetCurrent()<deadline && !superseded(generation)) {
                offered=YES;
                sg_progressiveOffered=YES;
                // The preparation wait ends once handed off; the bounded HTTP download continues.
                deadline=fullDeadline; sg_requestDeadline=0;
                ready(path,info);
            }
        }
        deadlineExpired = CFAbsoluteTimeGetCurrent() > deadline;
        if (superseded(generation) || (sg_background && !SGFlag(SGKeyAddons, NO)) || deadlineExpired) [task cancel];
    }
    [session finishTasksAndInvalidate];
    nw_path_monitor_cancel(monitor);
    // Only a server-specified delay blocks subsequent requests. Transport errors
    // and timeouts fail this attempt without inventing a source-wide cooldown.
    BOOL interrupted = superseded(generation);
    double serverDelay = retryAfterSeconds(transfer.retryAfter);
    if ((transfer.status == 429 || transfer.status >= 500) && serverDelay > 0) {
        sg_quiet[identifier] = @(MAX([sg_quiet[identifier] doubleValue], NSDate.date.timeIntervalSince1970 + serverDelay));
    }
    if (interrupted) return nil;
    if (transfer.failed || !transfer.received) {
        if (transfer.status == 401 || transfer.status == 403) sg_failure = @"소스 접근이 거부되었습니다(401/403). 개인 링크의 만료·권한을 확인하세요. 공식 앱 증명이 필요한 서비스는 지원하지 않습니다.";
        else if (transfer.status == 429) sg_failure = serverDelay > 0
            ? @"소스 요청이 제한되었습니다(429). 서버가 지정한 Retry-After 대기 중"
            : @"소스 요청이 제한되었습니다(429). 서버가 대기 시간을 지정하지 않았습니다";
        else if (transfer.status) sg_failure = [NSString stringWithFormat:@"소스 HTTP %ld 또는 불완전하거나 너무 큰 응답", (long)transfer.status];
        else sg_failure = @"소스 연결 실패 또는 시간 초과";
    }
    return !transfer.failed && transfer.received && generation == atomic_load(&sg_generation) ? transfer : nil;
}
static SGAddonTransfer *fetch(NSURL *url, NSString *path, NSString *identifier, uint64_t generation, NSDictionary *resume) {
    return fetchBounded(url,path,identifier,generation,resume,nil,path ? (sg_prefix ? 2*1024*1024 : 128*1024*1024) : 1024*1024,
                        path ? @"audio/*,application/octet-stream" : @"application/json",
                        path && !sg_prefix && (sg_background || sg_progressiveReady!=nil));
}

// Called by the serial addon worker. Old requests and background preparation must
// never replace the foreground track's display or its post-download alignment stage.
static void reportPreparation(uint64_t generation, SGAddonPreparationState stage, NSString *status) {
    if (sg_background || sg_progressiveOffered) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation==atomic_load(&sg_generation)) SGAddonSetPreparationStage(stage,status);
    });
}
static BOOL prepareSegmentsWithinDeadline(NSDictionary *stream, NSString *path, NSString *identifier, uint64_t generation) {
    if (sg_prefix) { sg_failure=@"분할 스트림은 Wi-Fi 또는 전체 사전 준비가 허용된 연결에서 준비합니다"; return NO; }
    NSString *transport=SGAddonStreamTransport(stream);
    NSURL *url=[NSURL URLWithString:stream[@"url"]];
    CFAbsoluteTime deadline=CFAbsoluteTimeGetCurrent()+120;
    BOOL (^cancelled)(void)=^BOOL { return superseded(generation) || CFAbsoluteTimeGetCurrent()>deadline ||
        (sg_requestDeadline>0 && CFAbsoluteTimeGetCurrent()>sg_requestDeadline); };
    NSDictionary *plan=nil;
    NSMutableSet *visited=[NSMutableSet set];
    for (NSUInteger depth=0;depth<4 && !cancelled();depth++) {
        if ([visited containsObject:url]) break; [visited addObject:url];
        SGAddonTransfer *response=fetchBounded(url,nil,identifier,generation,nil,nil,1024*1024,
            @"application/vnd.apple.mpegurl,application/x-mpegURL,application/dash+xml",NO);
        if (!response) return NO;
        plan=SGAddonSegmentPlan(response.body,response.responseURL ?: url,transport);
        if (!plan[@"playlist"]) break;
        url=plan[@"playlist"]; plan=nil;
    }
    NSArray *parts=plan[@"parts"];
    if (!parts.count || cancelled()) { sg_failure=sg_failure ?: @"지원하지 않는 HLS/DASH 목록입니다. 완성된 비암호화 오디오 목록이 필요합니다"; return NO; }
    NSString *assembled=[path stringByAppendingString:@".segments.mp4"], *piece=[path stringByAppendingString:@".part"];
    NSFileManager *files=NSFileManager.defaultManager;
    [files createFileAtPath:assembled contents:nil attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}];
    NSFileHandle *writer=[NSFileHandle fileHandleForWritingAtPath:assembled];
    BOOL ok=writer!=nil;
    NSUInteger bytes=0;
    for (NSDictionary *p in parts) {
        if (!ok || cancelled() || bytes>=128*1024*1024) { ok=NO; break; }
        SGAddonTransfer *download=fetchBounded(p[@"url"],piece,identifier,generation,nil,p[@"range"],128*1024*1024-bytes,@"audio/*,video/mp4,application/octet-stream",NO);
        if (!download) { ok=NO; break; }
        NSFileHandle *reader=[NSFileHandle fileHandleForReadingAtPath:piece];
        if (!reader) { ok=NO; break; }
        NSUInteger copied=0;
        while (!cancelled()) {
            NSError *error=nil;
            NSData *data=[reader readDataUpToLength:64*1024 error:&error];
            if (error) { ok=NO; break; }
            if (!data.length) break;
            if (![writer writeData:data error:&error]) { ok=NO; break; }
            copied+=data.length;
        }
        [reader closeFile];
        if (copied!=download.received || cancelled()) ok=NO;
        bytes+=copied;
        [files removeItemAtPath:piece error:NULL];
    }
    [writer closeFile];
    if (ok && !cancelled()) {
        reportPreparation(generation,SGAddonPreparationDecoding,@"분할 음원 디코딩 및 파일 형식 확인 중");
        // Prefer the ordinary decoder when it understands the complete assembled file.
        if (parts.count==1 && SGMeasureLosslessFile(assembled,[plan[@"duration"] doubleValue])) {
            [files removeItemAtPath:path error:NULL]; ok=[files moveItemAtPath:assembled toPath:path error:NULL];
        } else ok=SGDecodeSegmentedLossless(assembled,path,cancelled);
    } else ok=NO;
    [files removeItemAtPath:piece error:NULL]; [files removeItemAtPath:assembled error:NULL];
    if (!ok) { [files removeItemAtPath:path error:NULL]; sg_failure=sg_failure ?: @"분할 음원이 지원되는 스테레오 무손실 코덱이 아니거나 완전히 준비되지 않았습니다"; }
    return ok;
}
static BOOL prepareSegments(NSDictionary *stream, NSString *path, NSString *identifier, uint64_t generation) {
    double previous=sg_requestDeadline;
    sg_requestDeadline=previous>0 ? MIN(previous,CFAbsoluteTimeGetCurrent()+120) : CFAbsoluteTimeGetCurrent()+120;
    @try { return prepareSegmentsWithinDeadline(stream,path,identifier,generation); }
    @finally { sg_requestDeadline=previous; }
}
static NSDictionary *json(NSURL *url, NSString *identifier, uint64_t generation) {
    if (!url || superseded(generation)) return nil;
    initialize();
    // URLs can contain private source parameters: memory only, never diagnostics.
    NSString *key = [identifier stringByAppendingFormat:@"|%@", url.absoluteString];
    NSDictionary *cached = sg_jsonCache[key];
    double now = NSDate.date.timeIntervalSince1970;
    if ([cached[@"until"] doubleValue] > now) return cached[@"value"];
    [sg_jsonCache removeObjectForKey:key];
    SGAddonTransfer *response = fetch(url, nil, identifier, generation, nil);
    id value = response ? [NSJSONSerialization JSONObjectWithData:response.body options:0 error:NULL] : nil;
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    double until = now + 30;
    if ([value[@"expiresAt"] respondsToSelector:@selector(doubleValue)]) until = MIN(until, [value[@"expiresAt"] doubleValue] - 1);
    if (until > NSDate.date.timeIntervalSince1970) {
        for (NSString *old in sg_jsonCache.allKeys) if ([sg_jsonCache[old][@"until"] doubleValue] <= now) [sg_jsonCache removeObjectForKey:old];
        if (sg_jsonCache.count >= 64) [sg_jsonCache removeAllObjects];
        sg_jsonCache[key] = @{@"value":value, @"until":@(until)};
    }
    return value;
}
static void rememberSourceInfo(NSDictionary *source, NSDictionary *manifest) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"name", @"description", @"version"]) {
        id value = manifest[key];
        if ([value isKindOfClass:NSString.class]) info[key] = [value substringToIndex:MIN([value length], [key isEqual:@"description"] ? 1000 : 160)];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *sources = [SGAddonSources() mutableCopy];
        for (NSUInteger i = 0; i < sources.count; i++) {
            NSDictionary *current = sources[i];
            if (![current[@"id"] isEqual:source[@"id"]] || ![current[@"url"] isEqual:source[@"url"]]) continue;
            NSMutableDictionary *updated = [current mutableCopy]; [updated addEntriesFromDictionary:info];
            if (![updated isEqual:current]) { sources[i] = updated; save(sources); }
            break;
        }
    });
}
static NSDictionary *manifest(NSDictionary *source, uint64_t generation) {
    initialize();
    NSString *identifier = source[@"id"];
    NSDictionary *cached = sg_manifests[identifier];
    if ([cached[@"until"] doubleValue] > NSDate.date.timeIntervalSince1970) return cached[@"value"];
    NSDictionary *value = json(SGAddonEndpoint(SGAddonBaseURL(source[@"url"]), @[@"manifest.json"], @{}), identifier, generation);
    if (!value) return nil;
    rememberSourceInfo(source, value);
    if (!SGAddonManifestSupported(value)) {
        sg_failure = @"지원하지 않는 manifest입니다.";
        return nil;
    }
    double now = NSDate.date.timeIntervalSince1970, until = now + 600;
    if ([value[@"expiresAt"] respondsToSelector:@selector(doubleValue)]) until = MIN(until, [value[@"expiresAt"] doubleValue] - 1);
    if (until <= now) { sg_failure = @"소스 정보가 만료되었습니다. 개인 manifest 링크를 갱신해 주세요"; return nil; }
    sg_manifests[identifier] = @{@"value": value, @"until": @(until)};
    return value;
}
void SGAddonRefreshSourceInfo(NSString *identifier, void (^completion)(NSString *)) {
    NSDictionary *selected = nil;
    for (NSDictionary *source in SGAddonSources()) if ([source[@"id"] isEqual:identifier]) { selected = source; break; }
    if (!selected) { if (completion) completion(@"소스를 찾을 수 없습니다."); return; }
    uint64_t generation = atomic_load(&sg_generation);
    dispatch_async(worker(), ^{
        sg_failure = nil;
        invalidateSourceLookups(identifier);
        NSDictionary *value = manifest(selected, generation);
        NSString *error = value ? nil : (sg_failure ?: @"소스 정보를 불러오지 못했습니다.");
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(error); });
    });
}
void SGAddonTestSource(NSString *identifier, void (^completion)(NSString *)) {
    NSArray *sources = SGAddonSources();
    uint64_t generation = atomic_load(&sg_generation);
    dispatch_async(worker(), ^{
        initialize();
        invalidateSourceLookups(identifier);
        sg_failure = nil;
        BOOL ok = NO;
        for (NSDictionary *source in sources) if ([source[@"id"] isEqual:identifier]) {
            NSDictionary *m = manifest(source, generation);
            if (m) {
                NSMutableDictionary *params = [SGAddonParameters(m) mutableCopy]; params[@"q"] = @"music";
                NSDictionary *response = json(SGAddonEndpoint(SGAddonBaseURL(source[@"url"]), @[@"search"], params), identifier, generation);
                ok = [response[@"tracks"] isKindOfClass:NSArray.class];
            }
            break;
        }
        NSString *failure = sg_failure ?: @"지원하지 않는 manifest 또는 검색 응답";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok ? @"manifest 및 검색 요청에 성공했습니다. 실제 재생에는 음원 매칭, 디코딩, 정렬도 성공해야 합니다." : failure); });
    });
}
NSDictionary *SGMeasureLosslessFile(NSString *path, double expected) {
    ExtAudioFileRef file = NULL;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &file)) return nil;
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof format;
    OSStatus status = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format);
    SInt64 frames = 0;
    size = sizeof frames;
    status |= ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames);
    BOOL supported = SGSourceFileSupported(file, format);
    ExtAudioFileDispose(file);
    BOOL flac = format.mFormatID == kAudioFormatFLAC, alac = format.mFormatID == kAudioFormatAppleLossless;
    double seconds = format.mSampleRate > 0 ? frames / format.mSampleRate : 0;
    if (status || !supported || !isfinite(seconds) || seconds <= 0 || (expected > 0 && fabs(seconds - expected) > 30)) return nil;
    UInt32 bits = format.mBitsPerChannel;
    if (!bits && alac && format.mFormatFlags >= 1 && format.mFormatFlags <= 4) {
        const UInt32 depths[] = {0, 16, 20, 24, 32}; bits = depths[format.mFormatFlags];
    }
    if (flac && !bits) {
        NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
        NSData *header = [handle readDataOfLength:42]; [handle closeFile];
        const uint8_t *b = header.bytes;
        if (header.length >= 42 && !memcmp(b, "fLaC", 4) && (b[4] & 0x7f) == 0) {
            uint64_t fields = 0; for (int i = 18; i < 26; i++) fields = (fields << 8) | b[i];
            bits = (UInt32)((fields >> 36) & 31) + 1;
        }
    }
    return @{@"codec": SGSourceFileCodec(format), @"rate": @(format.mSampleRate), @"bits": @(bits),
             @"channels": @(format.mChannelsPerFrame), @"duration": @(seconds),
             @"averageKbps": @([NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL].fileSize * 8.0 / seconds / 1000)};
}
static NSDictionary *prepare(NSString *uri, NSString *title, NSString *artist, double duration, NSArray *sources, uint64_t generation, NSDictionary *prefixEntry) {
        sg_progressiveOffered=NO;
        sg_lastMediaURL = sg_lastMediaETag = nil;
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vitrine-addons"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        static dispatch_once_t cleanup;
        dispatch_once(&cleanup, ^{
            for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL])
                [NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:name] error:NULL];
        });
        // One transient file per attempt, never an offline library or playlist prefetch.
        NSString *path = [directory stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".audio"]];
        sg_failure = nil;
        NSDictionary *measured = nil;
        for (NSDictionary *source in sources) {
            if (superseded(generation)) break;
            reportPreparation(generation,SGAddonPreparationSearching,@"애드온 소스 및 일치하는 음원 조회 중");
            NSDictionary *m = manifest(source, generation);
            if (!m) continue;
            NSURL *base = SGAddonBaseURL(source[@"url"]);
            NSMutableDictionary *params = [SGAddonParameters(m) mutableCopy];
            params[@"q"] = [NSString stringWithFormat:@"%@ %@", title, artist];
            NSDictionary *search = json(SGAddonEndpoint(base, @[@"search"], params), source[@"id"], generation);
            id rows = search[@"tracks"];
            if (![rows isKindOfClass:NSArray.class]) continue;
            NSDictionary *candidate = nil;
            for (id row in rows) if ([row isKindOfClass:NSDictionary.class] && SGAddonTrackMatches(row, title, artist, duration)) { candidate = row; break; }
            if (!candidate) { sg_failure = @"검색에 응답했지만 제목, 아티스트, 길이가 일치하는 녹음이 없습니다"; continue; }
            NSDictionary *stream = nil;
            // BitChord resolves /stream first; a row URL is only a fallback.
            if ([candidate[@"id"] isKindOfClass:NSString.class] && [candidate[@"id"] length])
                stream = json(SGAddonEndpoint(base, @[@"stream", candidate[@"id"]], SGAddonParameters(m)), source[@"id"], generation);
            if (![stream[@"url"] isKindOfClass:NSString.class] && [candidate[@"streamURL"] isKindOfClass:NSString.class]) {
                NSMutableDictionary *fallback = [candidate mutableCopy];
                fallback[@"url"] = candidate[@"streamURL"]; stream = fallback;
            }
            NSString *transport=stream ? SGAddonStreamTransport(stream) : nil;
            if (!stream || !SGAddonStreamSupported(stream)) { if (stream) sg_failure = @"지원하지 않는 스트림입니다. 비암호화 스테레오 FLAC/ALAC/PCM이 필요하며 MP3/AAC/Atmos/DRM은 지원하지 않습니다"; continue; }
            // As in BitChord, resolved rendition metadata wins over catalogue hints.
            id expiry = stream[@"expiresAt"];
            if ([expiry respondsToSelector:@selector(doubleValue)] && [expiry doubleValue] <= NSDate.date.timeIntervalSince1970) {
                sg_failure = @"음원 URL이 만료되었습니다. 소스를 갱신하고 다시 시도하세요"; continue;
            }
            sg_progressiveName=[m[@"name"] isKindOfClass:NSString.class] ? m[@"name"] : @"Addon";
            reportPreparation(generation,SGAddonPreparationDownloading,@"무손실 음원 다운로드 중");
            SGAddonTransfer *download = transport ? nil : fetch([NSURL URLWithString:stream[@"url"]], path, source[@"id"], generation, sg_prefix ? nil : prefixEntry);
            if (transport && prepareSegments(stream,path,source[@"id"],generation)) measured=SGMeasureLosslessFile(path,duration);
            else if (download) {
                sg_lastMediaURL = stream[@"url"]; sg_lastMediaETag = download.entityTag;
                if (sg_prefix) {
                    // Prefixes warm a bounded HTTP/file cache only. They are never submitted to the decoder.
                    measured = @{@"trackURI":uri, @"partial":@YES};
                } else {
                    reportPreparation(generation,SGAddonPreparationDecoding,@"다운로드 완료 · 디코더에서 파일 형식 확인 중");
                    measured = SGMeasureLosslessFile(path, duration);
                }
            }
            if (measured) {
                NSMutableDictionary *info = [measured mutableCopy];
                info[@"trackURI"] = uri; info[@"sourceName"] = [m[@"name"] isKindOfClass:NSString.class] ? m[@"name"] : @"Addon";
                NSMutableDictionary *declared = [NSMutableDictionary dictionary];
                for (NSString *key in @[@"codec", @"sampleRate", @"bitDepth", @"bitrate"]) {
                    id value = stream[key];
                    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) {
                        if ([key isEqualToString:@"sampleRate"] && [value doubleValue]>0 && [value doubleValue]<1000) value = @([value doubleValue]*1000);
                        declared[key] = value;
                    }
                }
                info[@"declared"] = declared; measured = info; break;
            }
            sg_failure = sg_failure ?: @"받은 음원이 일치하는 스테레오 FLAC/ALAC 또는 WAV/AIFF(무압축 PCM) 파일이 아닙니다";
            [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
            // A path already owned by the coordinator cannot be replaced under its active decoder.
            if (sg_progressiveOffered) break;
        }
        if (!measured || generation != atomic_load(&sg_generation)) { [NSFileManager.defaultManager removeItemAtPath:path error:NULL]; path = nil; }
        return path ? @{@"path":path, @"info":measured, @"made":@(CFAbsoluteTimeGetCurrent()), @"url":sg_lastMediaURL ?: @"", @"etag":sg_lastMediaETag ?: @""} : nil;
}

static void discard(NSDictionary *entry) {
    if (entry[@"path"]) [NSFileManager.defaultManager removeItemAtPath:entry[@"path"] error:NULL];
}
void SGAddonPrepare(NSString *uri, NSString *title, NSString *artist, double duration, void (^completion)(NSString *)) {
    if (!SGFlag(SGKeyAddons, NO) || SGAddonPlaybackMode() == SGAddonPlaybackFast || !SGAddonEnabledSources().count) { completion(nil); return; }
    uint64_t generation = atomic_load(&sg_generation);
    NSArray *sources = SGAddonEnabledSources();
    BOOL lookup = SGAddonAllowsCurrentLookup();
    double wait = SGAddonPlaybackMode() == SGAddonPlaybackPrefer ? MAX(5, MIN(30, SGInt(SGKeyAddonWaitSeconds, 10))) : 0;
    atomic_fetch_add(&sg_foregroundPending, 1);
    sg_status = @"일치하는 녹음 검색 중";
    sg_preparation = SGAddonPreparationSearching;
    __block BOOL delivered=NO;
    __block NSString *earlyPath=nil;
    void (^ready)(NSString *,NSDictionary *)=^(NSString *path, NSDictionary *measured) {
        if (delivered) return;
        delivered=YES; earlyPath=path;
        NSMutableDictionary *info=[measured mutableCopy]; info[@"trackURI"]=uri; info[@"sourceName"]=sg_progressiveName ?: @"Addon";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation!=atomic_load(&sg_generation)) { completion(nil); return; }
            sg_progressivePath=path; sg_media=info;
            sg_status=@"FLAC 다운로드 진행 중 · 받은 구간 디코딩 대기 중";
            sg_preparation=SGAddonPreparationDecoding;
            completion(path);
        });
    };
    @synchronized(handoffLock()) {
        if (lookup && sg_inflightPromoted && [sg_inflightURI isEqual:uri] && sg_inflightGeneration==generation)
            sg_inflightReady=[ready copy];
    }
    dispatch_async(worker(), ^{
        if (generation != atomic_load(&sg_generation)) { foregroundFinished(); dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); }); return; }
        NSDictionary *entry = sg_prepared[uri];
        sg_failure = nil;
        [sg_prepared removeObjectForKey:uri];
        NSDictionary *prefixEntry = [entry[@"info"][@"partial"] boolValue] ? entry : nil;
        if (prefixEntry) entry = nil;
        if (entry && CFAbsoluteTimeGetCurrent() - [entry[@"made"] doubleValue] > 600) {
            discard(entry); entry = nil;
        }
        sg_background = NO; sg_prefix = NO;
        sg_requestDeadline = wait > 0 ? CFAbsoluteTimeGetCurrent() + wait : 0;
        sg_progressiveDuration=duration;
        sg_progressiveReady=ready;
        if (!entry && lookup && !delivered) entry = prepare(uri, title, artist, duration, sources, generation, prefixEntry);
        sg_progressiveReady=nil; sg_progressiveName=nil;
        discard(prefixEntry);
        sg_requestDeadline = 0;
        NSString *failure = sg_failure ?: (lookup ? @"검증된 파일이 없어 Spotify 오디오를 유지합니다" : @"재생 중 자동 전환이 꺼져 있습니다. 다음 곡을 계속 준비합니다");
        NSDictionary *result = entry;
        foregroundFinished();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (delivered) {
                if (generation==atomic_load(&sg_generation) && [sg_progressivePath isEqual:earlyPath]) {
                    if (result) {
                        sg_media=result[@"info"];
                        [NSNotificationCenter.defaultCenter postNotificationName:SGAddonDownloadFinishedNotification object:result[@"path"]];
                    }
                    else {
                        SGPlayerInvalidateSource(); SGLosslessStop(NO);
                        sg_preparation=SGAddonPreparationUnavailable; sg_status=failure;
                    }
                } else if (result) discard(result);
                return;
            }
            if (generation == atomic_load(&sg_generation)) {
                sg_media = result[@"info"];
                sg_status = result ? @"파일 검증 완료 · 디코딩 대기 중" : failure;
                sg_preparation = result ? SGAddonPreparationDecoding : SGAddonPreparationUnavailable;
                completion(result[@"path"]);
            } else { discard(result); completion(nil); }
        });
    });
}
void SGAddonUpdateUpcoming(NSArray<NSDictionary *> *tracks) {
    BOOL enabled=SGRedesignedUI() && SGFlag(SGKeyAddons,NO) && SGAddonPlaybackMode()==SGAddonPlaybackContinuous && SGFlag(SGKeyAddonPrefetchEnabled,YES);
    if (!enabled) tracks=@[];
    if (tracks.count > SGAddonPrefetchMaxTracks) tracks = [tracks subarrayWithRange:NSMakeRange(0, SGAddonPrefetchMaxTracks)];
    if ([tracks isEqual:sg_upcomingPlan]) return;
    if (!enabled) SGLosslessPrepareNext(nil,0);
    sg_upcomingPlan = [tracks copy];
    uint64_t plan = atomic_fetch_add(&sg_prefetchGeneration, 1) + 1;
    uint64_t generation = atomic_load(&sg_generation);
    NSArray *sources = SGAddonEnabledSources(), *upcoming = [tracks copy];
    NSString *currentURI=SGURIString(SGPlayerState().track.URI);
    AudioStreamBasicDescription client={0};
    double predecodeRate=SGPlayerMusicClientFormat(&client) ? client.mSampleRate : 0;
    dispatch_async(worker(), ^{
        if (plan != atomic_load(&sg_prefetchGeneration) || generation != atomic_load(&sg_generation) || atomic_load(&sg_foregroundPending)) return;
        if (!sg_prepared) sg_prepared = [NSMutableDictionary dictionary];
        NSMutableSet *wanted = [NSMutableSet setWithArray:[upcoming valueForKey:@"uri"]];
        if (currentURI.length) [wanted addObject:currentURI];
        for (NSString *uri in sg_prepared.allKeys) if (![wanted containsObject:uri]) {
            discard(sg_prepared[uri]); [sg_prepared removeObjectForKey:uri];
        }
        BOOL wifi = NO;
        if (!upcoming.count || !networkAllowed(&wifi)) return;
        sg_background = YES; sg_activePlan = plan;
        NSUInteger index = 0;
        for (NSDictionary *track in upcoming) {
            if (plan != atomic_load(&sg_prefetchGeneration) || generation != atomic_load(&sg_generation) || atomic_load(&sg_foregroundPending)) break;
            BOOL whole = index++ == 0 && (wifi || SGFlag(SGKeyAddonPrefetchCellular, NO));
            NSString *uri = track[@"uri"];
            NSDictionary *cached = sg_prepared[uri];
            if (cached && CFAbsoluteTimeGetCurrent() - [cached[@"made"] doubleValue] < 600 && (!whole || ![cached[@"info"][@"partial"] boolValue])) {
                if (index==1 && ![cached[@"info"][@"partial"] boolValue])
                    SGLosslessPrepareNext(cached[@"path"],predecodeRate>0 ? predecodeRate : [cached[@"info"][@"rate"] doubleValue]);
                continue;
            }
            [sg_prepared removeObjectForKey:uri];
            if (index>1) {
                // Stagger farther source warm-ups; current playback always preempts.
                double readyAt=CFAbsoluteTimeGetCurrent()+.5;
                while (CFAbsoluteTimeGetCurrent()<readyAt && !superseded(generation)) [NSThread sleepForTimeInterval:.02];
                if (superseded(generation)) break;
            }
            sg_prefix = !whole;
            sg_requestDeadline = CFAbsoluteTimeGetCurrent() + 120;
            @synchronized(handoffLock()) {
                // Do not expose a job already invalidated before it starts.
                if (generation!=atomic_load(&sg_generation) || plan!=atomic_load(&sg_prefetchGeneration)) break;
                sg_inflightURI=[uri copy]; sg_inflightGeneration=generation;
                ++sg_inflightSerial; sg_inflightPromoted=NO; sg_inflightPending=NO; sg_inflightReady=nil;
            }
            sg_progressiveDuration=[track[@"duration"] doubleValue];
            NSDictionary *entry = prepare(uri, track[@"title"], track[@"artist"], [track[@"duration"] doubleValue], sources, generation, cached);
            discard(cached);
            BOOL promoted=NO;
            @synchronized(handoffLock()) {
                promoted=sg_inflightPromoted || sg_inflightPending;
                sg_inflightURI=nil; sg_inflightPromoted=NO; sg_inflightPending=NO; sg_inflightReady=nil;
            }
            if ((promoted || plan == atomic_load(&sg_prefetchGeneration)) && generation == atomic_load(&sg_generation) && entry) {
                sg_prepared[uri] = entry;
                if (!promoted && index==1 && ![entry[@"info"][@"partial"] boolValue])
                    SGLosslessPrepareNext(entry[@"path"],predecodeRate>0 ? predecodeRate : [entry[@"info"][@"rate"] doubleValue]);
            }
            else discard(entry);
            if (promoted) break;
        }
        sg_background = NO; sg_prefix = NO; sg_requestDeadline = 0;
        // Retry only a failed plan with a real cooldown. A successful/unchanged
        // queue does not repeatedly resolve and download every 60 seconds.
        double nextRetry = 0, now = NSDate.date.timeIntervalSince1970;
        for (NSDictionary *source in sources) {
            double until = [sg_quiet[source[@"id"]] doubleValue];
            if (until > now && (!nextRetry || until < nextRetry)) nextRetry = until;
        }
        BOOL missing = NO;
        for (NSDictionary *track in upcoming) if (!sg_prepared[track[@"uri"]]) missing = YES;
        if (missing && nextRetry > now && !atomic_load(&sg_foregroundPending)) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MIN(3600, MAX(1, nextRetry - now)) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (plan != atomic_load(&sg_prefetchGeneration) || generation != atomic_load(&sg_generation) || atomic_load(&sg_foregroundPending)) return;
                sg_upcomingPlan = nil;
                SGAddonUpdateUpcoming(upcoming);
            });
        }
    });
}
