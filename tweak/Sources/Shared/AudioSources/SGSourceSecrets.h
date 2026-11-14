#import <Foundation/Foundation.h>

// Credentials stay out of NSUserDefaults and settings backups.
NSString *SGSourceSecret(NSString *account);
BOOL SGSaveSourceSecret(NSString *account, NSString *value);
