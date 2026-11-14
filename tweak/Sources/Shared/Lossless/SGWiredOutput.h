#import <Foundation/Foundation.h>

#define SGKeyWiredSourceOutput @"spotifyglass.lossless.wiredSourceOutput"
// Worker only, before anchoring. Unknown units/devices retain their existing path.
void SGWiredOutputPrepare(NSString *path);
BOOL SGWiredOutputPreserveLevel(void);
NSDictionary *SGWiredOutputStatus(void);
void SGWiredOutputSettingsChanged(void);
