#import <Foundation/Foundation.h>
#define SGKeySourceWireGuard @"spotifyglass.sources.wireguard"
#define SGKeyAppWireGuard @"spotifyglass.proxy.wireguard"

// One app-local engine, independently selectable for addons or app URLSession traffic.
BOOL SGWireGuardImport(NSString *text, NSString **reason);
BOOL SGWireGuardDelete(void);
BOOL SGWireGuardHasProfile(void);
// Worker thread only. Nil when enabled but unavailable; callers must not go direct.
NSURLSessionConfiguration *SGSourceSessionConfiguration(NSString **reason);
NSDictionary *SGWireGuardStatus(void);
BOOL SGWireGuardApplyToConfiguration(NSURLSessionConfiguration *configuration);
BOOL SGWireGuardAppProxyActive(void);
void SGWireGuardSetAppProxyActive(BOOL active);
NSDictionary *SGWireGuardProxyCounters(void);
void SGWireGuardTestDNS(void (^completion)(NSString *result));
void SGWireGuardTestHTTPS(void (^completion)(NSString *result));
