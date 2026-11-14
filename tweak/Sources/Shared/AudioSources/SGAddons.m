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
static NSString *sg_status = @"Idle";
static NSString *sg_summary = @"Idle";
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
    return SGLosslessRendering() ? @"Playing" : sg_summary;
}
void SGAddonSetPlaybackStatus(NSString *status, BOOL aligned) {
    sg_status = status;
    sg_summary = aligned ? @"Aligned" : @"Not aligned";
}
NSDictionary *SGAddonMediaInfo(void) { return sg_media ?: @{}; }
void SGAddonCancel(void) {
    atomic_fetch_add(&sg_generation, 1);
    sg_media = nil;
    sg_status = @"Idle";
    sg_summary = @"Idle";
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
    if (!networkAllowed()) { sg_failure = @"Network policy: use unmetered Wi-Fi or allow cellular downloads"; return nil; }
    if (!budget(identifier)) { sg_failure = @"Source request budget/cooldown reached; retry later"; return nil; }
    NSString *reason;
    NSURLSessionConfiguration *config = SGSourceSessionConfiguration(&reason);
    if (!config) { sg_failure = @"WireGuard unavailable; addon request blocked"; return nil; } // enabled WireGuard never falls back to a direct session
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
        if (transfer.status == 401 || transfer.status == 403) sg_failure = @"Source authentication refused (401/403). Renew the personal manifest URL on its setup page";
        else if (transfer.status == 429) sg_failure = @"Source rate limited (429); waiting for Retry-After";
        else if (transfer.status) sg_failure = [NSString stringWithFormat:@"Source HTTP %ld or incomplete/oversized response", (long)transfer.status];
        else sg_failure = @"Source connection failed or timed out";
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
    if (!value || !SGAddonManifestSupported(value)) return nil;
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
        NSString *failure = sg_failure ?: @"Unsupported manifest or search response";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok ? @"Manifest and authenticated search work. Playback matching, media decoding and alignment still need to succeed." : failure); });
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
    sg_status = @"Looking for a matching recording";
    sg_summary = @"Preparing";
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
            if (!candidate) { sg_failure = @"Search answered but no recording matched title, artist and duration"; continue; }
            NSDictionary *stream = nil;
            // BitChord resolves /stream first; a row URL is only a fallback.
            if ([candidate[@"id"] isKindOfClass:NSString.class] && [candidate[@"id"] length])
                stream = json(SGAddonEndpoint(base, @[@"stream", candidate[@"id"]], SGAddonParameters(m)), source[@"id"], generation);
            if (![stream[@"url"] isKindOfClass:NSString.class] && [candidate[@"streamURL"] isKindOfClass:NSString.class]) {
                NSMutableDictionary *fallback = [candidate mutableCopy];
                fallback[@"url"] = candidate[@"streamURL"]; stream = fallback;
            }
            if (!stream || !SGAddonDirectStream(stream)) { if (stream) sg_failure = @"Unsupported stream: need direct stereo FLAC/ALAC (DASH/HLS/Atmos/DRM are not connected to this engine)"; continue; }
            // As in BitChord, resolved rendition metadata wins over catalogue hints.
            id expiry = stream[@"expiresAt"];
            if ([expiry respondsToSelector:@selector(doubleValue)] && [expiry doubleValue] <= NSDate.date.timeIntervalSince1970) {
                sg_failure = @"Resolved media URL expired; renew the source and retry"; continue;
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
            sg_failure = sg_failure ?: @"Downloaded media is not a matching stereo FLAC/ALAC file";
            [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        }
        if (!measured || generation != atomic_load(&sg_generation)) { [NSFileManager.defaultManager removeItemAtPath:path error:NULL]; path = nil; }
        NSString *failure = sg_failure ?: @"No verified file; Spotify continues";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == atomic_load(&sg_generation)) {
                sg_media = measured;
                sg_status = path ? @"Lossless header checked; waiting for decode and alignment" : failure;
                sg_summary = path ? @"Aligning" : @"Unavailable";
                completion(path);
            } else { if (path) [NSFileManager.defaultManager removeItemAtPath:path error:NULL]; completion(nil); }
        });
    });
}
