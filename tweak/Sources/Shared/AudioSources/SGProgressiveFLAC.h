#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

// One immutable HTTP rendition. Published bytes are contiguous and written before readers are signalled.
// Worker/delegate only; never call these APIs from render. No network I/O is performed here.
@interface SGProgressiveFLAC : NSObject
- (instancetype)initWithPath:(NSString *)path cancelled:(BOOL (^)(void))cancelled;
- (void)publishBytes:(uint64_t)bytes total:(uint64_t)total;
- (void)finish:(BOOL)success;
- (NSDictionary *)probeDuration:(double)expected;
@end

// Off render. Returns YES only for a registered in-flight rendition. The caller disposes the
// ExtAudioFile before releasing owner, which owns its underlying AudioFile and read callbacks.
BOOL SGProgressiveFLACOpen(NSString *path, ExtAudioFileRef *file, CFTypeRef *owner, BOOL (^cancelled)(void));
// Detailed status is internal numeric decoder data only; never includes a URL or path.
BOOL SGProgressiveFLACOpenWithStatus(NSString *path, ExtAudioFileRef *file, CFTypeRef *owner, BOOL (^cancelled)(void), OSStatus *failure);
NSDictionary *SGProgressiveFLACState(NSString *path);
BOOL SGProgressiveFLACRegistered(NSString *path);
NSDictionary *SGProgressiveFLACInfo(NSString *path);
BOOL SGProgressiveFLACComplete(NSString *path);
void SGProgressiveFLACForgetAll(void);
