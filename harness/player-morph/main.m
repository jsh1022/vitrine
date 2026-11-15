#import "Core/SGCore.h"
#import "Redesigned/Player/Player.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"
#import "Redesigned/Kit/SGRKit.h"
@interface SGRPlayerMorph : NSObject
- (instancetype)initWithContainer:(UIView *)container overlay:(UIView *)overlay bar:(UIView *)bar barRest:(CGRect)rest;
- (void)followFrom:(UIView *)source opening:(BOOL)opening;
- (void)apply:(CGFloat)t;
- (void)tearDown;
@end
static BOOL coverHidden, coverReady;
BOOL SGRedesignedUI(void) { return YES; }
BOOL SGRReduceMotion(void) { return NO; }
const CGFloat SGRRadiusArtwork = 12;
void SGRequireClasses(NSArray *names) {}
SGRArtworkField *SGRPlayerField(void) { return nil; }
CGRect SGRNowPlayingCardFrameIn(UIView *host, CGFloat *radius) { if (radius) *radius=28; return CGRectMake(20,700,350,56); }
CGRect SGRNowPlayingArtworkFrameIn(UIView *host) { return CGRectMake(28,708,40,40); }
UIImage *SGRNowPlayingArtwork(NSString **track, NSString **url) { return [UIImage systemImageNamed:@"music.note"]; }
CGRect SGRNowPlayingStripFrameIn(UIView *host) { return CGRectNull; }
CGFloat SGRNowPlayingStripHeight(void) { return 0; }
CGRect SGRPlayerCoverFrameIn(UIView *host) { return coverReady ? CGRectMake(24,100,342,342) : CGRectNull; }
CGFloat SGRPlayerCoverScale(void) { return 1; }
void SGRPlayerSetCoverHidden(BOOL hidden) { coverHidden=hidden; }
BOOL SGRPlayerMotionShowing(void) { return NO; }
@interface MorphDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation MorphDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
 self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
 self.window.rootViewController=[UIViewController new]; [self.window makeKeyAndVisible];
 dispatch_async(dispatch_get_main_queue(), ^{
  UIView *container=self.window.rootViewController.view;
  UIView *overlay=[[UIView alloc] initWithFrame:container.bounds]; [container addSubview:overlay];
  CALayer *mask=[CALayer layer]; overlay.layer.mask=mask;
  CATransform3D original=CATransform3DMakeScale(0.99,0.99,1); overlay.layer.sublayerTransform=original;
  UIView *bar=[UIView new]; [container addSubview:bar];
  for (NSInteger pass=0; pass<20; pass++) {
   coverReady=NO; coverHidden=NO;
   SGRPlayerMorph *m=[[SGRPlayerMorph alloc] initWithContainer:container overlay:overlay bar:bar barRest:CGRectZero];
   [m followFrom:bar opening:pass%2==0]; [m apply:0.2];
   NSCAssert(!coverHidden, @"cover hidden before destination layout");
   coverReady=YES;
   for (NSNumber *t in @[@0.3,@0.8,@0.4,@1,@0]) [m apply:t.doubleValue];
   NSCAssert(coverHidden, @"real cover must be hidden while stand-in is present");
   [m tearDown]; [m tearDown];
   NSCAssert(!coverHidden && overlay.layer.mask==mask && CATransform3DEqualToTransform(overlay.layer.sublayerTransform,original), @"cancel/finish did not restore original state");
   NSCAssert(container.subviews.count==2, @"transition stand-ins leaked");
  }
  fprintf(stderr,"PASS morph: 20 open/close/reversal cycles, delayed layout, mask/transform restore, idempotent teardown, no stand-ins\n"); exit(0);
 }); return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(MorphDelegate.class)); } }
