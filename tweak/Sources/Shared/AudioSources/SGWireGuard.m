#import "SGWireGuard.h"
#import "SGSourceSecrets.h"
#import "Core/SGPrefs.h"
#import <Network/Network.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>

#if SG_WIREGUARD
#import "libytmuwg.h"
#endif

static NSLock *lock(void) {
    static NSLock *l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [NSLock new]; });
    return l;
}
static NSString *sg_reason = @"Not started";

#if SG_WIREGUARD
static NSString *sg_user, *sg_password;
static int sg_port;
static NSDictionary *readJSON(char *text) {
    if (!text) return @{};
    NSData *data = [[NSString stringWithUTF8String:text] dataUsingEncoding:NSUTF8StringEncoding];
    YTMUWGFree(text);
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [result isKindOfClass:NSDictionary.class] ? result : @{};
}
#endif

BOOL SGWireGuardHasProfile(void) { return SGSourceSecret(@"wireguard-profile").length > 0; }
BOOL SGWireGuardImport(NSString *text, NSString **reason) {
#if SG_WIREGUARD
    NSDictionary *result = readJSON(YTMUWGInspect((char *)text.UTF8String));
    if (![result[@"ok"] boolValue]) { *reason = @"Invalid or unsupported WireGuard profile."; return NO; }
    if (![lock() tryLock]) { *reason = @"WireGuard is starting. Wait before replacing the profile."; return NO; }
    BOOL running = sg_port > 0;
    BOOL ok = !running && SGSaveSourceSecret(@"wireguard-profile", text);
    [lock() unlock];
    if (!ok) *reason = running ? @"Restart Spotify with WireGuard off before replacing the profile." : @"Keychain could not save the profile.";
    return ok;
#else
    *reason = @"This build does not include WireGuard. Build with WIREGUARD=1.";
    return NO;
#endif
}
BOOL SGWireGuardDelete(void) {
    // Active engine retains its profile until process exit; the UI explains the restart.
    return SGSaveSourceSecret(@"wireguard-profile", nil);
}

NSURLSessionConfiguration *SGSourceSessionConfiguration(NSString **reason) {
#if SG_WIREGUARD
    static dispatch_once_t observe;
    dispatch_once(&observe, ^{
        // Notifications may arrive on any thread. Never make the posting thread wait on main.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [lock() lock];
                if (sg_port > 0) YTMUWGRebind();
                [lock() unlock];
            });
        }];
    });
#endif
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache = nil;
    config.HTTPCookieStorage = nil;
    config.URLCredentialStorage = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = 20;
    config.timeoutIntervalForResource = 120;
    if (!SGFlag(SGKeySourceWireGuard, NO)) return config;
    [lock() lock];
    NSURLSessionConfiguration *result = nil;
#if SG_WIREGUARD
    // Resolve the public iOS 17 proxy APIs dynamically so iOS 16 remains loadable.
    typedef void *(*Create)(void *);
    typedef void (*Credentials)(void *, const char *, const char *);
    typedef void (*Failover)(void *, bool);
    typedef bool (*GetFailover)(void *);
    Create create = (Create)dlsym(RTLD_DEFAULT, "nw_proxy_config_create_socksv5");
    Credentials credentials = (Credentials)dlsym(RTLD_DEFAULT, "nw_proxy_config_set_username_and_password");
    Failover failover = (Failover)dlsym(RTLD_DEFAULT, "nw_proxy_config_set_failover_allowed");
    GetFailover getFailover = (GetFailover)dlsym(RTLD_DEFAULT, "nw_proxy_config_get_failover_allowed");
    SEL setter = NSSelectorFromString(@"setProxyConfigurations:");
    SEL getter = NSSelectorFromString(@"proxyConfigurations");
    if (!create || !credentials || !failover || !getFailover || ![config respondsToSelector:setter] || ![config respondsToSelector:getter]) {
        sg_reason = @"WireGuard requires iOS 17 or later. Addon requests blocked.";
    } else {
        if (sg_port <= 0) {
            NSString *profile = SGSourceSecret(@"wireguard-profile");
            if (profile.length) {
                sg_user = NSUUID.UUID.UUIDString;
                sg_password = NSUUID.UUID.UUIDString;
                sg_port = YTMUWGStart((char *)profile.UTF8String, (char *)sg_user.UTF8String,
                                     (char *)sg_password.UTF8String, -1, 0);
            }
            sg_reason = sg_port > 0 ? @"Proxy ready; handshake not yet verified" : @"WireGuard unavailable. Addon requests blocked.";
        }
        if (sg_port > 0) {
            nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", @(sg_port).stringValue.UTF8String);
            id proxy = endpoint ? (__bridge_transfer id)create((__bridge void *)endpoint) : nil;
            if (proxy) {
                credentials((__bridge void *)proxy, sg_user.UTF8String, sg_password.UTF8String);
                failover((__bridge void *)proxy, false);
                ((void (*)(id, SEL, id))objc_msgSend)(config, setter, @[proxy]);
                id applied = ((id (*)(id, SEL))objc_msgSend)(config, getter);
                if ([applied isKindOfClass:NSArray.class] && [applied count] == 1 &&
                    !getFailover((__bridge void *)[applied firstObject])) result = config;
            }
        }
    }
#else
    sg_reason = @"WireGuard not included in this build. Addon requests blocked.";
#endif
    if (!result) *reason = @"WireGuard unavailable. Addon requests blocked.";
    [lock() unlock];
    return result;
}
NSDictionary *SGWireGuardStatus(void) {
    if (![lock() tryLock]) return @{@"state": @"Starting or recovering"};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"state"] = SGFlag(SGKeySourceWireGuard, NO) ? sg_reason : @"Off";
#if SG_WIREGUARD
    if (sg_port > 0) result[@"engine"] = readJSON(YTMUWGStatus());
#endif
    [lock() unlock];
    return result;
}
