#import <Foundation/Foundation.h>
#import "Shared/AudioSources/SGAddonProtocol.h"
#import "Shared/AudioSources/SGAddonSegments.h"

static void require(BOOL ok, NSString *message) {
    if (!ok) { NSLog(@"FAIL: %@", message); exit(1); }
}
int main(void) { @autoreleasepool {
    NSURL *base = SGAddonBaseURL(@" https://example.test/Server/Se%2Fcret/manifest.json?token=a%2Bb ");
    require([base.absoluteString isEqual:@"https://example.test/Server/Se%2Fcret?token=a%2Bb"], @"preserve secret prefix and query");
    NSURL *stream = SGAddonEndpoint(base, @[@"stream", @"id/with?query#fragment"], @{@"q": @"A+B & 한글", @"quality": @"LOSSLESS"});
    require([stream.absoluteString containsString:@"/Server/Se%2Fcret/stream/id%2Fwith%3Fquery%23fragment?"], @"IDs cannot change endpoints");
    require([stream.absoluteString containsString:@"q=A%2BB%20%26%20%ED%95%9C%EA%B8%80"], @"query delimiters and plus are encoded");
    require([stream.absoluteString containsString:@"token=a%2Bb"], @"base query survives endpoint construction");
    for (NSString *input in @[@"http://example.test/root", @"file:///tmp/audio", @"https://user:pass@example.test", @"https://example.test/pages/setup.html", @"https://example.test/#secret"])
        require(!SGAddonBaseURL(input), @"reject unsupported source URLs");
    require(SGAddonManifestSupported(@{@"id": @"library", @"resources": @[@"search", @"stream"]}), @"ordinary HTTP addon supported");
    require(SGAddonManifestSupported(@{@"id": @"private", @"bitchordAuth": @YES}), @"auth declaration defers access decision to the server, matching BitChord iOS");
    require(!SGAddonManifestSupported(@{@"bitchordAuth": @YES}), @"auth declaration does not replace required manifest id");
    require(!SGAddonManifestSupported(@{@"id": @"private", @"bitchordAuth": @YES, @"resources": @[@"video"]}), @"auth declaration does not enable unsupported resources");
    require(!SGAddonManifestSupported(@{@"resources": @[@"search"]}), @"manifest needs an id");
    require(!SGAddonManifestSupported(@{@"id": @"other", @"resources": @[@"video"]}), @"unsupported resources");
    NSDictionary *parameters = SGAddonParameters(@{@"settings": @[
        @{@"key": @"quality", @"default": @"low", @"options": @[@{@"value": @"low"}, @{@"value": @"flac"}]},
        @{@"key": @"atmos", @"default": @"auto"}, @{@"key": @"region", @"default": @"KR"}]});
    require([parameters[@"quality"] isEqual:@"flac"] && [parameters[@"atmos"] isEqual:@"false"] && [parameters[@"region"] isEqual:@"KR"], @"quality negotiation, stereo policy and defaults");
    NSDictionary *track = @{@"title": @"Song (Live)", @"artist": @"Artist", @"duration": @180.0};
    require(SGAddonTrackMatches(track, @"song (live)", @"artist", 181), @"same edition and duration match");
    require(!SGAddonTrackMatches(track, @"Song", @"Artist", 180), @"different edition rejected");
    require(!SGAddonTrackMatches(track, @"Song (Live)", @"Someone else", 180), @"different artist rejected");
    require(!SGAddonTrackMatches(track, @"Song (Live)", @"Artist", 211), @"different duration rejected");
    require(SGAddonTrackMatches(@{@"title": @"Song", @"artist": @"Artist"}, @"Song", @"Artist", 180), @"missing metadata duration is deferred to native file validation");
    require(SGAddonDirectStream(@{@"url": @"https://media.test/audio", @"format": @"flac"}), @"direct URL without encrypted field accepted for decoder verification");
    for (NSDictionary *bad in @[
        @{@"url": @"http://media.test/audio"}, @{@"url": @"https://media.test/audio", @"encrypted": @"widevine"},
        @{@"url": @"https://media.test/audio", @"manifest": @"dash"}, @{@"url": @"https://media.test/audio", @"format": @"hls"},
        @{@"url": @"https://media.test/audio", @"audioMode": @"DOLBY_ATMOS"}])
        require(!SGAddonDirectStream(bad), @"reject unsupported rendition before media request");
    require([SGAddonParameters(@{@"settings": @[@{@"key": @"quality", @"default": @"atmos", @"options": @[@{@"value": @"atmos"}, @{@"value": @"hires"}, @{@"value": @"lossless"}]}]})[@"quality"] isEqual:@"lossless"], @"exact requested quality wins before hires, matching BitChord");
    require(SGAddonTrackMatches(@{@"title": @"Don't Stop", @"artist": @"Artist, Guest", @"duration": @180}, @"Don’t Stop", @"Artist", 180), @"punctuation and multi-credit formatting do not reject the same recording");
    NSURL *manifestBase = [NSURL URLWithString:@"https://media.test/manifests/index.m3u8"];
    NSDictionary *hlsPlan = SGAddonSegmentPlan([@"#EXTM3U\n#EXT-X-MAP:URI=\"../audio/init.mp4\",BYTERANGE=\"16@0\"\n#EXTINF:2,\n#EXT-X-BYTERANGE:100@16\n../audio/media.m4s\n#EXTINF:3,\n#EXT-X-BYTERANGE:80\n../audio/media.m4s\n#EXT-X-ENDLIST\n" dataUsingEncoding:NSUTF8StringEncoding], manifestBase, @"hls");
    NSArray *hlsParts = hlsPlan[@"parts"];
    require(hlsParts.count == 3 && [hlsPlan[@"duration"] doubleValue] == 5, @"HLS VOD map and media segments form a finite plan");
    require([[(NSURL *)hlsParts[0][@"url"] absoluteString] isEqual:@"https://media.test/audio/init.mp4"] && NSEqualRanges([hlsParts[0][@"range"] rangeValue], NSMakeRange(0, 16)), @"HLS map resolves relatively and keeps its byte range");
    require([[(NSURL *)hlsParts[1][@"url"] absoluteString] isEqual:@"https://media.test/audio/media.m4s"] && NSEqualRanges([hlsParts[1][@"range"] rangeValue], NSMakeRange(16, 100)), @"HLS first segment URL and explicit range");
    require([[(NSURL *)hlsParts[2][@"url"] absoluteString] isEqual:@"https://media.test/audio/media.m4s"] && NSEqualRanges([hlsParts[2][@"range"] rangeValue], NSMakeRange(116, 80)), @"HLS implicit range continues on the same relative URL");
    NSURL *masterBase = [NSURL URLWithString:@"https://media.test/root/master.m3u8"];
    NSDictionary *master = SGAddonSegmentPlan([@"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=900000,CODECS=\"mp4a.40.2\"\nlossy.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200000,CODECS=\"flac\"\nlossless/audio.m3u8\n" dataUsingEncoding:NSUTF8StringEncoding], masterBase, @"hls");
    require([[(NSURL *)master[@"playlist"] absoluteString] isEqual:@"https://media.test/root/lossless/audio.m3u8"], @"HLS master skips AAC and selects FLAC variant");
    for (NSString *badHLS in @[
        @"#EXTM3U\n#EXTINF:2,\na.ts\n", // live: no ENDLIST
        @"#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\n#EXTINF:2,\na.ts\n#EXT-X-DISCONTINUITY\n#EXTINF:2,\nb.ts\n#EXT-X-ENDLIST\n",
        @"#EXTM3U\n#EXTINF:2,\nhttp://media.test/a.ts\n#EXT-X-ENDLIST\n"])
        require(!SGAddonSegmentPlan([badHLS dataUsingEncoding:NSUTF8StringEncoding], masterBase, @"hls"), @"reject HLS live, encrypted, discontinuous, and HTTP manifests");

    NSURL *mpdBase = [NSURL URLWithString:@"https://media.test/manifests/audio.mpd"];
    NSString *dashHead = @"<MPD type=\"static\" mediaPresentationDuration=\"PT5S\"><Period duration=\"PT5S\"><AdaptationSet mimeType=\"audio/flac\"><Representation id=\"flac1\" bandwidth=\"1000\" codecs=\"flac\">";
    NSString *dashTail = @"</Representation></AdaptationSet></Period></MPD>";
    NSString *templateXML = [NSString stringWithFormat:@"%@<BaseURL>../files/</BaseURL><SegmentTemplate timescale=\"1\" duration=\"2\" initialization=\"init-$RepresentationID$.m4a\" media=\"chunk-$Number%%03d$.m4a\"/>%@", dashHead, dashTail];
    NSDictionary *templatePlan = SGAddonSegmentPlan([templateXML dataUsingEncoding:NSUTF8StringEncoding], mpdBase, @"dash");
    NSArray *templateParts = templatePlan[@"parts"];
    require(templateParts.count == 4 && [templatePlan[@"duration"] doubleValue] == 5, @"DASH duration template expands init and ceil-duration segments");
    require([[(NSURL *)templateParts[0][@"url"] absoluteString] isEqual:@"https://media.test/files/init-flac1.m4a"] && [[(NSURL *)templateParts[1][@"url"] absoluteString] isEqual:@"https://media.test/files/chunk-001.m4a"] && [[(NSURL *)templateParts[3][@"url"] absoluteString] isEqual:@"https://media.test/files/chunk-003.m4a"], @"DASH relative BaseURL and padded Number URLs");
    NSString *timelineXML = [NSString stringWithFormat:@"%@<SegmentTemplate timescale=\"1\" initialization=\"init.m4a\" media=\"at-$Time$.m4a\"><SegmentTimeline><S t=\"0\" d=\"2\" r=\"1\"/><S t=\"5\" d=\"1\"/></SegmentTimeline></SegmentTemplate>%@", dashHead, dashTail];
    NSDictionary *timelinePlan = SGAddonSegmentPlan([timelineXML dataUsingEncoding:NSUTF8StringEncoding], mpdBase, @"dash");
    NSArray *timelineParts = timelinePlan[@"parts"];
    require(timelineParts.count == 4 && [[(NSURL *)timelineParts[1][@"url"] absoluteString] isEqual:@"https://media.test/manifests/at-0.m4a"] && [[(NSURL *)timelineParts[2][@"url"] absoluteString] isEqual:@"https://media.test/manifests/at-2.m4a"] && [[(NSURL *)timelineParts[3][@"url"] absoluteString] isEqual:@"https://media.test/manifests/at-5.m4a"], @"DASH timeline repeats and expands Time URLs");
    NSString *listXML = [NSString stringWithFormat:@"%@<SegmentList><Initialization sourceURL=\"media.bin\" range=\"0-15\"/><SegmentURL media=\"media.bin\" mediaRange=\"16-99\"/><SegmentURL media=\"media.bin\" mediaRange=\"100-199\"/></SegmentList>%@", dashHead, dashTail];
    NSDictionary *listPlan = SGAddonSegmentPlan([listXML dataUsingEncoding:NSUTF8StringEncoding], mpdBase, @"dash");
    NSArray *listParts = listPlan[@"parts"];
    require(listParts.count == 3 && NSEqualRanges([listParts[0][@"range"] rangeValue], NSMakeRange(0, 16)) && NSEqualRanges([listParts[1][@"range"] rangeValue], NSMakeRange(16, 84)) && NSEqualRanges([listParts[2][@"range"] rangeValue], NSMakeRange(100, 100)), @"DASH SegmentList preserves inclusive byte ranges as lengths");
    NSString *baseXML = [NSString stringWithFormat:@"%@<BaseURL>../files/full.flac</BaseURL><SegmentBase indexRange=\"0-99\"/>%@", dashHead, dashTail];
    NSDictionary *basePlan = SGAddonSegmentPlan([baseXML dataUsingEncoding:NSUTF8StringEncoding], mpdBase, @"dash");
    require([basePlan[@"parts"] count] == 1 && [[(NSURL *)basePlan[@"parts"][0][@"url"] absoluteString] isEqual:@"https://media.test/files/full.flac"] && !basePlan[@"parts"][0][@"range"], @"DASH SegmentBase downloads the direct progressive file");
    for (NSString *badDASH in @[
        [templateXML stringByReplacingOccurrencesOfString:@"type=\"static\"" withString:@"type=\"dynamic\""],
        [templateXML stringByReplacingOccurrencesOfString:@"codecs=\"flac\"" withString:@"codecs=\"mp4a.40.2\""],
        @"<MPD type=\"static\" mediaPresentationDuration=\"PT5S\"><Period duration=\"PT2S\"></Period><Period duration=\"PT3S\"></Period></MPD>",
        [NSString stringWithFormat:@"%@<ContentProtection schemeIdUri=\"urn:test\"/><SegmentTemplate initialization=\"init.m4a\" media=\"http://media.test/$Number$.m4a\" duration=\"1\"/>%@", dashHead, dashTail]])
        require(!SGAddonSegmentPlan([badDASH dataUsingEncoding:NSUTF8StringEncoding], mpdBase, @"dash"), @"reject dynamic, lossy, multi-period, protected, and HTTP DASH manifests");
    require(SGAddonStreamSupported(@{@"url": @"https://media.test/audio.m3u8", @"manifest": @"hls"}) && !SGAddonDirectStream(@{@"url": @"https://media.test/audio.m3u8", @"manifest": @"hls"}), @"HLS is supported as a manifest but not as a direct stream");
    require(SGAddonStreamSupported(@{@"url": @"https://media.test/audio.mpd", @"manifest": @"dash"}) && !SGAddonDirectStream(@{@"url": @"https://media.test/audio.mpd", @"manifest": @"dash"}), @"DASH is supported as a manifest but not as a direct stream");
    require(!SGAddonStreamSupported(@{@"url":@"https://media.test/audio.m3u8", @"manifest":@"hls", @"codec":@"aac"}) &&
            !SGAddonStreamSupported(@{@"url":@"https://media.test/audio.mpd", @"manifest":@"dash", @"codec":@"mp4a.40.2"}) &&
            !SGAddonStreamSupported(@{@"url":@"https://media.test/file.mp3", @"codec":@"mp3"}), @"known MP3/AAC renditions are rejected before download");
    NSString *httpDASH = [NSString stringWithFormat:@"%@<SegmentTemplate initialization=\"init.m4a\" media=\"http://media.test/$Number$.m4a\" duration=\"1\"/>%@",dashHead,dashTail];
    require(!SGAddonSegmentPlan([httpDASH dataUsingEncoding:NSUTF8StringEncoding],mpdBase,@"dash"), @"unencrypted DASH still refuses HTTP media segments");
    NSString *offsetDASH=[templateXML stringByReplacingOccurrencesOfString:@"timescale=\"1\"" withString:@"timescale=\"1\" presentationTimeOffset=\"2\""];
    require(!SGAddonSegmentPlan([offsetDASH dataUsingEncoding:NSUTF8StringEncoding],mpdBase,@"dash"), @"non-zero DASH presentation offset requires an unimplemented edit timeline");
    NSLog(@"PASS: addon protocol fixtures");
} return 0; }
