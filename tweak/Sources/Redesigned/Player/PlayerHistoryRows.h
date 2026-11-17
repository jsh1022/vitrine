#import <UIKit/UIKit.h>

// Implemented in Swift; the wrapper keeps Spotify's native component alive.
@interface SGRNativeHistoryRow : NSObject
@property(nonatomic, readonly) UIView *view;
@end

@interface SGRNativeHistoryRenderer : NSObject
+ (BOOL)isEditingQueueOf:(UIViewController *)controller;
+ (UIView *)currentTrackContainerOf:(UIViewController *)controller;
+ (SGRNativeHistoryRow *)rowInController:(UIViewController *)controller
                                title:(NSString *)title
                             subtitle:(NSString *)subtitle
                              artwork:(NSURL *)artwork;
@end
