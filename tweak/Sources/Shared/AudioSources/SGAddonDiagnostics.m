#import "SGAddonDiagnostics.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

static const NSUInteger SGAddonEventLimit = 160;
static const NSUInteger SGAddonFileLimit = 32;

static NSObject *SGAddonDiagnosticsLock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static NSMutableArray<NSDictionary *> *SGAddonEventStore(void) {
    static NSMutableArray *events; static dispatch_once_t once;
    dispatch_once(&once, ^{ events = [NSMutableArray new]; });
    return events;
}
static NSMutableDictionary<NSString *, NSString *> *SGAddonFileStore(void) {
    static NSMutableDictionary *files; static dispatch_once_t once;
    dispatch_once(&once, ^{ files = [NSMutableDictionary new]; });
    return files;
}
static NSMutableArray<NSString *> *SGAddonFileOrder(void) {
    static NSMutableArray *order; static dispatch_once_t once;
    dispatch_once(&once, ^{ order = [NSMutableArray new]; });
    return order;
}

NSString *SGAddonDiagnosticsSafeSourceID(NSString *sourceID) {
    if (![sourceID isKindOfClass:NSString.class]) return @"common";
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:sourceID];
    return uuid ? uuid.UUIDString.lowercaseString : @"common";
}

NSString *SGAddonDiagnosticsSafeText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length > 4096) return @"[긴 텍스트 숨김]";
    NSMutableString *safe = [NSMutableString new];
    NSCharacterSet *controls = NSCharacterSet.controlCharacterSet;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ([controls characterIsMember:c]) [safe appendString:@" "];
        else [safe appendFormat:@"%C", (unichar)c];
    }
    NSArray<NSString *> *patterns = @[
        @"(?i)https?://[^\\s]+",
        @"(?i)\\bBearer\\s+[A-Za-z0-9._~-]{12,}",
        @"\\b[A-Za-z0-9_-]{24,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\b",
        @"(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{24,}(?![A-Za-z0-9_-])",
        @"(?:/[^\\s]+){2,}",
        @"[?&][^\\s=]+=[^\\s&]+"
    ];
    NSArray<NSString *> *replacements = @[@"[주소 숨김]", @"[토큰 숨김]", @"[토큰 숨김]", @"[토큰 숨김]", @"[경로 숨김]", @"?[값 숨김]"];
    for (NSUInteger i = 0; i < patterns.count; i++) {
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:patterns[i] options:0 error:nil];
        if (regex) [safe setString:[regex stringByReplacingMatchesInString:safe options:0 range:NSMakeRange(0, safe.length) withTemplate:replacements[i]]];
    }
    NSString *trimmed = [safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return @"알 수 없음";
    return trimmed.length > 120 ? [[trimmed substringToIndex:120] stringByAppendingString:@"…"] : [trimmed copy];
}

static NSDictionary *SGAddonSafeDetails(NSDictionary *details) {
    NSSet *numbers = [NSSet setWithArray:@[@"httpStatus", @"errorCode", @"receivedBytes", @"expectedBytes", @"fileBytes", @"correlation"]];
    NSSet *booleans = [NSSet setWithArray:@[@"fileExists", @"growing", @"complete", @"cancelled", @"timeout", @"epochChanged", @"generationChanged"]];
    NSMutableDictionary *safe = [NSMutableDictionary new];
    if (![details isKindOfClass:NSDictionary.class]) return safe;
    for (id key in details) {
        id value = details[key];
        if ([numbers containsObject:key] && [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) {
            double number = [value doubleValue];
            if (isfinite(number) && fabs(number) <= 9.0e15) safe[key] = value;
        } else if ([booleans containsObject:key] && [value isKindOfClass:NSNumber.class]) {
            safe[key] = @([value boolValue]);
        } else if ([key isEqual:@"errorDomain"] && [value isKindOfClass:NSString.class]) {
            NSString *domain = value;
            safe[key] = ([domain isEqual:NSURLErrorDomain] || [domain isEqual:NSCocoaErrorDomain] || [domain isEqual:@"NSOSStatusErrorDomain"]) ? [domain copy] : @"기타 오류 영역";
        } else if ([key isEqual:@"correlation"] && [value isKindOfClass:NSString.class]) {
            safe[key] = SGAddonDiagnosticsSafeText(value);
        }
    }
    return [safe copy];
}

static NSMutableDictionary *sg_sourceNames;
void SGAddonDiagnosticsNameSource(NSString *sourceID, NSString *name) {
    NSString *identifier=SGAddonDiagnosticsSafeSourceID(sourceID);
    if ([identifier isEqual:@"common"] || ![name isKindOfClass:NSString.class] || !name.length) return;
    NSString *safe=SGAddonDiagnosticsSafeText(name);
    @synchronized(SGAddonDiagnosticsLock()) {
        if (!sg_sourceNames) sg_sourceNames=[NSMutableDictionary dictionary];
        if (sg_sourceNames.count>=32 && !sg_sourceNames[identifier]) [sg_sourceNames removeObjectForKey:sg_sourceNames.allKeys.firstObject];
        sg_sourceNames[identifier]=safe;
    }
}
NSString *SGAddonDiagnosticsSourceName(NSString *sourceID) {
    @synchronized(SGAddonDiagnosticsLock()) { return sg_sourceNames[SGAddonDiagnosticsSafeSourceID(sourceID)]; }
}
void SGAddonDiagnostic(NSString *sourceID, NSString *stage, NSString *event, NSDictionary *details) {
    NSDictionary *entry = @{@"time": [NSDate date], @"source": SGAddonDiagnosticsSafeSourceID(sourceID),
        @"stage": SGAddonDiagnosticsSafeText(stage), @"event": SGAddonDiagnosticsSafeText(event),
        @"details": [SGAddonSafeDetails(details) copy]};
    @synchronized(SGAddonDiagnosticsLock()) {
        NSMutableArray *events = SGAddonEventStore();
        [events addObject:entry];
        if (events.count > SGAddonEventLimit) [events removeObjectsInRange:NSMakeRange(0, events.count - SGAddonEventLimit)];
    }
}
NSArray<NSDictionary *> *SGAddonDiagnosticEvents(void) {
    @synchronized(SGAddonDiagnosticsLock()) { return [SGAddonEventStore() copy]; }
}
void SGAddonDiagnosticsBindFile(NSString *path, NSString *sourceID) {
    if (![path isKindOfClass:NSString.class] || !path.length) return;
    @synchronized(SGAddonDiagnosticsLock()) {
        NSMutableDictionary *files = SGAddonFileStore(); NSMutableArray *order = SGAddonFileOrder();
        [files removeObjectForKey:path]; [order removeObject:path];
        files[path] = SGAddonDiagnosticsSafeSourceID(sourceID); [order addObject:path];
        while (order.count > SGAddonFileLimit) { [files removeObjectForKey:order.firstObject]; [order removeObjectAtIndex:0]; }
    }
}
NSString *SGAddonDiagnosticSourceForFile(NSString *path) {
    if (![path isKindOfClass:NSString.class]) return nil;
    @synchronized(SGAddonDiagnosticsLock()) { return SGAddonFileStore()[path]; }
}
