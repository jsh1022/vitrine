#import <Foundation/Foundation.h>
#import "Shared/AudioSources/SGAddonProtocol.h"

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
    require(!SGAddonManifestSupported(@{@"id": @"private", @"bitchordAuth": @YES}), @"never impersonate official app");
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
    NSLog(@"PASS: addon protocol fixtures");
} return 0; }
