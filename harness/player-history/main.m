#import <UIKit/UIKit.h>
#import "Redesigned/Player/PlayerHistory.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"
@interface SPTPlayerTrack ()
@property(nonatomic, readwrite) id URI;
@property(nonatomic, readwrite) NSString *artistName, *trackTitle;
@property(nonatomic, readwrite) NSDictionary *metadata;
@property(nonatomic, readwrite, copy) NSString *provider;
@end
@interface SPTPlayerState ()
@property(nonatomic, readwrite) SPTPlayerTrack *track;
@property(nonatomic, readwrite) id contextURI;
@property(nonatomic, readwrite) NSArray *future, *reverse;
@property(nonatomic, readwrite) double duration;
@end
extern void SGRHarnessSetState(SPTPlayerState *);
extern void SGRHarnessSetEnabled(BOOL);
extern void SGRHarnessSetPlayer(id);
extern UIViewController *SGRHarnessPresented(void);
static int checks;
static void check(BOOL ok, NSString *name) { checks++; if (!ok) { NSLog(@"FAIL player-history: %@",name); exit(1); } NSLog(@"PASS check %d: %@",checks,name); }
static SPTPlayerTrack *track(NSString *uri, NSString *title) { SPTPlayerTrack *t=[SPTPlayerTrack new]; t.URI=uri; t.trackTitle=title; t.artistName=@"Vitrine test artist"; t.provider=@"context"; return t; }
static SPTPlayerState *state(SPTPlayerTrack *current, NSArray *reverse, NSArray *future) { SPTPlayerState *s=[SPTPlayerState new]; s.track=current; s.reverse=reverse; s.future=future; s.contextURI=@"spotify:playlist:test"; return s; }
@interface SGRHarnessDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation SGRHarnessDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
 self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.window.rootViewController=[UIViewController new]; [self.window makeKeyAndVisible];
 dispatch_async(dispatch_get_main_queue(), ^{
  @try {
   SPTPlayerTrack *old=track(@"spotify:track:old",@"한국어 긴 제목 — 이전 곡");
   SPTPlayerTrack *current=track(@"spotify:track:current",@"현재 곡");
   SPTPlayerTrack *next=track(@"spotify:track:next",@"다음 곡");
   SPTPlayerState *initial=state(current,@[old,old],@[next]); SGRHarnessSetState(initial);
   NSObject *fake=[NSClassFromString(@"SGRFakePlayer") new]; SGRHarnessSetPlayer(fake);
   UIView *queue=[[UIView alloc] initWithFrame:CGRectMake(0,0,100,44)]; SGRPlayerAttachHistory(queue);
   check(queue.subviews.count==1 && [queue.subviews.firstObject.accessibilityLabel containsString:@"이전 곡"],@"history overlay attaches to Spotify queue");
   SGRHarnessSetEnabled(NO); SGRPlayerAttachHistory(queue);
   check(queue.subviews.count==0 && !SGRPlayerShowHistory(),@"off removes overlay and show returns NO");
   SGRHarnessSetEnabled(YES); SGRPlayerAttachHistory(queue);
   check(SGRPlayerShowHistory(),@"enabled show opens");
   UINavigationController *nav=(id)SGRHarnessPresented(); UITableViewController *table=(id)nav.topViewController;
   self.window.rootViewController=nav;
   table.traitOverrides.preferredContentSizeCategory=UIContentSizeCategoryAccessibilityExtraExtraExtraLarge;
   [table loadViewIfNeeded];
   check([table.traitCollection.preferredContentSizeCategory isEqual:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge],@"table receives accessibility Dynamic Type traits");
   check([table numberOfSectionsInTableView:table.tableView]==3,@"history/current/future are separate sections");
   check([table tableView:table.tableView numberOfRowsInSection:0]==2 && [table tableView:table.tableView numberOfRowsInSection:1]==1 && [table tableView:table.tableView numberOfRowsInSection:2]==1,@"history duplicates preserved with current and future");
   check([[table tableView:table.tableView titleForHeaderInSection:0] containsString:@"이전"] && [[table tableView:table.tableView titleForHeaderInSection:1] containsString:@"현재"] && [[table tableView:table.tableView titleForHeaderInSection:2] containsString:@"다음"],@"section names distinguish history/current/future");
   NSIndexPath *history=[NSIndexPath indexPathForRow:1 inSection:0];
   [table tableView:table.tableView didSelectRowAtIndexPath:history];
   NSArray *calls=[fake valueForKey:@"calls"];
   check(calls.count==1 && calls[0][@"track"]==old,@"targeted previous replays exact duplicate native track object");
   SPTPlayerTrack *updatedNext=track(@"spotify:track:new-next",@"새 다음 곡");
   SGRHarnessSetState(state(current,@[old],@[updatedNext]));
   [table tableView:table.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
   calls=[fake valueForKey:@"calls"];
   check(calls.count==2 && calls[1][@"track"]==updatedNext,@"targeted next sends current native future object");
   NSUInteger before=calls.count; SPTPlayerTrack *different=track(@"spotify:track:changed",@"changed"); SGRHarnessSetState(state(different,@[],@[next]));
   [table tableView:table.tableView didSelectRowAtIndexPath:history];
   calls=[fake valueForKey:@"calls"];
   check(calls.count==before,@"stale index snapshot rejected after queue changes");
   check(calls.count==2 && [calls[0][@"options"] isEqual:NSNull.null] && [calls[0][@"params"] isEqual:NSNull.null] && [calls[1][@"options"] isEqual:NSNull.null] && [calls[1][@"params"] isEqual:NSNull.null],@"commands use native targeted selectors with nil options and logging");
   SGRHarnessSetState(initial);
   NSIndexPath *longIndex=[NSIndexPath indexPathForRow:0 inSection:0];
   [table.tableView reloadData]; [nav.view setNeedsLayout]; [nav.view layoutIfNeeded]; [self.window layoutIfNeeded];
   [table.tableView scrollToRowAtIndexPath:longIndex atScrollPosition:UITableViewScrollPositionTop animated:NO];
   [table.tableView layoutIfNeeded];
   UITableViewCell *longCell=[table.tableView cellForRowAtIndexPath:longIndex];
   check(longCell!=nil && longCell.window==self.window,@"long-title test uses a visible table cell in the window");
   check(longCell.textLabel.numberOfLines==0 && longCell.textLabel.adjustsFontForContentSizeCategory,@"long Korean title wraps and follows Dynamic Type");
   check(longCell.textLabel.font.pointSize > [UIFont preferredFontForTextStyle:UIFontTextStyleBody].pointSize,@"accessibility Dynamic Type enlarges row text");
   NSLog(@"PASS player-history: %d checks (native targeted replay, duplicate history, stale snapshot, toggle, sections, wrapping)",checks); exit(0);
  } @catch (NSException *e) { NSLog(@"FAIL player-history exception: %@\n%@",e,[NSThread callStackSymbols]); exit(1); }
 }); return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(SGRHarnessDelegate.class)); } }
