#import <Foundation/Foundation.h>

// Pure, bounded manifest parsing. No URLSession/AVPlayer may fetch a manifest's URLs itself.
// Returns {playlist: NSURL} or {parts: [{url: NSURL, range?: NSValue}], duration: NSNumber}.
// nil means malformed, encrypted, live or unsupported; never return provider text in diagnostics.
NSDictionary *SGAddonSegmentPlan(NSData *data, NSURL *base, NSString *transport);
NSString *SGAddonStreamTransport(NSDictionary *stream);
