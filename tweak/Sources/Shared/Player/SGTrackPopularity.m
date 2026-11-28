#import "SGTrackPopularity.h"
#import "Shared/Lyrics/Lyrics.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

@interface SGPopularityLookup : NSObject <NSURLSessionTaskDelegate>
@property(nonatomic, strong) NSCache<NSString *, NSDictionary *> *cache;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, copy) NSString *uri;
@property(nonatomic, strong) NSMutableArray *callbacks;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, strong) NSDate *retryAfter;
@end

@implementation SGPopularityLookup
- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSCache new]; _cache.countLimit = 100;
    }
    return self;
}
- (void)finish:(NSNumber *)value cache:(BOOL)keep {
    NSString *uri = self.uri;
    NSArray *callbacks = [self.callbacks copy];
    self.generation++;
    [self.task cancel]; self.task = nil;
    [self.session invalidateAndCancel]; self.session = nil;
    self.uri = nil; self.callbacks = nil;
    if (keep && uri) [self.cache setObject:@{@"value": value ?: NSNull.null,
        @"until": [NSDate dateWithTimeIntervalSinceNow:value ? 900 : 60]} forKey:uri];
    for (void (^callback)(NSNumber *) in callbacks) callback(value);
}
- (void)request:(NSString *)uri completion:(void (^)(NSNumber *))completion {
    BOOL valid = [uri isKindOfClass:NSString.class] &&
        [uri rangeOfString:@"^spotify:track:[A-Za-z0-9]{22}$" options:NSRegularExpressionSearch].location != NSNotFound;
    if (!valid) { [self finish:nil cache:NO]; completion(nil); return; }
    NSDictionary *kept = [self.cache objectForKey:uri];
    if ([kept[@"until"] timeIntervalSinceNow] > 0) {
        completion([kept[@"value"] isKindOfClass:NSNumber.class] ? kept[@"value"] : nil); return;
    }
    if ([self.uri isEqualToString:uri]) { [self.callbacks addObject:[completion copy]]; return; }
    [self finish:nil cache:NO];
    if (self.retryAfter.timeIntervalSinceNow > 0) { completion(nil); return; }
    self.uri = uri; self.callbacks = [NSMutableArray arrayWithObject:[completion copy]];
    NSUInteger generation = self.generation;
    __weak SGPopularityLookup *weakSelf = self;
    // Bounds both waiting for Spotify's first authenticated request and the network call.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        SGPopularityLookup *lookup = weakSelf;
        if (lookup && lookup.generation == generation) [lookup finish:nil cache:YES];
    });
    SGSpclientHeaders(^(NSDictionary<NSString *,NSString *> *headers) {
        SGPopularityLookup *lookup = weakSelf;
        if (!lookup || lookup.generation != generation) return;
        NSString *authorization = headers[@"authorization"];
        if (![authorization isKindOfClass:NSString.class] || !authorization.length) { [lookup finish:nil cache:YES]; return; }
        NSString *trackID = [uri componentsSeparatedByString:@":"].lastObject;
        NSURL *url = [NSURL URLWithString:[@"https://api.spotify.com/v1/tracks/" stringByAppendingString:trackID]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 8;
        [request setValue:authorization forHTTPHeaderField:@"Authorization"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 8;
        configuration.HTTPShouldSetCookies = NO; configuration.HTTPCookieStorage = nil;
        lookup.session = [NSURLSession sessionWithConfiguration:configuration delegate:lookup delegateQueue:nil];
        lookup.task = [lookup.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
            id json = !error && http.statusCode == 200 && data.length && data.length <= 1024 * 1024 ?
                [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            id raw = [json isKindOfClass:NSDictionary.class] && [json[@"id"] isKindOfClass:NSString.class] &&
                [json[@"id"] isEqualToString:trackID] ? json[@"popularity"] : nil;
            NSNumber *value = nil;
            if ([raw isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)raw) != CFBooleanGetTypeID()) {
                double score = [raw doubleValue];
                if (isfinite(score) && floor(score) == score && score >= 0 && score <= 100) value = @((NSInteger)score);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                SGPopularityLookup *current = weakSelf;
                if (!current || current.generation != generation) return;
                if (http.statusCode == 429) {
                    NSString *header = [http valueForHTTPHeaderField:@"Retry-After"];
                    double seconds = header.doubleValue;
                    if (seconds <= 0 && header.length) {
                        NSDateFormatter *formatter = [NSDateFormatter new];
                        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                        formatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss z";
                        seconds = [[formatter dateFromString:header] timeIntervalSinceNow];
                    }
                    current.retryAfter = [NSDate dateWithTimeIntervalSinceNow:MAX(60, seconds)];
                }
                [current finish:value cache:YES];
            });
        }];
        [lookup.task resume];
    });
}
// Never forward the Authorization header through an unexpected redirect.
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

// Main-queue scheduler shared by visible rows and the current player. Limit traffic,
// coalesce duplicate tracks, and keep successful scores for fifteen minutes.
static NSMutableDictionary<NSString *, NSMutableDictionary *> *jobs;
static NSMutableArray<NSString *> *waiting;
static NSCache<NSString *, NSDictionary *> *answers;
static NSDate *quietUntil;
static NSUInteger activeCount;
static BOOL cancelling;
static void pump(void);

static void prepare(void) {
    if (jobs) return;
    jobs = [NSMutableDictionary dictionary]; waiting = [NSMutableArray array];
    answers = [NSCache new]; answers.countLimit = 200;
}
static void pump(void) {
    if (cancelling || quietUntil.timeIntervalSinceNow > 0) return;
    while (activeCount < 2 && waiting.count) {
        NSString *uri = waiting.firstObject; [waiting removeObjectAtIndex:0];
        NSMutableDictionary *job = jobs[uri];
        if (!job) continue;
        SGPopularityLookup *worker = [SGPopularityLookup new];
        job[@"worker"] = worker; activeCount++;
        [worker request:uri completion:^(NSNumber *value) {
            if (jobs[uri] != job) return;
            NSArray *callbacks = [job[@"callbacks"] copy];
            [jobs removeObjectForKey:uri]; activeCount--;
            [answers setObject:@{@"value": value ?: NSNull.null,
                @"until": [NSDate dateWithTimeIntervalSinceNow:value ? 900 : 60]} forKey:uri];
            if (worker.retryAfter.timeIntervalSinceNow > 0) {
                quietUntil = worker.retryAfter;
                NSArray *queued = [waiting copy]; [waiting removeAllObjects];
                for (NSString *other in queued) {
                    NSArray *skipped = [jobs[other][@"callbacks"] copy];
                    [jobs removeObjectForKey:other];
                    for (void (^callback)(NSNumber *) in skipped) callback(nil);
                }
            }
            for (void (^callback)(NSNumber *) in callbacks) callback(value);
            pump();
        }];
    }
}
void SGTrackPopularityRequest(NSString *uri, void (^completion)(NSNumber *)) {
    if (!completion) return;
    NSCAssert(NSThread.isMainThread, @"Popularity lookup must run on main");
    prepare();
    if (![uri isKindOfClass:NSString.class] ||
        [uri rangeOfString:@"^spotify:track:[A-Za-z0-9]{22}$" options:NSRegularExpressionSearch].location == NSNotFound) {
        completion(nil); return;
    }
    NSDictionary *answer = [answers objectForKey:uri];
    if ([answer[@"until"] timeIntervalSinceNow] > 0) {
        completion([answer[@"value"] isKindOfClass:NSNumber.class] ? answer[@"value"] : nil); return;
    }
    if (quietUntil.timeIntervalSinceNow > 0) { completion(nil); return; }
    if (jobs[uri]) { [jobs[uri][@"callbacks"] addObject:[completion copy]]; return; }
    if (jobs.count >= 40) { completion(nil); return; }
    jobs[uri] = [@{@"callbacks": [NSMutableArray arrayWithObject:[completion copy]]} mutableCopy];
    [waiting addObject:uri]; pump();
}
void SGTrackPopularityCancel(void) {
    NSCAssert(NSThread.isMainThread, @"Popularity lookup must run on main");
    cancelling = YES;
    NSArray *old = [jobs.allValues copy]; [jobs removeAllObjects]; [waiting removeAllObjects]; activeCount = 0;
    for (NSDictionary *job in old) {
        [(SGPopularityLookup *)job[@"worker"] finish:nil cache:NO];
        for (void (^callback)(NSNumber *) in job[@"callbacks"]) callback(nil);
    }
    cancelling = NO;
}
