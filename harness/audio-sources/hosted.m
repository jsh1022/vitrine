#import <Foundation/Foundation.h>
#import "Shared/AudioSources/SGHostedLossless.h"
#import "Shared/AudioSources/SGHostedAuthPolicy.h"
#import "Shared/AudioSources/SGAddonSegments.h"

static NSMutableDictionary *secrets;
NSString *SGSourceSecret(NSString *account) { return secrets[account]; }
BOOL SGSaveSourceSecret(NSString *account, NSString *value) { if (value) secrets[account]=value; else [secrets removeObjectForKey:account]; return YES; }
NSURLSessionConfiguration *SGSourceSessionConfiguration(NSString **reason) { return NSURLSessionConfiguration.ephemeralSessionConfiguration; }
BOOL SGFlag(NSString *key, BOOL fallback) { return fallback; }

static void require(BOOL ok, NSString *message) { if (!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
static NSString *account(NSString *provider) { return [@"hosted-lossless." stringByAppendingString:provider]; }
static void session(NSString *provider) {
    secrets[account(provider)]=@"{\"expires_at\":\"2099-01-01T00:00:00Z\",\"session_id\":\"session-abc\",\"session_secret\":\"secret-xyz\",\"install_id\":\"install-1\"}";
}

int main(void) { @autoreleasepool {
    secrets=[NSMutableDictionary dictionary];
    require(SGHostedAuthNavigationAllowed([NSURL URLWithString:@"about:blank"],NO) && SGHostedAuthNavigationAllowed([NSURL URLWithString:@"about:srcdoc"],NO),@"Turnstile local child frames about:blank and about:srcdoc are allowed");
    require(!SGHostedAuthNavigationAllowed([NSURL URLWithString:@"about:blank"],YES) && !SGHostedAuthNavigationAllowed([NSURL URLWithString:@"about:srcdoc"],YES),@"local documents cannot navigate the top frame");
    require(SGHostedAuthNavigationAllowed([NSURL URLWithString:@"https://challenges.cloudflare.com/turnstile/frame"],NO) && !SGHostedAuthNavigationAllowed([NSURL URLWithString:@"https://challenges.cloudflare.com/turnstile/frame"],YES),@"Cloudflare challenge origin is allowed only in child frames");
    require(SGHostedAuthNavigationAllowed([NSURL URLWithString:@"https://api.zarz.moe/auth"],YES),@"broker HTTPS top-level navigation is allowed");
    for (NSString *badURL in @[@"https://user@api.zarz.moe/auth",@"https://api.zarz.moe.evil.test/auth",@"https://api-zarz.moe/auth",@"http://api.zarz.moe/auth",@"https://api.zarz.moe:444/auth"]) {
        require(!SGHostedAuthNavigationAllowed([NSURL URLWithString:badURL],YES),[NSString stringWithFormat:@"unsafe broker URL rejected: %@",badURL]);
    }
    require([SGHostedAuthGrant(@"gr_fixture-token") isEqual:@"gr_fixture-token"],@"raw gr_ grant accepted");
    require([SGHostedAuthGrant(@"mornye://session-grant?grant=gr_fixture-token") isEqual:@"gr_fixture-token"] &&
            [SGHostedAuthGrant(@"mornye://session-grant/?grant=gr_fixture-token") isEqual:@"gr_fixture-token"],@"exact mornye grant URLs with and without slash accepted");
    for (NSString *badGrant in @[@"mornye://session-grant?grant=gr_one&grant=gr_two",@"gr_bad token",@"mornye://evil-host?grant=gr_token",@"mornye://user:password@session-grant?grant=gr_token",@"mornye://session-grant?grant=gr_token#fragment"]) {
        require(!SGHostedAuthGrant(badGrant),[NSString stringWithFormat:@"malformed grant rejected: %@",badGrant]);
    }
    require(!SGHostedProvider(@"amazon") && SGHostedAppVersion(@"amazon")==nil,@"Amazon is not a supported hosted provider");
    __block NSUInteger unsupportedCalls=0;
    require(!SGHostedStream(@"amazon",@"B012345678",^NSDictionary *(NSURLRequest *request){ unsupportedCalls++; return @{}; },nil) && unsupportedCalls==0,
            @"unsupported Amazon stream is rejected without network callbacks");
    require(!SGHostedStreamResponse(@"amazon",@{@"data":@{@"manifest":[[@"{}" dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]}}),
            @"Amazon stream responses are rejected as an unsupported provider");
    NSDictionary *record=@{@"session_id":@"session-fixed-42",@"session_secret":@"test-secret-123"};
    NSData *body=[@"{\"id\":\"42\"}" dataUsingEncoding:NSUTF8StringEncoding];
    NSDate *date=[NSDate dateWithTimeIntervalSince1970:1767323045];
    NSDictionary *headers=SGHostedSignedHeaders(record,@"qobuz-web@1.2.21",@"POST",@"/v2/dl/qbz",body,date,@"00112233445566778899aabbccddeeff");
    require([headers[@"X-Zarz-Timestamp"] isEqual:@"2026-01-02T03:04:05.000Z"] && [headers[@"X-Zarz-Body-SHA256"] isEqual:@"8aa5b6751d68bd72901cea96bbbddca8624efa387d5442a63197d5fedb2b693d"],@"fixed body hash and timestamp");
    require([headers[@"X-Zarz-Signature"] isEqual:@"seEDnkmNgHA-7P4UYrL8Qir5SzhFINUADBehyuDe1mY"],@"independent Python HMAC-SHA256 rolling-key golden signature");
    for (NSString *variant in @[@"body",@"nonce",@"path",@"key"]) {
        NSData *b=[variant isEqual:@"body"] ? [@"different" dataUsingEncoding:NSUTF8StringEncoding] : body;
        NSString *n=[variant isEqual:@"nonce"] ? @"ffeeddccbbaa99887766554433221100" : @"00112233445566778899aabbccddeeff";
        NSString *p=[variant isEqual:@"path"] ? @"/v2/dl/other" : @"/v2/dl/qbz";
        NSDictionary *r=[variant isEqual:@"key"] ? @{@"session_id":@"session-fixed-42",@"session_secret":@"changed-secret"} : record;
        NSDictionary *changed=SGHostedSignedHeaders(r,@"qobuz-web@1.2.21",@"POST",p,b,date,n);
        require(![changed[@"X-Zarz-Signature"] isEqual:headers[@"X-Zarz-Signature"]],[variant stringByAppendingString:@" changes signature"]);
    }

    NSDictionary *qbz=SGHostedStreamResponse(@"qobuz",@{@"download_url":@"https://media.test/track.flac"});
    require([qbz[@"url"] isEqual:@"https://media.test/track.flac"] && [qbz[@"codec"] isEqual:@"flac"],@"Qobuz direct FLAC response");
    NSString *btsFLAC=@"{\"mimeType\":\"audio/flac\",\"urls\":[\"https://media.test/tidal.flac\"]}";
    NSString *btsALAC=@"{\"mimeType\":\"audio/alac\",\"urls\":[\"https://media.test/tidal.m4a\"]}";
    NSDictionary *tidal=SGHostedStreamResponse(@"tidal",@{@"data":@{@"assetPresentation":@"FULL",@"manifest":[[btsFLAC dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]}});
    NSDictionary *alac=SGHostedStreamResponse(@"tidal",@{@"data":@{@"manifest":[[btsALAC dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]}});
    require([tidal[@"codec"] isEqual:@"flac"] && [alac[@"codec"] isEqual:@"alac"],@"Tidal base64 BTS FLAC and ALAC");
    NSDictionary *aac=SGHostedStreamResponse(@"tidal",@{@"data":@{@"manifest":[[@"{\"mimeType\":\"audio/mp4\",\"urls\":[\"https://media.test/aac\"]}" dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]}});
    NSDictionary *preview=SGHostedStreamResponse(@"tidal",@{@"data":@{@"assetPresentation":@"PREVIEW",@"manifest":[[btsFLAC dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]}});
    require(!aac && !preview,@"reject AAC and PREVIEW assets");
    NSString *dashText=@"<MPD type=\"static\" mediaPresentationDuration=\"PT5S\"><Period duration=\"PT5S\"><AdaptationSet mimeType=\"audio/flac\"><Representation id=\"f\" bandwidth=\"1000\" codecs=\"flac\"><BaseURL>audio.flac</BaseURL><SegmentBase indexRange=\"0-99\"/></Representation></AdaptationSet></Period></MPD>";
    NSDictionary *dash=SGHostedStreamResponse(@"tidal",@{@"data":@{@"manifest":[[dashText dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]}});
    require(dash && [SGAddonStreamTransport(dash) isEqual:@"dash"],@"DASH inline response is routed to DASH transport");
    NSDictionary *plan=SGAddonSegmentPlan([dash[@"manifestText"] dataUsingEncoding:NSUTF8StringEncoding],[NSURL URLWithString:dash[@"url"]],@"dash");
    require([plan[@"parts"] count]==1 && [[(NSURL *)plan[@"parts"][0][@"url"] absoluteString] isEqual:@"https://api.zarz.moe/audio.flac"],@"existing DASH SegmentPlan selects the FLAC progressive fixture");

    session(@"qobuz"); require(SGHostedVerified(@"qobuz"),@"valid saved session verifies");
    require(!SGHostedAuthenticationExpired(@"qobuz") && !SGHostedAuthenticationExpired(@"tidal"),@"valid and never-authenticated sources are not expired");
    secrets[account(@"deezer")]=@"{\"expires_at\":\"2000-01-01T00:00:00Z\",\"session_id\":\"old\",\"session_secret\":\"old-secret\"}";
    require(SGHostedAuthenticationExpired(@"deezer"),@"elapsed server expiry is detected locally");
    secrets[account(@"deezer")]=@"{\"expires_at\":\"malformed\",\"session_id\":\"old\",\"session_secret\":\"old-secret\"}";
    require(!SGHostedAuthenticationExpired(@"deezer"),@"unknown expiry cannot be guessed");
    SGHostedForget(@"deezer");

    __block NSUInteger index=0;
    NSDictionary *(^send)(NSURLRequest *)=^NSDictionary *(NSURLRequest *request) {
        index++;
        require([request valueForHTTPHeaderField:@"X-Zarz-Session"] && [request valueForHTTPHeaderField:@"X-Zarz-Signature"] && [request valueForHTTPHeaderField:@"X-Zarz-Nonce"],@"broker request is signed");
        if (index==1) {
            require([request.URL.path isEqual:@"/v2/tickets"] && [request.HTTPMethod isEqual:@"POST"],@"ticket call is first");
            NSDictionary *v=[NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:NULL];
            require([v[@"provider"] isEqual:@"qbz"] && [v[@"capability"] isEqual:@"download_ticket"] && [v[@"resource_hash"] length]==64,@"ticket request body carries Qobuz resource hash");
            return @{@"_http":@200,@"ticket_id":@"ticket-1"};
        }
        require(index==2 && [request.URL.path isEqual:@"/v2/dl/qbz"] && [[request valueForHTTPHeaderField:@"X-Zarz-Ticket"] isEqual:@"ticket-1"],@"download call follows ticket with ticket header");
        NSDictionary *v=[NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:NULL];
        require([v[@"id"] isEqual:@"42"] && [v[@"quality"] isEqual:@"hi-res-max"] && [v[@"upload_to_r2"] isEqual:@NO],@"Qobuz download request body");
        return @{@"_http":@200,@"download_url":@"https://media.test/result.flac"};
    };
    NSDictionary *stream=SGHostedStream(@"qobuz",@"42",send,nil);
    require(index==2 && [stream[@"codec"] isEqual:@"flac"],@"stream tickets then downloads and returns direct FLAC");

    session(@"tidal"); index=0;
    NSDictionary *(^tidalSend)(NSURLRequest *)=^NSDictionary *(NSURLRequest *request) {
        index++;
        require([request.URL.path isEqual:@"/v2/tickets"] || [request.URL.path isEqual:@"/v2/dl/tid"],@"Tidal requests remain on broker paths");
        if (index==1) return @{@"_http":@200,@"ticket_id":@"tid-ticket"};
        require([[request valueForHTTPHeaderField:@"X-Zarz-Ticket"] isEqual:@"tid-ticket"],@"Tidal download attaches ticket");
        return @{@"_http":@200,@"data":@{@"manifest":[[btsFLAC dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]}};
    };
    require([SGHostedStream(@"tidal",@"987",tidalSend,nil)[@"codec"] isEqual:@"flac"] && index==2,@"Tidal stream flow");

    session(@"deezer"); index=0;
    NSDictionary *(^deezerSend)(NSURLRequest *)=^NSDictionary *(NSURLRequest *request) {
        index++;
        require([request valueForHTTPHeaderField:@"X-Zarz-Session"] && [request valueForHTTPHeaderField:@"X-Zarz-Signature"],@"Deezer broker call is signed");
        if (index==1) {
            require([request.URL.path isEqual:@"/v2/tickets"],@"Deezer requests ticket first");
            NSDictionary *body=[NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:NULL];
            require([body[@"provider"] isEqual:@"dzr"] && [body[@"capability"] isEqual:@"download_ticket"] &&
                    [body[@"resource_hash"] isEqual:@"0a4f49fc624bb235ed1ffffcce1bff35903590d39ece952c2348ab071ffca6f6"],@"Deezer ticket uses dzr provider and fixed track resource hash");
            return @{@"_http":@200,@"ticket_id":@"deezer-ticket"};
        }
        require(index==2 && [request.URL.path isEqual:@"/v2/dl/dzr"] && [[request valueForHTTPHeaderField:@"X-Zarz-Ticket"] isEqual:@"deezer-ticket"],@"Deezer download follows ticket at /dl/dzr");
        NSDictionary *body=[NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:NULL];
        require([body[@"id"] isEqual:@"123456"] && [body[@"url"] isEqual:@"https://www.deezer.com/track/123456"] && [body[@"type"] isEqual:@"track"],@"Deezer download body carries track URL and ID");
        return @{@"_http":@200,@"success":@YES,@"deezer_source_format":@"FLAC",@"direct_downloadable":@NO,@"deezer_encrypted":@YES,@"deezer_track_id":@123456,@"download_url":@"https://media.test/123456.flac"};
    };
    NSDictionary *deezerStream=SGHostedStream(@"deezer",@"123456",deezerSend,nil);
    require(index==2 && [deezerStream[@"url"] isEqual:@"https://media.test/123456.flac"] &&
            [deezerStream[@"hostedTransform"] isEqual:@"deezer"] && [deezerStream[@"mediaTrackID"] isEqual:@"123456"] && [deezerStream[@"codec"] isEqual:@"flac"],
            @"Deezer encrypted response maps to its transform descriptor");
    NSDictionary *deezerSearch=SGHostedSearch(@"deezer",@"fixture",^NSDictionary *(NSURLRequest *request) {
        require([request.URL.host isEqual:@"api.deezer.com"] && [request.URL.path isEqual:@"/search"] &&
                [[[NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO].queryItems filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@",@"q"]].firstObject.value isEqual:@"fixture"],
                @"Deezer public catalogue search URL and query");
        return @{@"_http":@200,@"data":@[@{@"id":@123456,@"title":@"Fixture",@"artist":@{@"name":@"Artist"},@"duration":@211}]};
    },nil);
    NSDictionary *deezerRow=[deezerSearch[@"tracks"] firstObject];
    require([deezerRow[@"id"] isEqual:@"123456"] && [deezerRow[@"artist"] isEqual:@"Artist"],@"Deezer catalogue maps numeric track ID and nested artist name");

    SGHostedForget(@"qobuz"); __block NSUInteger calls=0; NSString *error=nil;
    require(!SGHostedVerified(@"qobuz") && !SGHostedSearch(@"qobuz",@"song",^NSDictionary *(NSURLRequest *r){ calls++; return @{}; },&error) && calls==0,@"missing session fails without network");
    session(@"qobuz"); calls=0;
    require(!SGHostedStream(@"qobuz",@"42",^NSDictionary *(NSURLRequest *r){ calls++; return @{@"_http":@401,@"code":@"INVALID_CREDENTIALS",@"origin":@"provider"}; },&error) && calls==1 && SGHostedVerified(@"qobuz"),@"provider 401 does not revoke the hosted session");
    require(!SGHostedAuthenticationExpired(@"qobuz"),@"provider error is not reported as session expiry");
    session(@"qobuz"); calls=0;
    require(!SGHostedStream(@"qobuz",@"42",^NSDictionary *(NSURLRequest *r){ calls++; return @{@"_http":@401,@"code":@"SESSION_INVALID"}; },&error) && calls==1 && !SGHostedVerified(@"qobuz"),@"gateway SESSION_INVALID revokes stored session");
    require(SGHostedAuthenticationExpired(@"qobuz"),@"confirmed gateway invalidation persists after credentials are revoked");
    SGHostedForget(@"qobuz");require(!SGHostedAuthenticationExpired(@"qobuz"),@"explicit source removal clears the expiry marker");
    session(@"qobuz"); calls=0;
    require(!SGHostedStream(@"qobuz",@"42",^NSDictionary *(NSURLRequest *r){ calls++; return @{@"_http":@428,@"code":@"VERIFY_REQUIRED"}; },&error) && calls==1 && !SGHostedVerified(@"qobuz"),@"gateway VERIFY_REQUIRED revokes stored session");
    require(SGHostedAuthenticationExpired(@"qobuz"),@"gateway verification requirement persists for next foreground notice");

    NSDate *soon=[NSDate dateWithTimeIntervalSinceNow:30*60];
    NSISO8601DateFormatter *dateFormatter=[NSISO8601DateFormatter new];
    dateFormatter.formatOptions=NSISO8601DateFormatWithInternetDateTime;
    secrets[account(@"qobuz")]=[NSString stringWithFormat:@"{\"expires_at\":\"%@\",\"session_id\":\"old-session\",\"session_secret\":\"old-secret\",\"install_id\":\"install-1\"}",[dateFormatter stringFromDate:soon]];
    calls=0;
    NSDictionary *search=SGHostedSearch(@"qobuz",@"fixture",^NSDictionary *(NSURLRequest *request) {
        calls++;
        if (calls==1) {
            require([request.URL.path isEqual:@"/v2/session/refresh"] && [request.HTTPMethod isEqual:@"POST"],@"near-expiry session refresh precedes search");
            require([[request valueForHTTPHeaderField:@"X-Zarz-Session"] isEqual:@"old-session"] && [request valueForHTTPHeaderField:@"X-Zarz-Signature"].length,@"refresh is signed with current credentials");
            return @{@"session_id":@"new-session",@"session_secret":@"new-secret",@"expires_at":@"2099-01-01T00:00:00Z"};
        }
        require(calls==2 && [request.URL.path isEqual:@"/v2/qbz/track/search"],@"catalogue search follows successful refresh");
        require([[request valueForHTTPHeaderField:@"X-Zarz-Session"] isEqual:@"new-session"] && [request valueForHTTPHeaderField:@"X-Zarz-Signature"].length,@"catalogue search uses refreshed session signature");
        return @{@"_http":@200,@"tracks":@{@"items":@[@{@"id":@"42",@"title":@"Fixture",@"streamable":@YES}]}};
    },&error);
    require(calls==2 && [search[@"tracks"] count]==1 && [[NSJSONSerialization JSONObjectWithData:[secrets[account(@"qobuz")] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL][@"session_id"] isEqual:@"new-session"],@"near-expiry session refresh saves credentials before search");

    secrets[account(@"qobuz")]=@"{\"expires_at\":\"2000-01-01T00:00:00Z\",\"session_id\":\"expired-session\",\"session_secret\":\"expired-secret\",\"install_id\":\"install-1\"}";
    calls=0; error=nil;
    require(!SGHostedSearch(@"qobuz",@"fixture",^NSDictionary *(NSURLRequest *request){ calls++; return @{}; },&error) && calls==0,@"expired session is rejected without attempting refresh or network search");
    SGHostedServerResponse(429,nil);
    SGHostedServerResponse(503,@"invalid");
    require(!SGHostedServerWaiting(),@"server failures without a valid Retry-After do not invent a cooldown");
    SGHostedServerResponse(429,@"30");
    require(SGHostedServerWaiting(),@"broker Retry-After is shared by both built-in sources and authentication");
    NSLog(@"PASS: hosted signing, response decoding, DASH planning, broker ordering and session checks");
} return 0; }
