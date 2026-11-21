#import "SGAddonSegments.h"
#include <math.h>

static NSString *text(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSURL *resolve(NSString *value, NSURL *base) {
    if (!value.length) return nil;
    NSURL *url = [NSURL URLWithString:value relativeToURL:base].absoluteURL;
    return [url.scheme.lowercaseString isEqual:@"https"] && url.host.length && !url.user && !url.password && !url.fragment ? url : nil;
}
NSString *SGAddonStreamTransport(NSDictionary *stream) {
    NSURL *url = [NSURL URLWithString:text(stream[@"url"])];
    for (NSString *key in @[@"manifest", @"mediaType", @"mimeType", @"format"]) {
        NSString *value = text(stream[key]).lowercaseString;
        if ([@[@"hls", @"m3u8", @"application/x-mpegurl", @"application/vnd.apple.mpegurl"] containsObject:value]) return @"hls";
        if ([@[@"dash", @"mpd", @"application/dash+xml"] containsObject:value]) return @"dash";
    }
    if ([url.pathExtension.lowercaseString isEqual:@"m3u8"]) return @"hls";
    if ([url.pathExtension.lowercaseString isEqual:@"mpd"]) return @"dash";
    return nil;
}
static NSDictionary *attributes(NSString *line) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([A-Za-z0-9-]+)=(\"[^\"]*\"|[^,]*)" options:0 error:NULL];
    for (NSTextCheckingResult *match in [re matchesInString:line options:0 range:NSMakeRange(0, line.length)]) {
        NSString *value = [line substringWithRange:[match rangeAtIndex:2]];
        if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) value = [value substringWithRange:NSMakeRange(1, value.length-2)];
        result[[line substringWithRange:[match rangeAtIndex:1]]] = value;
    }
    return result;
}
// Unknown codecs are validated from the assembled file. Known lossy/video codecs are never selected.
static BOOL codecAllowed(NSString *codecs) {
    if (!codecs.length) return YES;
    for (NSString *raw in [codecs.lowercaseString componentsSeparatedByString:@","]) {
        NSString *c = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![c hasPrefix:@"flac"] && ![c hasPrefix:@"alac"] && ![c hasPrefix:@"lpcm"] && ![c hasPrefix:@"pcm"]) return NO;
    }
    return YES;
}
static BOOL integer(NSString *s, uint64_t *n) {
    if (!s.length || [s rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:s];
    unsigned long long value;
    if (![scanner scanUnsignedLongLong:&value] || !scanner.isAtEnd || value > NSUIntegerMax) return NO;
    *n = value; return YES;
}
static NSValue *byteRange(NSString *raw, BOOL hls, uint64_t fallback) {
    NSArray *pair = [raw componentsSeparatedByString:hls ? @"@" : @"-"];
    uint64_t a=0, b=0;
    if (!integer(pair.firstObject, &a)) return nil;
    if (pair.count > 2 || (pair.count == 2 && !integer(pair[1], &b))) return nil;
    if (hls) { b = pair.count == 2 ? b : fallback; if (!a || b > NSUIntegerMax-a) return nil; return [NSValue valueWithRange:NSMakeRange(b,a)]; }
    if (pair.count != 2 || b < a || b-a >= NSUIntegerMax) return nil;
    return [NSValue valueWithRange:NSMakeRange(a,b-a+1)];
}
static NSDictionary *part(NSURL *url, NSValue *range) {
    if (!url) return nil;
    return range ? @{@"url":url, @"range":range} : @{@"url":url};
}
static NSDictionary *hls(NSData *data, NSURL *base) {
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (![body hasPrefix:@"#EXTM3U"]) return nil;
    NSArray *lines = [body componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    NSMutableArray *variants = [NSMutableArray array], *parts = [NSMutableArray array];
    NSDictionary *pendingVariant = nil;
    NSString *pendingRange = nil;
    NSURL *previousURL = nil;
    uint64_t nextOffset = 0;
    BOOL ended = NO, hasMap = NO;
    double duration = 0, segmentDuration = 0;
    for (NSString *raw in lines) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!line.length) continue;
        if ([line hasPrefix:@"#EXT-X-KEY:"] || [line hasPrefix:@"#EXT-X-SESSION-KEY:"]) {
            if (![attributes(line)[@"METHOD"] isEqual:@"NONE"]) return nil;
        } else if ([line hasPrefix:@"#EXT-X-DISCONTINUITY"] || [line hasPrefix:@"#EXT-X-GAP"] || [line hasPrefix:@"#EXT-X-PART:"]) return nil;
        else if ([line hasPrefix:@"#EXT-X-MEDIA:"]) {
            NSDictionary *a = attributes(line);
            if ([a[@"TYPE"] isEqual:@"AUDIO"] && a[@"GROUP-ID"] && a[@"URI"]) groups[a[@"GROUP-ID"]] = a[@"URI"];
        } else if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) pendingVariant = attributes(line);
        else if ([line hasPrefix:@"#EXT-X-MAP:"]) {
            if (hasMap || parts.count) return nil; // no mid-track initialization or codec changes
            NSDictionary *a = attributes(line);
            NSValue *range = a[@"BYTERANGE"] ? byteRange(a[@"BYTERANGE"], YES, 0) : nil;
            if (a[@"BYTERANGE"] && !range) return nil;
            NSDictionary *p = part(resolve(a[@"URI"],base),range); if (!p) return nil;
            [parts addObject:p]; hasMap = YES;
        } else if ([line hasPrefix:@"#EXT-X-BYTERANGE:"]) pendingRange = [line substringFromIndex:17];
        else if ([line hasPrefix:@"#EXTINF:"]) {
            segmentDuration = [[line substringFromIndex:8] doubleValue];
            if (!isfinite(segmentDuration) || segmentDuration <= 0) return nil;
        } else if ([line isEqual:@"#EXT-X-ENDLIST"]) ended = YES;
        else if (![line hasPrefix:@"#"]) {
            if (ended) return nil;
            NSURL *url = resolve(line,base); if (!url) return nil;
            if (pendingVariant) {
                if (codecAllowed(text(pendingVariant[@"CODECS"]))) [variants addObject:@{@"url":url, @"attributes":pendingVariant}];
                pendingVariant = nil; continue;
            }
            if (segmentDuration <= 0) return nil;
            if (pendingRange && ![pendingRange containsString:@"@"] && ![previousURL isEqual:url]) return nil;
            NSValue *range = pendingRange ? byteRange(pendingRange,YES,nextOffset) : nil;
            if (pendingRange && !range) return nil;
            [parts addObject:part(url,range)]; if (parts.count > 2049) return nil;
            nextOffset = range ? NSMaxRange(range.rangeValue) : 0; previousURL = range ? url : nil;
            pendingRange = nil; duration += segmentDuration; segmentDuration = 0;
        }
    }
    if (variants.count) {
        if (parts.count || pendingVariant) return nil;
        NSDictionary *best = nil;
        for (NSDictionary *v in variants) if (!best || [v[@"attributes"][@"BANDWIDTH"] doubleValue] > [best[@"attributes"][@"BANDWIDTH"] doubleValue]) best = v;
        NSString *group = best[@"attributes"][@"AUDIO"];
        NSURL *url = group && groups[group] ? resolve(groups[group],base) : best[@"url"];
        return url ? @{@"playlist":url} : nil;
    }
    if (!ended || pendingRange || segmentDuration || duration <= 0 || duration > 7200 || !parts.count || (!hasMap && parts.count != 1)) return nil;
    return @{@"parts":parts, @"duration":@(duration)};
}

@interface SGAddonXMLNode : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSDictionary *attributes;
@property(nonatomic, strong) NSMutableString *text;
@property(nonatomic, strong) NSMutableArray<SGAddonXMLNode *> *children;
@end
@implementation SGAddonXMLNode
@end
@interface SGAddonXML : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<SGAddonXMLNode *> *stack;
@property(nonatomic, strong) SGAddonXMLNode *root;
@property(nonatomic) NSUInteger count;
@end
@implementation SGAddonXML
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified attributes:(NSDictionary *)a {
    if (++self.count > 10000 || self.stack.count > 24) { [p abortParsing]; return; }
    SGAddonXMLNode *node = [SGAddonXMLNode new]; node.name = name; node.attributes = a;
    node.text = [NSMutableString string]; node.children = [NSMutableArray array];
    [self.stack.lastObject.children addObject:node]; if (!self.root) self.root = node;
    [self.stack addObject:node];
}
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s { [self.stack.lastObject.text appendString:s]; }
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)n namespaceURI:(NSString *)u qualifiedName:(NSString *)q { [self.stack removeLastObject]; }
@end
static NSArray *children(SGAddonXMLNode *n, NSString *name) { return [n.children filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SGAddonXMLNode *c, NSDictionary *b) { return [c.name isEqual:name]; }]]; }
static SGAddonXMLNode *child(SGAddonXMLNode *n, NSString *name) { return children(n,name).firstObject; }
static double isoDuration(NSString *s) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^PT(?:(\\d+(?:\\.\\d+)?)H)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)S)?$" options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:s ?: @"" options:0 range:NSMakeRange(0,s.length)];
    if (!m) return 0; double result = 0; const double weights[] = {3600,60,1};
    for (NSUInteger i=1;i<=3;i++) if ([m rangeAtIndex:i].location != NSNotFound) result += [[s substringWithRange:[m rangeAtIndex:i]] doubleValue]*weights[i-1];
    return result;
}
static NSString *expand(NSString *pattern, NSString *identifier, NSString *bandwidth, uint64_t number, uint64_t time) {
    if (!pattern.length) return nil;
    NSString *s = [pattern stringByReplacingOccurrencesOfString:@"$$" withString:@"\x01"];
    s = [s stringByReplacingOccurrencesOfString:@"$RepresentationID$" withString:identifier ?: @""];
    s = [s stringByReplacingOccurrencesOfString:@"$Bandwidth$" withString:bandwidth ?: @""];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\$(Number|Time)(?:%0([1-9][0-9]?)d)?\\$" options:0 error:NULL];
    NSArray *matches = [re matchesInString:s options:0 range:NSMakeRange(0,s.length)];
    for (NSTextCheckingResult *m in matches.reverseObjectEnumerator) {
        BOOL isNumber = [[s substringWithRange:[m rangeAtIndex:1]] isEqual:@"Number"];
        NSUInteger width = [m rangeAtIndex:2].location == NSNotFound ? 0 : [[s substringWithRange:[m rangeAtIndex:2]] integerValue];
        if (width > 20) return nil;
        NSString *value = [NSString stringWithFormat:@"%0*llu",(int)width,(unsigned long long)(isNumber ? number : time)];
        s = [s stringByReplacingCharactersInRange:m.range withString:value];
    }
    if ([s containsString:@"$"]) return nil;
    return [s stringByReplacingOccurrencesOfString:@"\x01" withString:@"$"];
}
static NSDictionary *dash(NSData *data, NSURL *base) {
    NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!xml || [xml rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location != NSNotFound || [xml rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location != NSNotFound) return nil;
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data]; parser.shouldProcessNamespaces = YES; parser.shouldResolveExternalEntities = NO;
    SGAddonXML *delegate = [SGAddonXML new]; delegate.stack = [NSMutableArray array]; parser.delegate = delegate;
    if (![parser parse]) return nil;
    SGAddonXMLNode *root = delegate.root;
    if (![root.name isEqual:@"MPD"] || (root.attributes[@"type"] && ![root.attributes[@"type"] isEqual:@"static"]) || children(root,@"Period").count != 1) return nil;
    SGAddonXMLNode *period = child(root,@"Period");
    if (period.attributes[@"start"] && isoDuration(period.attributes[@"start"]) != 0) return nil;
    double duration = isoDuration(period.attributes[@"duration"] ?: root.attributes[@"mediaPresentationDuration"]);
    if (!isfinite(duration) || duration <= 0 || duration > 7200) return nil;
    SGAddonXMLNode *selected = nil, *adaptation = nil;
    for (SGAddonXMLNode *a in children(period,@"AdaptationSet")) for (SGAddonXMLNode *r in children(a,@"Representation")) {
        NSString *mime = r.attributes[@"mimeType"] ?: a.attributes[@"mimeType"];
        if (![mime hasPrefix:@"audio/"] && ![a.attributes[@"contentType"] isEqual:@"audio"]) continue;
        if (child(root,@"ContentProtection") || child(period,@"ContentProtection") || child(a,@"ContentProtection") || child(r,@"ContentProtection")) continue;
        if (!codecAllowed(r.attributes[@"codecs"] ?: a.attributes[@"codecs"])) continue;
        if (!selected || [r.attributes[@"bandwidth"] doubleValue] > [selected.attributes[@"bandwidth"] doubleValue]) { selected=r; adaptation=a; }
    }
    if (!selected) return nil;
    NSArray *hierarchy = @[root,period,adaptation,selected];
    NSURL *mediaBase = base;
    SGAddonXMLNode *list = nil, *segmentBase = nil, *timeline = nil;
    NSMutableDictionary *template = [NSMutableDictionary dictionary];
    for (SGAddonXMLNode *n in hierarchy) {
        NSString *relative = [child(n,@"BaseURL").text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (relative.length) { mediaBase=resolve(relative,mediaBase); if (!mediaBase) return nil; }
        if (child(n,@"SegmentList")) list=child(n,@"SegmentList");
        if (child(n,@"SegmentBase")) segmentBase=child(n,@"SegmentBase");
        SGAddonXMLNode *t=child(n,@"SegmentTemplate"); if (t) { [template addEntriesFromDictionary:t.attributes]; if (child(t,@"SegmentTimeline")) timeline=child(t,@"SegmentTimeline"); }
    }
    if ((list && template.count) || (segmentBase && (list || template.count))) return nil;
    NSMutableArray *parts=[NSMutableArray array];
    if (list) {
        SGAddonXMLNode *init=child(list,@"Initialization");
        if (!init) return nil;
        NSURL *u=init.attributes[@"sourceURL"] ? resolve(init.attributes[@"sourceURL"],mediaBase) : mediaBase;
        NSValue *range=init.attributes[@"range"] ? byteRange(init.attributes[@"range"],NO,0) : nil;
        if (!u || (init.attributes[@"range"] && !range)) return nil;
        [parts addObject:part(u,range)];
        for (SGAddonXMLNode *s in children(list,@"SegmentURL")) {
            u=s.attributes[@"media"] ? resolve(s.attributes[@"media"],mediaBase) : mediaBase;
            range=s.attributes[@"mediaRange"] ? byteRange(s.attributes[@"mediaRange"],NO,0) : nil;
            if (!u || (s.attributes[@"mediaRange"] && !range) || parts.count >= 2049) return nil;
            [parts addObject:part(u,range)];
        }
        if (parts.count < 2) return nil;
    } else if (template.count) {
        uint64_t scale=1,start=1,offset=0;
        if ((template[@"timescale"] && !integer(template[@"timescale"],&scale)) || !scale || scale > 1000000000 ||
            (template[@"startNumber"] && !integer(template[@"startNumber"],&start)) ||
            (template[@"presentationTimeOffset"] && !integer(template[@"presentationTimeOffset"],&offset))) return nil;
        // Non-zero offsets need a presentation edit timeline, which the local PCM path does not implement.
        if (offset) return nil;
        double end = duration*scale + offset; if (end > 9e15) return nil;
        NSString *identifier=selected.attributes[@"id"], *bandwidth=selected.attributes[@"bandwidth"];
        NSURL *init=resolve(expand(template[@"initialization"],identifier,bandwidth,start,0),mediaBase);
        if (!init || !template[@"media"]) return nil;
        [parts addObject:part(init,nil)];
        NSMutableArray *times=[NSMutableArray array];
        if (timeline) {
            NSArray *entries=children(timeline,@"S"); uint64_t at=0;
            for (NSUInteger i=0;i<entries.count;i++) {
                NSDictionary *a=[entries[i] attributes]; uint64_t d=0,t=0;
                if (!integer(a[@"d"],&d) || !d || (a[@"t"] && !integer(a[@"t"],&t))) return nil;
                if (a[@"t"]) at=t;
                NSInteger repeats=0;
                if (a[@"r"] && ![a[@"r"] isEqual:@"-1"]) { uint64_t r; if (!integer(a[@"r"],&r) || r>2048) return nil; repeats=(NSInteger)r; }
                if ([a[@"r"] isEqual:@"-1"]) {
                    double until=end;
                    if (i+1<entries.count) { uint64_t next; if (!integer([entries[i+1] attributes][@"t"],&next)) return nil; until=next; }
                    if (until<=at || ceil((until-at)/d)>2048) return nil;
                    repeats=(NSInteger)ceil((until-at)/d)-1;
                }
                for (NSInteger j=0;j<=repeats;j++) { if (times.count>=2048 || at>UINT64_MAX-d) return nil; [times addObject:@(at)]; at+=d; }
            }
        } else {
            uint64_t d; if (!integer(template[@"duration"],&d) || !d) return nil;
            double count=ceil(duration*scale/d); if (count<1 || count>2048) return nil;
            for (NSUInteger i=0;i<(NSUInteger)count;i++) [times addObject:@(i*d)];
        }
        if (!times.count || start>UINT64_MAX-times.count) return nil;
        for (NSUInteger i=0;i<times.count;i++) {
            NSURL *u=resolve(expand(template[@"media"],identifier,bandwidth,start+i,[times[i] unsignedLongLongValue]),mediaBase);
            if (!u) return nil; [parts addObject:part(u,nil)];
        }
    } else {
        // SegmentBase indexes one complete progressive file. Download that file, not its index.
        if ([mediaBase isEqual:base]) return nil;
        [parts addObject:part(mediaBase,nil)];
    }
    return @{@"parts":parts,@"duration":@(duration)};
}
NSDictionary *SGAddonSegmentPlan(NSData *data, NSURL *base, NSString *transport) {
    if (!data.length || data.length>1024*1024 || !resolve(base.absoluteString,base)) return nil;
    if ([transport isEqual:@"hls"]) return hls(data,base);
    if ([transport isEqual:@"dash"]) return dash(data,base);
    return nil;
}
