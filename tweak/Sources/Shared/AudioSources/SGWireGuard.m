#import "SGWireGuard.h"
#import "SGSourceSecrets.h"
#import "Core/SGPrefs.h"
#import <Network/Network.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <stdatomic.h>

#if SG_WIREGUARD
#import "libytmuwg.h"
#endif

static NSLock *lock(void) {
    static NSLock *l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [NSLock new]; });
    return l;
}
static NSString *sg_reason = @"시작 전";
static atomic_bool sg_appActive;
BOOL SGWireGuardAppProxyActive(void) { return atomic_load(&sg_appActive); }
void SGWireGuardSetAppProxyActive(BOOL active) { atomic_store(&sg_appActive, active); }


#if SG_WIREGUARD
static NSString *sg_user, *sg_password;
static int sg_port;
static BOOL sg_failed;
static BOOL sg_ready;
static dispatch_queue_t engineQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.wireguard", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
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
    if (![result[@"ok"] boolValue]) { *reason = @"유효하지 않거나 지원하지 않는 WireGuard 프로필입니다."; return NO; }
    if (![lock() tryLock]) { *reason = @"WireGuard 시작 중입니다. 프로필을 교체하기 전에 기다리세요."; return NO; }
    BOOL running = sg_port > 0;
    BOOL ok = SGSaveSourceSecret(@"wireguard-profile", text);
    if (ok && running) sg_reason = @"프로필을 갱신했습니다. 새 구성을 적용하려면 재시작하세요";
    [lock() unlock];
    if (!ok) *reason = @"Keychain에 프로필을 저장하지 못했습니다.";
    return ok;
#else
    *reason = @"이 빌드에는 WireGuard가 없습니다. WIREGUARD=1로 빌드하세요.";
    return NO;
#endif
}
BOOL SGWireGuardDelete(void) {
    // Active engine retains its profile until process exit; the UI explains the restart.
    return SGSaveSourceSecret(@"wireguard-profile", nil);
}

BOOL SGWireGuardApplyToConfiguration(NSURLSessionConfiguration *config) {
#if SG_WIREGUARD
    static dispatch_once_t observe;
    dispatch_once(&observe, ^{
        // Notifications may arrive on any thread. Never make the posting thread wait on main.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(engineQueue(), ^{
                [lock() lock];
                BOOL ready = sg_ready;
                [lock() unlock];
                if (ready) YTMUWGRebind();
            });
        }];
        static nw_path_monitor_t monitor;
        static NSString *previous;
        monitor = nw_path_monitor_create();
        nw_path_monitor_set_queue(monitor, engineQueue());
        nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
            NSString *signature = [NSString stringWithFormat:@"%d:%d:%d:%d", (int)nw_path_get_status(path),
                nw_path_uses_interface_type(path, nw_interface_type_wifi),
                nw_path_uses_interface_type(path, nw_interface_type_cellular),
                nw_path_uses_interface_type(path, nw_interface_type_wired)];
            BOOL changed = previous && ![previous isEqualToString:signature];
            previous = signature;
            [lock() lock]; BOOL ready = sg_ready; [lock() unlock];
            if (ready && changed && nw_path_get_status(path) == nw_path_status_satisfied) YTMUWGRebind();
        });
        nw_path_monitor_start(monitor);
    });
#endif
    [lock() lock];
    BOOL result = NO;
    @try {
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
        sg_reason = @"WireGuard에는 iOS 17 이상이 필요합니다";
    } else {
        if (sg_port <= 0 && !sg_failed) {
            NSString *profile = SGSourceSecret(@"wireguard-profile");
            if (profile.length) {
                // Reserve the authenticated proxy's port immediately. Never enter Go or wait
                // for peer DNS on the UI thread or from a dylib constructor.
                int fd = socket(AF_INET, SOCK_STREAM, 0);
                struct sockaddr_in address = {0};
                address.sin_len = sizeof address;
                address.sin_family = AF_INET;
                address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                socklen_t length = sizeof address;
                if (fd >= 0 && !bind(fd, (struct sockaddr *)&address, sizeof address) &&
                    !listen(fd, 256) && !getsockname(fd, (struct sockaddr *)&address, &length)) {
                    sg_port = ntohs(address.sin_port);
                    sg_user = NSUUID.UUID.UUIDString;
                    sg_password = NSUUID.UUID.UUIDString;
                    NSString *user = sg_user, *password = sg_password;
                    int expected = sg_port;
                    sg_reason = @"WireGuard 시작 중";
                    dispatch_async(engineQueue(), ^{
                        // YTMUWGStart consumes fd on success and on every error path.
                        int port = YTMUWGStart((char *)profile.UTF8String, (char *)user.UTF8String,
                                             (char *)password.UTF8String, fd, expected);
                        [lock() lock];
                        sg_failed = port != expected;
                        sg_ready = !sg_failed;
                        sg_reason = sg_failed ? @"WireGuard 실패 · 프로필을 확인한 후 재시작하세요" : @"프록시 준비됨 · 핸드셰이크를 확인하거나 터널 DNS를 검사하세요";
                        [lock() unlock];
                    });
                } else {
                    if (fd >= 0) close(fd);
                    sg_failed = YES;
                    sg_reason = @"로컬 프록시를 확보하지 못했습니다";
                }
            } else sg_reason = @"먼저 프로필을 가져온 후 Spotify를 재시작하세요";
        }
        if (sg_port > 0 && !sg_failed) {
            nw_endpoint_t endpoint = nw_endpoint_create_host("127.0.0.1", @(sg_port).stringValue.UTF8String);
            id proxy = endpoint ? (__bridge_transfer id)create((__bridge void *)endpoint) : nil;
            if (proxy) {
                credentials((__bridge void *)proxy, sg_user.UTF8String, sg_password.UTF8String);
                failover((__bridge void *)proxy, false);
                config.connectionProxyDictionary = nil;
                ((void (*)(id, SEL, id))objc_msgSend)(config, setter, @[proxy]);
                id applied = ((id (*)(id, SEL))objc_msgSend)(config, getter);
                if ([applied isKindOfClass:NSArray.class] && [applied count] == 1 &&
                    !getFailover((__bridge void *)[applied firstObject])) result = YES;
            }
        }
    }
#else
    sg_reason = @"이 빌드에는 WireGuard가 없습니다";
#endif
    } @catch (NSException *exception) {
        sg_reason = @"이 URLSession 구성에서 프록시를 사용하지 못했습니다";
        result = NO;
    } @finally {
        [lock() unlock];
    }
    return result;
}
NSDictionary *SGWireGuardStatus(void) {
    if (![lock() tryLock]) return @{@"state": @"시작 또는 복구 중"};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"state"] = sg_reason;
    result[@"appActive"] = @(SGWireGuardAppProxyActive());
#if SG_WIREGUARD
    if (sg_ready) result[@"engine"] = readJSON(YTMUWGStatus());
#endif
    [lock() unlock];
    return result;
}

NSURLSessionConfiguration *SGSourceSessionConfiguration(NSString **reason) {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.URLCache = nil; config.HTTPCookieStorage = nil; config.URLCredentialStorage = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 120;
    if (!SGFlag(SGKeySourceWireGuard, NO) && !SGWireGuardAppProxyActive()) return config;
    if (SGWireGuardApplyToConfiguration(config)) return config;
    *reason = @"WireGuard를 사용할 수 없어 애드온 요청을 차단했습니다.";
    return nil;
}
void SGWireGuardTestDNS(void (^completion)(NSString *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        BOOL ready = SGWireGuardApplyToConfiguration(config);
        BOOL ok = NO;
#if SG_WIREGUARD
        if (ready) {
            // Engine startup is asynchronous; wait only on this worker, never on UI.
            for (int i = 0; i < 150; i++) {
                [lock() lock]; BOOL started = sg_ready, failed = sg_failed; [lock() unlock];
                if (failed) break;
                if (started) { ok = [readJSON(YTMUWGLookup("api.spotify.com"))[@"ok"] boolValue]; break; }
                usleep(100000);
            }
        }
#else
        (void)ready;
#endif
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(ok ? @"터널 DNS 검사에 성공하여 피어 및 DNS 경로를 확인했습니다. URLSession 라우팅은 요청 카운터에서 확인하세요." : @"터널 DNS 검사에 실패했습니다. 프로필, 엔드포인트, DNS 및 네트워크를 확인한 후 Spotify를 재시작하세요. 직접 연결로 우회하지 않았습니다.");
        });
    });
}

void SGWireGuardTestHTTPS(void (^completion)(NSString *)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.URLCache = nil; config.HTTPCookieStorage = nil;
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30;
        if (!SGWireGuardApplyToConfiguration(config)) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@"터널을 사용할 수 없어 HTTPS 검사를 차단했습니다. 직접 연결로 우회하지 않습니다."); });
            return;
        }
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
        // Explicit user action: the selected tunnel contacts Cloudflare's trace endpoint.
        [[session dataTaskWithURL:[NSURL URLWithString:@"https://www.cloudflare.com/cdn-cgi/trace"] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *result = @"터널 HTTPS 검사에 실패했습니다. 직접 연결로 우회하지 않았습니다.";
            if (!error && [(NSHTTPURLResponse *)response statusCode] == 200 && data.length < 65536) {
                NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                NSString *ip = nil, *country = nil;
                for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
                    if ([line hasPrefix:@"ip="]) ip = [line substringFromIndex:3];
                    if ([line hasPrefix:@"loc="]) country = [line substringFromIndex:4];
                }
                if (ip.length && ip.length < 64 && country.length == 2)
                    result = [NSString stringWithFormat:@"터널 HTTPS 검사 성공. 출구 IP: %@ · 국가: %@. 터널의 URLSession 경로를 확인한 결과이며 Spotify 음악 로더 전체를 검증한 것은 아닙니다.", ip, country];
            }
            [session finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }] resume];
    });
}
