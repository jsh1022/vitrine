#import <Foundation/Foundation.h>
#import "Shared/AudioSources/SGAddonDiagnostics.h"

static void require(BOOL ok, NSString *message) {
    if (!ok) { NSLog(@"FAIL: %@", message); exit(1); }
}

int main(void) { @autoreleasepool {
    NSString *korean = SGAddonDiagnosticsSafeText(@"다운로드 진행 중");
    require([korean isEqual:@"다운로드 진행 중"], @"keep fixed Korean stage text readable");
    NSString *privateText = SGAddonDiagnosticsSafeText(@"실패 https://private.test/file?token=secret Bearer abcdefghijklmnop /Users/test/private/file abcdefghijklmnopqrstuvwxyz");
    require([privateText containsString:@"[주소 숨김]"], @"redact URLs");
    require([privateText containsString:@"[토큰 숨김]"], @"redact bearer and opaque tokens");
    require([privateText containsString:@"[경로 숨김]"], @"redact paths");
    require(![privateText containsString:@"private.test"] && ![privateText containsString:@"secret"] &&
            ![privateText containsString:@"/Users/test"] && ![privateText containsString:@"abcdefghijklmnopqrstuvwxyz"], @"safe text omits sensitive values");

    NSString *uuid = @"8B8B33C4-2C77-4B97-90E3-113CC3D32960";
    SGAddonDiagnosticsNameSource(uuid,@"Lossless Bridge");
    require([SGAddonDiagnosticsSourceName(uuid) isEqual:@"Lossless Bridge"],@"safe source name remains available after source deletion");
    NSString *otherUUID=NSUUID.UUID.UUIDString;
    SGAddonDiagnosticsNameSource(otherUUID,@"https://private.test/service?token=secret");
    require(![SGAddonDiagnosticsSourceName(otherUUID) containsString:@"secret"],@"saved source labels redact credentials");
    SGAddonDiagnostic(uuid, @"다운로드", @"응답 수신", @{@"httpStatus": @206, @"receivedBytes": @512,
        @"fileExists": @YES, @"correlation": @0.875, @"errorDomain": @"private.provider", @"providerBody": @"private body", @"url": @"https://secret.test/?token=secret"});
    NSArray<NSDictionary *> *snapshot = SGAddonDiagnosticEvents();
    require(snapshot.count == 1, @"event snapshot contains one entry");
    NSDictionary *first = snapshot.firstObject;
    require([first[@"source"] isEqual:uuid.lowercaseString], @"source ID is canonical UUID");
    require([first[@"stage"] isEqual:@"다운로드"] && [first[@"event"] isEqual:@"응답 수신"], @"Korean stage and event are kept");
    NSDictionary *details = first[@"details"];
    require([details[@"httpStatus"] isEqual:@206] && [details[@"fileExists"] isEqual:@YES], @"allowlisted numeric and boolean details survive");
    require([details[@"correlation"] isEqual:@0.875], @"numeric correlation scores survive");
    require([details[@"errorDomain"] isEqual:@"기타 오류 영역"] && details[@"providerBody"] == nil && details[@"url"] == nil, @"unknown strings and keys are excluded");
    SGAddonDiagnostic(uuid, @"file", @"write failed", @{@"errorDomain": NSCocoaErrorDomain});
    require([SGAddonDiagnosticEvents().lastObject[@"details"][@"errorDomain"] isEqual:NSCocoaErrorDomain], @"standard Cocoa file errors are retained");
    NSMutableString *mutableDomain=[NSCocoaErrorDomain mutableCopy];
    SGAddonDiagnostic(uuid,@"파일",@"쓰기 실패",@{@"errorDomain":mutableDomain});
    [mutableDomain setString:@"https://private.test/token"];
    require([SGAddonDiagnosticEvents().lastObject[@"details"][@"errorDomain"] isEqual:NSCocoaErrorDomain],@"stored diagnostics own immutable copies of string details");
    SGAddonDiagnostic(@"not-a-uuid", @"common", @"event", @{});
    require([SGAddonDiagnosticEvents().lastObject[@"source"] isEqual:@"common"], @"invalid source ID is mapped to common");

    for (NSUInteger i = 0; i < 170; i++) SGAddonDiagnostic(uuid, @"history", [NSString stringWithFormat:@"item%03lu", (unsigned long)i], @{});
    NSArray *bounded = SGAddonDiagnosticEvents();
    require(bounded.count == 160 && [bounded.firstObject[@"event"] isEqual:@"item010"], @"event history is bounded to latest 160 entries");
    require(snapshot.count == 1 && [snapshot[0][@"event"] isEqual:@"응답 수신"], @"returned event snapshots do not mutate");

    for (NSUInteger i = 0; i < 33; i++) SGAddonDiagnosticsBindFile([NSString stringWithFormat:@"/private/path/%lu", (unsigned long)i], uuid);
    require(SGAddonDiagnosticSourceForFile(@"/private/path/0") == nil, @"old file associations are evicted");
    require([SGAddonDiagnosticSourceForFile(@"/private/path/32") isEqual:uuid.lowercaseString], @"new file association is retained");
    SGAddonDiagnosticsBindFile(@"/private/path/invalid", @"bad-id");
    require([SGAddonDiagnosticSourceForFile(@"/private/path/invalid") isEqual:@"common"], @"file map rejects non-UUID source IDs");

    dispatch_apply(400, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
        SGAddonDiagnostic(uuid, @"parallel", [NSString stringWithFormat:@"item%lu", (unsigned long)index], @{@"fileBytes": @(index)});
    });
    require(SGAddonDiagnosticEvents().count == 160, @"parallel writes retain bounded history safely");
    NSLog(@"PASS diagnostics storage and redaction");
} }
