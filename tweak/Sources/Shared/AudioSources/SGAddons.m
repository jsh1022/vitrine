#import "SGAddons.h"
#import "SGAddonProtocol.h"
#import "SGSourceSecrets.h"
#import "SGWireGuard.h"
#import "Core/SGCore.h"
#import "Shared/Lossless/SGLossless.h"
#import <AudioToolbox/AudioToolbox.h>
#import <Network/Network.h>
#import <stdatomic.h>

static _Atomic uint64_t sg_generation;
static NSString *sg_status = @"대기 중";
static SGAddonPreparationState sg_preparation;
static NSDictionary *sg_media;
static NSString *sg_failure; // worker-owned, fixed diagnostics only
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
BOOL SGAddonAddSource(NSString *input) {
    NSURL *url = SGAddonBaseURL(input);
    if (!url) return NO;
    NSMutableArray *sources = [SGAddonSources() mutableCopy];
    if (sources.count >= 8) return NO;
    for (NSDictionary *source in sources) if ([source[@"url"] isEqual:url.absoluteString]) return YES;
    [sources addObject:@{@"id": NSUUID.UUID.UUIDString, @"url": url.absoluteString}];
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
        case SGAddonPreparationSearching: return @"준비 중";
        case SGAddonPreparationAligning: return @"정렬 중";
        case SGAddonPreparationAligned: return @"정렬됨";
        case SGAddonPreparationUnavailable: return @"사용 불가";
        default: return @"대기 중";
    }
}
SGAddonPreparationState SGAddonPreparation(void) { return sg_preparation; }
void SGAddonSetPlaybackUnavailable(void) { sg_preparation = SGAddonPreparationUnavailable; }
void SGAddonSetPlaybackStatus(NSString *status, BOOL aligned) {
    sg_status = status;
    sg_preparation = aligned ? SGAddonPreparationAligned : SGAddonPreparationAligning;
}
NSDictionary *SGAddonMediaInfo(void) { return sg_media ?: @{}; }
void SGAddonCancel(void) {
    atomic_fetch_add(&sg_generation, 1);
    sg_media = nil;
    sg_status = @"대기 중";
    sg_preparation = SGAddonPreparationIdle;
}
void SGAddonRetryCurrentTrack(void) {
    SGAddonCancel();
    [NSNotificationCenter.defaultCenter postNotificationName:SGAddonRetryNotification object:nil];
}

// A bounded request. The worker can cancel while URLSession's delegate writes a file on its own
// serial queue. URLs, HTTP error bodies and provider error strings never reach diagnostics.
@interface SGAddonTransfer : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) NSUInteger limit, received;
@property(nonatomic) BOOL failed;
@property(nonatomic) NSInteger status;
@property(nonatomic, copy) NSString *retryAfter;
@property(nonatomic, strong) NSMutableData *body;
@property(nonatomic, strong) NSFileHandle *file;
@property(nonatomic, strong) dispatch_semaphore_t done;
@end
@implementation SGAddonTransfer
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    self.status = [(NSHTTPURLResponse *)response statusCode];
    self.retryAfter = [(NSHTTPURLResponse *)response valueForHTTPHeaderField:@"Retry-After"];
    self.failed = self.status != 200 || response.expectedContentLength > (int64_t)self.limit;
    completion(self.failed ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (self.failed) return;
    if (data.length > self.limit - self.received) { self.failed = YES; [task cancel]; return; }
    self.received += data.length;
    if (self.file) {
        NSError *error;
        if (![self.file writeData:data error:&error]) { self.failed = YES; [task cancel]; }
    } else [self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) self.failed = YES;
    [self.file closeFile];
    dispatch_semaphore_signal(self.done);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
 newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    // Preserve secrets on addon API calls: no JSON redirects, even to another HTTPS host.
    // Media redirects carry no application auth header; refuse every downgrade.
    BOOL allowed = self.file && [request.URL.scheme.lowercaseString isEqualToString:@"https"] && !request.URL.user && !request.URL.password;
    if (!allowed) self.failed = YES;
    completion(allowed ? request : nil);
}
@end

// All budget/cache state is confined to worker(). Counts include the media request.
static NSMutableDictionary *sg_calls, *sg_quiet, *sg_manifests;
static void initialize(void) {
    if (sg_calls) return;
    sg_calls = [NSMutableDictionary dictionary]; sg_quiet = [NSMutableDictionary dictionary]; sg_manifests = [NSMutableDictionary dictionary];
}
static BOOL budget(NSString *identifier) {
    initialize();
    double now = NSDate.date.timeIntervalSince1970;
    if ([sg_quiet[identifier] doubleValue] > now) return NO;
    NSMutableArray *calls = sg_calls[identifier] ?: [NSMutableArray array];
    [calls filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *at, NSDictionary *bindings) { return at.doubleValue > now - 60; }]];
    sg_calls[identifier] = calls;
    if (calls.count >= 5) return NO;
    [calls addObject:@(now)];
    return YES;
}
static BOOL networkAllowed(void) {
    // Check the current network before every request, including the media download.
    nw_path_monitor_t monitor = nw_path_monitor_create();
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block BOOL allowed = NO;
    __block BOOL received = NO;
    nw_path_monitor_set_queue(monitor, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        if (received) return;
        received = YES;
        allowed = nw_path_get_status(path) == nw_path_status_satisfied &&
            (SGFlag(SGKeyAddonCellular, NO) || (!nw_path_is_expensive(path) && !nw_path_uses_interface_type(path, nw_interface_type_cellular)));
        dispatch_semaphore_signal(ready);
    });
    nw_path_monitor_start(monitor);
    dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    nw_path_monitor_cancel(monitor);
    return allowed;
}
static SGAddonTransfer *fetch(NSURL *url, NSString *path, NSString *identifier, uint64_t generation) {
    if (generation != atomic_load(&sg_generation)) return nil;
    if (!networkAllowed()) { sg_failure = @"네트워크 정책: 비과금 Wi-Fi를 사용하거나 셀룰러 다운로드를 허용하세요"; return nil; }
    if (!budget(identifier)) { sg_failure = @"소스 요청 제한 또는 대기 시간에 도달했습니다. 나중에 다시 시도하세요"; return nil; }
    NSString *reason;
    NSURLSessionConfiguration *config = SGSourceSessionConfiguration(&reason);
    if (!config) { sg_failure = @"WireGuard를 사용할 수 없어 애드온 요청을 차단했습니다"; return nil; } // enabled WireGuard never falls back to a direct session
    config.allowsCellularAccess = SGFlag(SGKeyAddonCellular, NO);
    config.allowsExpensiveNetworkAccess = SGFlag(SGKeyAddonCellular, NO);
    config.allowsConstrainedNetworkAccess = NO;
    SGAddonTransfer *transfer = [SGAddonTransfer new];
    transfer.limit = path ? 128 * 1024 * 1024 : 1024 * 1024;
    transfer.done = dispatch_semaphore_create(0);
    if (path) {
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}];
        transfer.file = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!transfer.file) return nil;
    } else transfer.body = [NSMutableData data];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:transfer delegateQueue:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:path ? @"audio/*,application/octet-stream" : @"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Vitrine/" SG_VERSION " (audio-addon)" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    nw_path_monitor_t monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    BOOL cellular = SGFlag(SGKeyAddonCellular, NO);
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t network) {
        if (!cellular && (nw_path_is_expensive(network) || nw_path_uses_interface_type(network, nw_interface_type_cellular))) [task cancel];
    });
    nw_path_monitor_start(monitor);
    [task resume];
    double deadline = CFAbsoluteTimeGetCurrent() + (path ? 120 : 20);
    while (dispatch_semaphore_wait(transfer.done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10))) {
        if (generation != atomic_load(&sg_generation) || CFAbsoluteTimeGetCurrent() > deadline) [task cancel];
    }
    [session finishTasksAndInvalidate];
    nw_path_monitor_cancel(monitor);
    if (transfer.status == 429) {
        double delay = transfer.retryAfter.doubleValue;
        if (delay <= 0) {
            NSDateFormatter *formatter = [NSDateFormatter new];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
            delay = [[formatter dateFromString:transfer.retryAfter] timeIntervalSinceNow];
        }
        sg_quiet[identifier] = @(NSDate.date.timeIntervalSince1970 + MAX(60, delay));
    }
    if (transfer.failed || !transfer.received) {
        if (transfer.status == 401 || transfer.status == 403) sg_failure = @"소스 인증이 거부되었습니다(401/403). 서비스 설정 페이지에서 개인 manifest 링크를 갱신하세요";
        else if (transfer.status == 429) sg_failure = @"소스 요청이 제한되었습니다(429). Retry-After 대기 중";
        else if (transfer.status) sg_failure = [NSString stringWithFormat:@"소스 HTTP %ld 또는 불완전하거나 너무 큰 응답", (long)transfer.status];
        else sg_failure = @"소스 연결 실패 또는 시간 초과";
    }
    return !transfer.failed && transfer.received && generation == atomic_load(&sg_generation) ? transfer : nil;
}
static NSDictionary *json(NSURL *url, NSString *identifier, uint64_t generation) {
    SGAddonTransfer *response = fetch(url, nil, identifier, generation);
    id value = response ? [NSJSONSerialization JSONObjectWithData:response.body options:0 error:NULL] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
static NSDictionary *manifest(NSDictionary *source, uint64_t generation) {
    initialize();
    NSString *identifier = source[@"id"];
    NSDictionary *cached = sg_manifests[identifier];
    if ([cached[@"until"] doubleValue] > NSDate.date.timeIntervalSince1970) return cached[@"value"];
    NSDictionary *value = json(SGAddonEndpoint(SGAddonBaseURL(source[@"url"]), @[@"manifest.json"], @{}), identifier, generation);
    if (!value) return nil;
    if (!SGAddonManifestSupported(value)) {
        sg_failure = [value[@"bitchordAuth"] isEqual:@YES]
            ? @"공식 BitChord 앱 인증이 필요합니다. Vitrine용으로 허용된 인증 방법이 없어 연결할 수 없습니다."
            : @"지원하지 않는 manifest입니다.";
        return nil;
    }
    sg_manifests[identifier] = @{@"value": value, @"until": @(NSDate.date.timeIntervalSince1970 + 600)};
    return value;
}
void SGAddonTestSource(NSString *identifier, void (^completion)(NSString *)) {
    NSArray *sources = SGAddonSources();
    uint64_t generation = atomic_load(&sg_generation);
    dispatch_async(worker(), ^{
        initialize();
        [sg_manifests removeObjectForKey:identifier];
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
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok ? @"manifest 및 인증 검색에 성공했습니다. 실제 재생에는 음원 매칭, 디코딩, 정렬도 성공해야 합니다." : failure); });
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
    ExtAudioFileDispose(file);
    BOOL flac = format.mFormatID == kAudioFormatFLAC, alac = format.mFormatID == kAudioFormatAppleLossless;
    double seconds = format.mSampleRate > 0 ? frames / format.mSampleRate : 0;
    if (status || (!flac && !alac) || format.mChannelsPerFrame != 2 || seconds <= 0 || (expected > 0 && fabs(seconds - expected) > 30)) return nil;
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
    return @{@"codec": flac ? @"FLAC" : @"ALAC", @"rate": @(format.mSampleRate), @"bits": @(bits),
             @"channels": @(format.mChannelsPerFrame), @"duration": @(seconds),
             @"averageKbps": @([NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL].fileSize * 8.0 / seconds / 1000)};
}
void SGAddonPrepare(NSString *uri, NSString *title, NSString *artist, double duration, void (^completion)(NSString *)) {
    if (!SGFlag(SGKeyAddons, NO) || !SGAddonSources().count) { completion(nil); return; }
    uint64_t generation = atomic_load(&sg_generation);
    NSArray *sources = SGAddonSources();
    sg_status = @"일치하는 녹음 검색 중";
    sg_preparation = SGAddonPreparationSearching;
    dispatch_async(worker(), ^{
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
            if (generation != atomic_load(&sg_generation)) break;
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
            if (!stream || !SGAddonDirectStream(stream)) { if (stream) sg_failure = @"지원하지 않는 스트림입니다. 직접 제공되는 스테레오 FLAC/ALAC가 필요합니다. DASH/HLS/Atmos/DRM은 이 엔진에 연결되지 않았습니다"; continue; }
            // As in BitChord, resolved rendition metadata wins over catalogue hints.
            id expiry = stream[@"expiresAt"];
            if ([expiry respondsToSelector:@selector(doubleValue)] && [expiry doubleValue] <= NSDate.date.timeIntervalSince1970) {
                sg_failure = @"음원 URL이 만료되었습니다. 소스를 갱신하고 다시 시도하세요"; continue;
            }
            if (fetch([NSURL URLWithString:stream[@"url"]], path, source[@"id"], generation)) measured = SGMeasureLosslessFile(path, duration);
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
            sg_failure = sg_failure ?: @"받은 음원이 일치하는 스테레오 FLAC/ALAC 파일이 아닙니다";
            [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        }
        if (!measured || generation != atomic_load(&sg_generation)) { [NSFileManager.defaultManager removeItemAtPath:path error:NULL]; path = nil; }
        NSString *failure = sg_failure ?: @"검증된 파일이 없어 Spotify 오디오를 유지합니다";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == atomic_load(&sg_generation)) {
                sg_media = measured;
                sg_status = path ? @"무손실 헤더 확인됨 · 디코딩 및 정렬 대기 중" : failure;
                sg_preparation = path ? SGAddonPreparationAligning : SGAddonPreparationUnavailable;
                completion(path);
            } else { if (path) [NSFileManager.defaultManager removeItemAtPath:path error:NULL]; completion(nil); }
        });
    });
}
