#import <Foundation/Foundation.h>
#define SGKeySourceWireGuard @"spotifyglass.sources.wireguard"

// App-local tunnel for addon JSON and audio only. Never hooks Spotify sessions.
BOOL SGWireGuardImport(NSString *text, NSString **reason);
BOOL SGWireGuardDelete(void);
BOOL SGWireGuardHasProfile(void);
// Worker thread only. Nil when enabled but unavailable; callers must not go direct.
NSURLSessionConfiguration *SGSourceSessionConfiguration(NSString **reason);
NSDictionary *SGWireGuardStatus(void);
