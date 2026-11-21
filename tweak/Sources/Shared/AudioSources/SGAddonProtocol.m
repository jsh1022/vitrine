#import "SGAddonProtocol.h"
#import "SGAddonSegments.h"
#import <math.h>

static NSString *string(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
NSURL *SGAddonBaseURL(NSString *input) {
    NSURLComponents *c = [NSURLComponents componentsWithString:[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    // HTTPS also for private servers: no global ATS exceptions or credential-bearing HTTP links.
    if (![c.scheme.lowercaseString isEqualToString:@"https"] || !c.host.length || c.user || c.password || c.fragment) return nil;
    NSString *path = c.percentEncodedPath;
    while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    if ([path.lowercaseString hasSuffix:@".json"]) path = [path substringToIndex:[path rangeOfString:@"/" options:NSBackwardsSearch].location];
    if ([path.lowercaseString hasSuffix:@".html"] || [path.lowercaseString hasSuffix:@".htm"]) return nil;
    c.percentEncodedPath = path;
    return c.URL;
}
NSURL *SGAddonEndpoint(NSURL *base, NSArray<NSString *> *segments, NSDictionary<NSString *, NSString *> *query) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:base resolvingAgainstBaseURL:NO];
    NSString *path = c.percentEncodedPath ?: @"";
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    for (NSString *part in segments) path = [path stringByAppendingFormat:@"/%@", [part stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
    c.percentEncodedPath = path;
    NSMutableArray *items = [c.queryItems mutableCopy] ?: [NSMutableArray array];
    for (NSString *key in query) {
        // Explicit client policy replaces a conflicting base query parameter.
        NSIndexSet *old = [items indexesOfObjectsPassingTest:^BOOL(NSURLQueryItem *item, NSUInteger i, BOOL *stop) { return [item.name isEqualToString:key]; }];
        [items removeObjectsAtIndexes:old];
        [items addObject:[NSURLQueryItem queryItemWithName:key value:query[key]]];
    }
    NSMutableArray *encoded = [NSMutableArray array];
    for (NSURLQueryItem *item in items) [encoded addObject:[NSString stringWithFormat:@"%@=%@",
        [item.name stringByAddingPercentEncodingWithAllowedCharacters:allowed],
        [(item.value ?: @"") stringByAddingPercentEncodingWithAllowedCharacters:allowed]]];
    c.percentEncodedQuery = encoded.count ? [encoded componentsJoinedByString:@"&"] : nil;
    return c.URL;
}
BOOL SGAddonManifestSupported(NSDictionary *m) {
    id resources = m[@"resources"];
    // Like BitChord iOS, try the supplied URL even when bitchordAuth is declared.
    // The flag grants no credentials: the server still decides access (401/403).
    if (!string(m[@"id"]).length) return NO;
    if (!resources) return YES;
    return [resources isKindOfClass:NSArray.class] && (![resources count] || [resources containsObject:@"search"]);
}
NSDictionary *SGAddonParameters(NSDictionary *m) {
    NSMutableDictionary *result = [@{@"quality": @"LOSSLESS"} mutableCopy];
    id settings = m[@"settings"];
    if (![settings isKindOfClass:NSArray.class]) return result;
    for (id raw in settings) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSString *key = string(raw[@"key"]);
        if ([key isEqualToString:@"atmos"]) result[key] = @"false";
        id value = raw[@"default"];
        if (key.length && ![@[@"quality", @"atmos", @"q"] containsObject:key] &&
            ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class])) result[key] = [value description];
        if ([key isEqualToString:@"quality"] && [raw[@"options"] isKindOfClass:NSArray.class]) {
            NSString *exact = nil;
            for (id option in raw[@"options"]) {
                NSString *v = [option isKindOfClass:NSDictionary.class] ? string(option[@"value"]) : string(option);
                if ([v.lowercaseString isEqualToString:@"lossless"]) { exact = v; break; }
            }
            if (exact) { result[@"quality"] = exact; continue; }
            for (id option in raw[@"options"]) {
                NSString *v = [option isKindOfClass:NSDictionary.class] ? string(option[@"value"]) : string(option);
                if ([@[@"lossless", @"flac", @"hifi", @"hi-res", @"hires", @"max", @"best"] containsObject:v.lowercaseString]) {
                    result[@"quality"] = v; break;
                }
            }
        }
    }
    return result;
}
static NSString *fold(NSString *s) {
    NSString *value = [s stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSWidthInsensitiveSearch | NSDiacriticInsensitiveSearch locale:[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]];
    return [[value componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
}
static NSSet *artists(NSString *text) {
    NSString *value = [text.lowercaseString stringByReplacingOccurrencesOfString:@" feat. " withString:@","];
    NSMutableSet *names = [NSMutableSet set];
    for (NSString *part in [value componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",;&"]]) {
        NSString *name = fold(part); if (name.length) [names addObject:name];
    }
    return names;
}
BOOL SGAddonTrackMatches(NSDictionary *c, NSString *title, NSString *artist, double seconds) {
    id length = c[@"duration"];
    BOOL hasDuration = [length isKindOfClass:NSNumber.class] || [length isKindOfClass:NSString.class];
    double duration = hasDuration ? [length doubleValue] : 0;
    // BitChord TrackMatcher.durationLimitSec is 30. Missing metadata is checked
    // against the actual completed file, then against Spotify's audio waveform.
    BOOL lengthMatches = !hasDuration || (isfinite(duration) && duration > 0 && fabs(duration - seconds) <= 30);
    return title.length && artist.length && isfinite(seconds) && seconds > 0 && lengthMatches && [fold(string(c[@"title"])) isEqualToString:fold(title)] &&
        [artists(string(c[@"artist"])) intersectsSet:artists(artist)];
}
BOOL SGAddonStreamSupported(NSDictionary *s) {
    NSURL *url = [NSURL URLWithString:string(s[@"url"])];
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length || url.user || url.password) return NO;
    for (NSString *key in @[@"codec", @"format", @"mimeType"]) {
        NSString *value = string(s[key]).lowercaseString;
        if ([@[@"mp3", @"aac", @"he-aac", @"he-aac-v2", @"audio/mpeg", @"audio/aac", @"audio/aacp"] containsObject:value] || [value hasPrefix:@"mp4a"]) return NO;
    }
    id encrypted = s[@"encrypted"];
    if (encrypted == NSNull.null) encrypted = nil;
    if ([encrypted isKindOfClass:NSString.class]) encrypted = [encrypted stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (encrypted && ![encrypted isEqual:@NO] && ![encrypted isEqual:@"false"] && ![encrypted isEqual:@"none"] && ![encrypted isEqual:@""]) return NO;
    for (NSString *key in @[@"manifest", @"mediaType"]) {
        NSString *v = string(s[key]).lowercaseString;
        if (v.length && ![v isEqualToString:@"none"] && !SGAddonStreamTransport(@{key:v})) return NO;
    }
    if ([s[@"atmos"] isEqual:@YES]) return NO;
    id modes = s[@"audioModes"];
    if ([modes isKindOfClass:NSArray.class]) for (id mode in modes) {
        NSString *v = string(mode).lowercaseString;
        if ([v containsString:@"atmos"] || [v containsString:@"dolby"]) return NO;
    }
    for (NSString *key in @[@"format", @"mimeType", @"audioMode", @"quality", @"audioQuality", @"codec"]) {
        NSString *v = string(s[key]).lowercaseString;
        if ([v containsString:@"atmos"] || [v containsString:@"dolby"]) return NO;
        if (([v containsString:@"dash"] || [v containsString:@"hls"] || [v containsString:@"mpegurl"]) && !SGAddonStreamTransport(s)) return NO;
    }
    // Decoder, not these hints, decides whether the completed file is lossless.
    return YES;
}
BOOL SGAddonDirectStream(NSDictionary *s) { return !SGAddonStreamTransport(s) && SGAddonStreamSupported(s); }
