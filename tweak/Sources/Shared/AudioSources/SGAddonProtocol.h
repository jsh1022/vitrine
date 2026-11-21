#import <Foundation/Foundation.h>

// HTTP JSON only: no downloaded provider code or embedded hosted endpoints.
NSURL *SGAddonBaseURL(NSString *input);
NSURL *SGAddonEndpoint(NSURL *base, NSArray<NSString *> *segments, NSDictionary<NSString *, NSString *> *query);
BOOL SGAddonManifestSupported(NSDictionary *manifest);
NSDictionary *SGAddonParameters(NSDictionary *manifest);
BOOL SGAddonTrackMatches(NSDictionary *candidate, NSString *title, NSString *artist, double seconds);
BOOL SGAddonDirectStream(NSDictionary *stream);
BOOL SGAddonStreamSupported(NSDictionary *stream);
