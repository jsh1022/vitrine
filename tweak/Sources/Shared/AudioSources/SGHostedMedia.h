#import <Foundation/Foundation.h>
// Local, bounded preparation only; credentials/keys must never enter logs or settings.
BOOL SGHostedPrepareMedia(NSDictionary *stream, NSString *path, BOOL (^cancelled)(void), NSString **error);
// Sequential URLSession delegate only. Retains at most one incomplete 2048-byte block.
// Returns nil on invalid input; final flushes the unencrypted short tail exactly once.
@interface SGHostedDeezerDecoder : NSObject
- (instancetype)initWithTrackID:(NSString *)track;
- (NSData *)appendData:(NSData *)data final:(BOOL)final;
@end
