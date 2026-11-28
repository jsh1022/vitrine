#import <Foundation/Foundation.h>

// Main queue only. A server-confirmed integer from 0 to 100, or nil when unavailable.
// Requests are deduplicated and limited to two concurrent lookups; no token is persisted or logged.
void SGTrackPopularityRequest(NSString *uri, void (^completion)(NSNumber *value));
void SGTrackPopularityCancel(void);
