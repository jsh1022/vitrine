// App URLSession traffic is independent of lossless playback and addon settings.
// Public Foundation factories cover Spotify's evidenced SPTDataLoaderService,
// Connectivity_HttpClientKit and SPTCoreURLSessionDataDelegate paths. This does
// not intercept raw sockets, Connect discovery or another process's WebKit traffic.
#import "Core/SGCore.h"
#import "Shared/AudioSources/SGWireGuard.h"
#import <stdatomic.h>

static _Atomic uint64_t sg_configured, sg_blocked;

@interface SGWireGuardBlockedProtocol : NSURLProtocol
@end
@implementation SGWireGuardBlockedProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    return [@[@"http", @"https", @"ws", @"wss"] containsObject:request.URL.scheme.lowercaseString ?: @""];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
}
- (void)stopLoading {}
@end

static NSURLSessionConfiguration *configure(NSURLSessionConfiguration *original) {
    if (!SGWireGuardAppProxyActive() || !original) return original;
    NSURLSessionConfiguration *config = [original copy];
    BOOL ok = NO;
    @try { ok = SGWireGuardApplyToConfiguration(config); } @catch (NSException *exception) { ok = NO; }
    if (ok) {
        NSMutableArray *protocols = [config.protocolClasses mutableCopy];
        [protocols removeObject:SGWireGuardBlockedProtocol.class];
        config.protocolClasses = protocols;
        atomic_fetch_add(&sg_configured, 1);
    }
    else {
        atomic_fetch_add(&sg_blocked, 1);
        @try {
            SEL setter = NSSelectorFromString(@"setProxyConfigurations:");
            if ([config respondsToSelector:setter]) [config setValue:@[] forKey:@"proxyConfigurations"];
        } @catch (NSException *exception) {}
        // Also close the proxy route for consumers that ignore custom URL protocols.
        // A missing profile or engine is never a reason to return a direct config.
        config.connectionProxyDictionary = @{@"HTTPEnable": @1, @"HTTPProxy": @"127.0.0.1", @"HTTPPort": @1,
            @"HTTPSEnable": @1, @"HTTPSProxy": @"127.0.0.1", @"HTTPSPort": @1,
            @"SOCKSEnable": @1, @"SOCKSProxy": @"127.0.0.1", @"SOCKSPort": @1};
        // Background sessions reject custom URLProtocols; keep their closed proxy route.
        if (!config.identifier.length) {
            NSMutableArray *protocols = [config.protocolClasses mutableCopy] ?: [NSMutableArray array];
            if (![protocols containsObject:SGWireGuardBlockedProtocol.class]) [protocols insertObject:SGWireGuardBlockedProtocol.class atIndex:0];
            config.protocolClasses = protocols;
        }
    }
    return config;
}
NSDictionary *SGWireGuardProxyCounters(void) {
    return @{@"configurations": @(atomic_load(&sg_configured)), @"blockedConfigurations": @(atomic_load(&sg_blocked))};
}

%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration { return configure(%orig); }
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration { return configure(%orig); }
+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier { return configure(%orig); }
%end

%hook NSURLSession
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    return %orig(configure(configuration));
}
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id)delegate delegateQueue:(NSOperationQueue *)queue {
    return %orig(configure(configuration), delegate, queue);
}
+ (NSURLSession *)sharedSession {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration]; });
    return session;
}
%end

%hook NSMutableURLRequest
- (void)setAssumesHTTP3Capable:(BOOL)value { %orig(NO); }
%end
%hook NSURLRequest
- (BOOL)assumesHTTP3Capable { return NO; }
%end

%ctor {
    BOOL active = SGFlag(SGKeyAppWireGuard, NO);
    SGWireGuardSetAppProxyActive(active);
    if (!active) return;
    %init;
    // Starts the engine asynchronously; no Go entry or network wait on this constructor.
    (void)NSURLSessionConfiguration.ephemeralSessionConfiguration;
}
