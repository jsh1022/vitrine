#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Network/Network.h>
#import <AudioToolbox/AudioToolbox.h>

// Import the production implementation so the fixture invokes its real private delegate.
#import "../../tweak/Sources/Shared/AudioSources/SGAddons.m"

static void require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSHTTPURLResponse *response(NSInteger status, NSDictionary<NSString *, NSString *> *headers) {
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://media.example/audio"]
                                      statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
}

static NSString *newFile(NSString *contents) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return path;
}

static SGAddonTransfer *newTransfer(void) {
    SGAddonTransfer *transfer = [SGAddonTransfer new];
    transfer.done = dispatch_semaphore_create(0);
    return transfer;
}

static SGAddonTransfer *transferForFile(NSString *path, NSUInteger limit, BOOL prefix, NSUInteger offset) {
    SGAddonTransfer *transfer = newTransfer();
    transfer.limit = limit;
    transfer.prefix = prefix;
    transfer.offset = offset;
    transfer.received = offset;
    transfer.file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (offset) [transfer.file seekToEndReturningOffset:NULL error:NULL];
    return transfer;
}

static void receiveResponse(SGAddonTransfer *transfer, NSURLSession *session, NSURLSessionDataTask *task,
                            NSHTTPURLResponse *responseValue, NSURLSessionResponseDisposition *disposition) {
    [transfer URLSession:session dataTask:task didReceiveResponse:responseValue
       completionHandler:^(NSURLSessionResponseDisposition value) { *disposition = value; }];
}

static NSData *fileData(NSString *path) { return [NSData dataWithContentsOfFile:path]; }

int main(void) { @autoreleasepool {
    NSString *path = newFile(@"");
    SGAddonTransfer *prefix = transferForFile(path, 2 * 1024 * 1024, YES, 0);
    NSURLSession *session = NSURLSession.sharedSession;
    NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:@"https://media.example/audio"]];
    NSURLSessionResponseDisposition disposition = NSURLSessionResponseCancel;
    receiveResponse(prefix, session, task, response(200, @{@"ETag": @"\"strong-tag\""}), &disposition);
    require(disposition == NSURLSessionResponseAllow && !prefix.failed, @"200 response accepted for prefix");
    require([prefix.entityTag isEqual:@"\"strong-tag\""], @"ETag retained from response");
    NSMutableData *oversized = [NSMutableData dataWithLength:2 * 1024 * 1024 + 37];
    [prefix URLSession:session dataTask:task didReceiveData:oversized];
    require(prefix.received == 2 * 1024 * 1024 && fileData(path).length == 2 * 1024 * 1024,
            @"prefix response that ignores Range never writes beyond the 2 MiB cap");
    require(prefix.prefixSatisfied && task.state == NSURLSessionTaskStateCanceling,
            @"prefix cancels intentionally at its byte limit");
    NSError *cancel = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
    [prefix URLSession:session task:task didCompleteWithError:cancel];
    require(!prefix.failed, @"intentional prefix cancellation is success");
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];

    path = newFile(@"");
    SGAddonTransfer *rangedPrefix = transferForFile(path, 4, YES, 0);
    task = [session dataTaskWithURL:[NSURL URLWithString:@"https://media.example/audio"]];
    receiveResponse(rangedPrefix, session, task,
                    response(206, @{@"Content-Range": @"bytes 0-3/100", @"ETag": @"\"range-tag\""}),
                    &disposition);
    require(!rangedPrefix.failed && disposition == NSURLSessionResponseAllow &&
            [rangedPrefix.entityTag isEqual:@"\"range-tag\""], @"valid 206 prefix starting at zero is accepted");
    [rangedPrefix URLSession:session dataTask:task didReceiveData:[@"HEAD" dataUsingEncoding:NSUTF8StringEncoding]];
    require([fileData(path) isEqual:[@"HEAD" dataUsingEncoding:NSUTF8StringEncoding]], @"valid 206 prefix writes its range");
    [rangedPrefix URLSession:session task:task didCompleteWithError:nil];
    require(!rangedPrefix.failed, @"valid 206 prefix completes with the expected range length");
    [rangedPrefix.file closeFile];
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];

    path = newFile(@"");
    SGAddonTransfer *malformed = transferForFile(path, 100, YES, 0);
    task = [session dataTaskWithURL:[NSURL URLWithString:@"https://media.example/audio"]];
    receiveResponse(malformed, session, task, response(206, @{@"Content-Range": @"bytes 0-3/*"}), &disposition);
    require(malformed.failed && disposition == NSURLSessionResponseCancel, @"malformed Content-Range is rejected");
    [malformed.file closeFile];
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];

    path = newFile(@"HEAD");
    SGAddonTransfer *resume = transferForFile(path, 100, NO, 4);
    task = [session dataTaskWithURL:[NSURL URLWithString:@"https://media.example/audio"]];
    receiveResponse(resume, session, task, response(206, @{@"Content-Range": @"bytes 4-7/8", @"ETag": @"\"resume-tag\""}), &disposition);
    require(!resume.failed && disposition == NSURLSessionResponseAllow, @"valid 206 offset resume accepted");
    [resume URLSession:session dataTask:task didReceiveData:[@"TAIL" dataUsingEncoding:NSUTF8StringEncoding]];
    require([fileData(path) isEqual:[@"HEADTAIL" dataUsingEncoding:NSUTF8StringEncoding]], @"206 resume appends at the requested offset");
    require([resume.entityTag isEqual:@"\"resume-tag\""], @"resumed response ETag retained");
    [resume URLSession:session task:task didCompleteWithError:nil];
    require(!resume.failed, @"206 resume completes with the full expected length");
    [resume.file closeFile];
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];

    path = newFile(@"HEAD");
    SGAddonTransfer *incompleteRange = transferForFile(path, 100, NO, 4);
    task = [session dataTaskWithURL:[NSURL URLWithString:@"https://media.example/audio"]];
    receiveResponse(incompleteRange, session, task,
                    response(206, @{@"Content-Range": @"bytes 4-7/100"}), &disposition);
    require(incompleteRange.failed && disposition == NSURLSessionResponseCancel,
            @"206 response with a non-terminal range is rejected for resume");
    [incompleteRange.file closeFile];
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];

    path = newFile(@"HEAD");
    SGAddonTransfer *shortRange = transferForFile(path, 100, NO, 4);
    task = [session dataTaskWithURL:[NSURL URLWithString:@"https://media.example/audio"]];
    receiveResponse(shortRange, session, task,
                    response(206, @{@"Content-Range": @"bytes 4-7/8"}), &disposition);
    [shortRange URLSession:session dataTask:task didReceiveData:[@"TA" dataUsingEncoding:NSUTF8StringEncoding]];
    [shortRange URLSession:session task:task didCompleteWithError:nil];
    require(shortRange.failed, @"short 206 completion fails expected-byte validation");
    [shortRange.file closeFile];
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];

    path = newFile(@"old-prefix");
    SGAddonTransfer *restart = transferForFile(path, 100, NO, 10);
    task = [session dataTaskWithURL:[NSURL URLWithString:@"https://media.example/audio"]];
    receiveResponse(restart, session, task, response(200, @{@"ETag": @"\"new-tag\""}), &disposition);
    require(!restart.failed && disposition == NSURLSessionResponseAllow && fileData(path).length == 0,
            @"200 after a resume truncates the old prefix");
    [restart URLSession:session dataTask:task didReceiveData:[@"replacement" dataUsingEncoding:NSUTF8StringEncoding]];
    require([[NSString alloc] initWithData:fileData(path) encoding:NSUTF8StringEncoding] &&
            [[[NSString alloc] initWithData:fileData(path) encoding:NSUTF8StringEncoding] isEqual:@"replacement"],
            @"restarted 200 writes only the replacement body");
    [restart.file closeFile];
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];

    path = newFile(@"");
    SGAddonTransfer *oversizedFile = transferForFile(path, 10, NO, 0);
    task = [session dataTaskWithURL:[NSURL URLWithString:@"https://media.example/audio"]];
    receiveResponse(oversizedFile, session, task, response(200, @{}), &disposition);
    [oversizedFile URLSession:session dataTask:task didReceiveData:[NSMutableData dataWithLength:11]];
    require(oversizedFile.failed && task.state == NSURLSessionTaskStateCanceling && fileData(path).length == 0,
            @"oversized non-prefix response is rejected before writing its chunk");
    [oversizedFile.file closeFile];
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];

    for (NSNumber *status in @[@401, @403]) {
        SGAddonTransfer *unauthorized = newTransfer();
        task = [session dataTaskWithURL:[NSURL URLWithString:@"https://media.example/audio"]];
        NSURLSessionResponseDisposition result = NSURLSessionResponseAllow;
        receiveResponse(unauthorized, session, task, response(status.integerValue, @{}), &result);
        require(unauthorized.failed && result == NSURLSessionResponseCancel,
                [NSString stringWithFormat:@"HTTP %@ is rejected", status]);
    }

    SGAddonTransfer *ordinaryCancel = newTransfer();
    [ordinaryCancel URLSession:session task:task didCompleteWithError:cancel];
    require(ordinaryCancel.failed, @"ordinary cancellation is a failed transfer");

    NSLog(@"PASS: SGAddonTransfer delegate fixtures");
} return 0; }
