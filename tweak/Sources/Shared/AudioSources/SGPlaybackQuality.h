#import <UIKit/UIKit.h>

// Main thread. Only recently rendered external frames establish source quality.
NSDictionary<NSString *, NSString *> *SGPlaybackQualityInfo(void);
void SGShowPlaybackQuality(UIView *anchor);
