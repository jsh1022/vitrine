#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "Redesigned/Player/PlayerHistory.h"
#import "Headers/SPTPlayer.h"
@interface SPTPlayerTrack ()
@property(nonatomic, readwrite) id URI;
@property(nonatomic, readwrite) NSString *artistName, *trackTitle;
@property(nonatomic, readwrite) NSDictionary *metadata;
@property(nonatomic, readwrite, copy) NSString *provider;
@property(nonatomic, readwrite, copy) NSString *UID;
@end
@interface SPTPlayerState ()
@property(nonatomic, readwrite) SPTPlayerTrack *track;
@property(nonatomic, readwrite) id contextURI;
@property(nonatomic, readwrite) NSArray *future, *reverse;
@property(nonatomic, readwrite) double duration;
@end
extern void SGRHarnessSetState(SPTPlayerState *);
extern void SGRHarnessSetStateWithoutReport(SPTPlayerState *);
extern void SGRHarnessSetEnabled(BOOL);
extern void SGRHarnessSetRedesigned(BOOL);
extern void SGRHarnessSetPlayer(id);
extern void SGRPlayerHistoryTransportCommand(void);
extern void SGRHarnessSetHistoryQueueTracks(NSArray *);
extern void SGRHarnessDeferHistoryQueue(BOOL);
extern void SGRHarnessCompleteHistoryQueueAtIndex(NSUInteger, NSArray *);
extern SPTPlayerState *SGPlayerState(void);
@interface SGRFakeTask : NSObject
- (void)fulfill;
- (void)fail;
@end
static int checks;
static void check(BOOL ok, NSString *name) { checks++; if (!ok) { NSLog(@"FAIL player-history: %@",name); exit(1); } NSLog(@"PASS check %d: %@",checks,name); }
static NSString *uriString(id uri) { return [uri isKindOfClass:NSURL.class] ? [uri absoluteString] : uri; }
static SPTPlayerTrack *track(NSString *uri, NSString *title) { SPTPlayerTrack *t=[SPTPlayerTrack new]; t.URI=uri; t.UID=NSUUID.UUID.UUIDString; t.trackTitle=title; t.artistName=@"fixture"; t.provider=@"context"; return t; }
static SPTPlayerState *state(SPTPlayerTrack *current, NSArray *reverse, NSArray *future) { SPTPlayerState *s=[SPTPlayerState new]; s.track=current; s.reverse=reverse; s.future=future; s.contextURI=@"spotify:playlist:test"; return s; }
@interface QueueFixture : UIViewController <UITableViewDataSource,UITableViewDelegate>
@property(nonatomic,strong) UIStackView *stack;
@property(nonatomic,strong) UIView *current, *titleView;
@property(nonatomic,strong) UITableView *table;
@property(nonatomic) BOOL rendererFails;
@property(nonatomic) BOOL editMode;
@property(nonatomic) NSUInteger futureSelections;
@end
@implementation QueueFixture
- (void)viewDidLoad {
 [super viewDidLoad];self.view.backgroundColor=UIColor.blackColor;
 self.current=[UIView new];self.current.translatesAutoresizingMaskIntoConstraints=NO;
 [self.current.heightAnchor constraintEqualToConstant:64].active=YES;
 self.titleView=[UIView new];[self.titleView.heightAnchor constraintEqualToConstant:44].active=YES;
 self.stack=[[UIStackView alloc] initWithArrangedSubviews:@[self.titleView,self.current]];
 self.stack.axis=UILayoutConstraintAxisVertical;self.stack.spacing=8;self.stack.translatesAutoresizingMaskIntoConstraints=NO;
 self.table=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];self.table.translatesAutoresizingMaskIntoConstraints=NO;self.table.dataSource=self;self.table.delegate=self;self.table.editing=YES;
 [self.view addSubview:self.stack];[self.view addSubview:self.table];
 [NSLayoutConstraint activateConstraints:@[[self.stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.table.topAnchor constraintEqualToAnchor:self.stack.bottomAnchor],[self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return 40; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p { return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]; }
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p { self.futureSelections++; }
@end
@interface RecognizedTap : UITapGestureRecognizer @end
@implementation RecognizedTap
- (UIGestureRecognizerState)state { return UIGestureRecognizerStateRecognized; }
@end
static void replay(UIView *row, UIViewController *queue) {
 // Exercise the production replay method with the actual row's reverse index.
 UITapGestureRecognizer *registered=(id)row.gestureRecognizers.firstObject;
 check(registered!=nil,@"history row has a replay gesture");
 // The production adapter is registered as a weak player observer; get the target
 // from this gesture's UIKit target/action entry rather than exposing a test API.
 NSArray *targets=[registered valueForKey:@"_targets"];
 id target=[targets.firstObject valueForKey:@"target"];
 RecognizedTap *tap=[RecognizedTap new];[row addGestureRecognizer:tap];
 ((void (*)(id,SEL,id))objc_msgSend)(target,NSSelectorFromString(@"replay:"),tap);
 [row removeGestureRecognizer:tap];
}
static id replayTarget(UIView *row) {
 UITapGestureRecognizer *registered=(id)row.gestureRecognizers.firstObject;
 NSArray *targets=[registered valueForKey:@"_targets"];
 return [targets.firstObject valueForKey:@"target"];
}
@interface SGRHarnessDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation SGRHarnessDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
 self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[QueueFixture new];[self.window makeKeyAndVisible];
 dispatch_async(dispatch_get_main_queue(), ^{
  @try {
   QueueFixture *q=(id)self.window.rootViewController;[q.view layoutIfNeeded];
   UIView *original=q.current;id source=q.table.dataSource, delegate=q.table.delegate;
   id player=[NSClassFromString(@"SGRFakePlayer") new];SGRHarnessSetPlayer(player);
   SPTPlayerTrack *a=track(@"spotify:track:same",@"oldest"), *b=track(@"spotify:track:same",@"nearest"), *now=track(@"spotify:track:now",@"now"), *next=track(@"spotify:track:next",@"next");
   SPTPlayerState *initial=state(now,@[a,b],@[next]);SGRHarnessSetState(initial);
   SGRHarnessSetEnabled(NO);SGRPlayerUpdateHistory(q);
   check(q.table.tableHeaderView==nil && [q.stack.arrangedSubviews containsObject:original],@"off keeps the unmodified native current row and queue");
   SGRHarnessSetEnabled(YES);SGRPlayerUpdateHistory(q);[q.view layoutIfNeeded];
   UIView *header=q.table.tableHeaderView;
   check(header!=nil && q.presentedViewController==nil,@"history opens inside the original queue, without presenting another controller");
   check(q.table.dataSource==source && q.table.delegate==delegate,@"original future data source and delegate stay unchanged");
   check(original.superview==header && ![q.stack.arrangedSubviews containsObject:original],@"the same native current-track view shares table scrolling with history");
   NSArray *rows=[header valueForKey:@"rows"];
   check(rows.count==2,@"duplicate track URIs remain separate history rows");
   UIView *oldest=[rows[0] valueForKey:@"view"], *nearest=[rows[1] valueForKey:@"view"];
  check([oldest.accessibilityLabel isEqual:@"oldest"] && [nearest.accessibilityLabel isEqual:@"nearest"] && oldest.tag==0 && nearest.tag==1,@"history is chronological and row tags follow displayed order");
   check(CGRectGetMaxY(oldest.frame)<=nearest.frame.origin.y && CGRectGetMaxY(nearest.frame)<=original.frame.origin.y,@"history lies above current without overlapping rows");
   check(fabs(header.frame.size.height-200)<0.5,@"header includes two native-height rows, current row and the original gap");
  replay(oldest,q);NSArray *calls=[player valueForKey:@"calls"];NSArray *queueTasks=[player valueForKey:@"queueTasks"];
  check(q.table.editing && calls.count==1 && [calls[0][@"selector"] isEqual:@"queueTrackPlayNext:"] && [calls[0][@"track"] isKindOfClass:SPTPlayerTrack.class],@"replay enqueues a fresh synthetic track through Spotify's queue wrapper");
  SPTPlayerTrack *synthetic=calls[0][@"track"];
  check(synthetic!=a && [uriString(synthetic.URI) isEqual:uriString(a.URI)] && synthetic.UID==nil,@"synthetic queue target preserves URI and leaves occurrence UID unset for Spotify");
  replay(nearest,q);check([[player valueForKey:@"queueTasks"] count]==1,@"repeated taps are ignored while queue task is pending");
  [queueTasks[0] fulfill];calls=[player valueForKey:@"calls"];
  check(calls.count==2 && [calls[1][@"selector"] isEqual:@"skipToNextTrackWithOptions:"] && [calls[1][@"options"] isEqual:NSNull.null],@"enqueue fulfillment issues Spotify's one-argument next-track command");
  check([SGPlayerState() track]==now,@"enqueue fulfillment alone does not claim playback changed");
  check([[player valueForKey:@"skipTasks"] count]==1,@"guarded skip task is tracked separately from enqueue task");
  [[[player valueForKey:@"skipTasks"] firstObject] fulfill];
  check([[replayTarget(oldest) valueForKey:@"replayTargetURI"] isEqual:@"spotify:track:same"],@"skip task fulfillment alone keeps replay pending until playback state changes");
  SPTPlayerTrack *played=track(@"spotify:track:same",@"oldest");
  check(![played.UID isEqual:now.UID],@"state confirmation requires a new track occurrence UID");
  SGRHarnessSetState(state(played,@[now,b],@[next]));
  check(q.presentedViewController==nil,@"matching URI and new UID state report confirms replay without an alert");
  q.editMode=YES;replay([[((NSArray *)[q.table.tableHeaderView valueForKey:@"rows"]) lastObject] valueForKey:@"view"],q);check([[player valueForKey:@"queueTasks"] count]==1,@"read-only history does not issue playback commands during native Edit mode");q.editMode=NO;
  SPTPlayerTrack *fresh=track(@"spotify:track:same",@"nearest");fresh.UID=b.UID;
  rows=[q.table.tableHeaderView valueForKey:@"rows"];nearest=[[rows lastObject] valueForKey:@"view"];
  SGRHarnessSetState(state(played,@[now,fresh],@[next]));
  rows=[q.table.tableHeaderView valueForKey:@"rows"];
  check([[rows lastObject] valueForKey:@"view"]==nearest,@"same-identity state report reuses the existing history row");
  replay(nearest,q);queueTasks=[player valueForKey:@"queueTasks"];
  check(queueTasks.count==2 && [uriString(((SPTPlayerTrack *)[[player valueForKey:@"calls"] lastObject][@"track"]).URI) isEqual:uriString(fresh.URI)],@"reused row still enqueues the selected URI through Spotify's wrapper");
  SGRHarnessSetStateWithoutReport(state(played,@[now],@[next]));replay(nearest,q);
  check([[player valueForKey:@"queueTasks"] count]==2,@"duplicate tap is ignored while enqueue is pending");
  [queueTasks[1] fail];check(q.presentedViewController!=nil,@"SPTask error clears pending replay and presents failure");[q.presentedViewController dismissViewControllerAnimated:NO completion:nil];
  SGRHarnessSetState(state(played,@[now,fresh],@[next]));
  rows=[q.table.tableHeaderView valueForKey:@"rows"];nearest=[[rows lastObject] valueForKey:@"view"];
  SGRHarnessSetStateWithoutReport(state(played,@[now],@[next]));replay(nearest,q);
  check([[player valueForKey:@"queueTasks"] count]==2 && ((NSArray *)[q.table.tableHeaderView valueForKey:@"rows"]).count==1,@"a stale history snapshot is rejected after a queue change with no command pending");
  rows=[q.table.tableHeaderView valueForKey:@"rows"];oldest=[[rows firstObject] valueForKey:@"view"];
  replay(oldest,q);queueTasks=[player valueForKey:@"queueTasks"];
  check(queueTasks.count==3,@"failed replay can be retried");
  [queueTasks[2] fulfill];NSUInteger beforeTimeout=[[player valueForKey:@"calls"] count];
  check(beforeTimeout==5 && [[player valueForKey:@"skipTasks"] count]==2,@"retry enqueue fulfillment submits one next-track command");
  id adapter=replayTarget(oldest);NSUInteger serial=[[adapter valueForKey:@"replaySerial"] unsignedIntegerValue];
  ((void (*)(id,SEL,id))objc_msgSend)(adapter,NSSelectorFromString(@"replayTimedOut:"),@(serial));
  check(q.presentedViewController!=nil,@"unconfirmed playback times out and presents a recoverable failure");[q.presentedViewController dismissViewControllerAnimated:NO completion:nil];
  rows=[q.table.tableHeaderView valueForKey:@"rows"];nearest=[[rows lastObject] valueForKey:@"view"];
  replay(nearest,q);queueTasks=[player valueForKey:@"queueTasks"];
  check(queueTasks.count==4,@"timeout releases pending state for retry");
  [queueTasks[2] fulfill];
  check([[adapter valueForKey:@"replayTask"] isEqual:queueTasks[3]],@"late completion from timed-out request cannot clear newer pending task");
  NSUInteger priorSkips=[[player valueForKey:@"skipTasks"] count];
  SGRPlayerHistoryTransportCommand();[queueTasks[3] fulfill];
  check([[player valueForKey:@"skipTasks"] count]==priorSkips && [adapter valueForKey:@"replayTargetURI"]==nil,@"external transport command cancels a stale enqueue callback");
  rows=[q.table.tableHeaderView valueForKey:@"rows"];nearest=[[rows lastObject] valueForKey:@"view"];
  replay(nearest,q);queueTasks=[player valueForKey:@"queueTasks"];
  check(queueTasks.count==5,@"external command cancellation releases replay for another attempt");
  SPTPlayerTrack *unrelated=track(@"spotify:track:unrelated",@"unrelated");SGRHarnessSetState(state(unrelated,@[b,a],@[next]));
  NSUInteger skipCount=[[player valueForKey:@"skipTasks"] count];[queueTasks[4] fulfill];
  check([[player valueForKey:@"skipTasks"] count]==skipCount,@"unrelated current-track report cancels enqueue before skip");
  [queueTasks[4] fail];
   [q.table.delegate tableView:q.table didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
   check(q.futureSelections==1,@"future selections still reach Spotify's original delegate");
   SGRHarnessSetState(state(now,@[a,b],@[next]));
   NSLayoutConstraint *currentHeight=q.current.constraints.firstObject;
   currentHeight.constant=96;SGRPlayerLayoutHistory(q);
   check(fabs(q.table.tableHeaderView.frame.size.height-296)<0.5,@"two history rows and current row follow larger native measurements");
   currentHeight.constant=64;SGRPlayerLayoutHistory(q);
   check(fabs(q.table.tableHeaderView.frame.size.height-200)<0.5,@"two history rows shrink again with native row measurements");
   UIView *removedNearest=[[[q.table.tableHeaderView valueForKey:@"rows"] lastObject] valueForKey:@"view"];
   SGRHarnessSetState(state(now,@[b,a],@[next]));
   NSArray *beforeRemovedTap=[player valueForKey:@"queueTasks"];
   replay(removedNearest,q);
   check([[player valueForKey:@"queueTasks"] count]==beforeRemovedTap.count,@"a gesture queued on a removed history row cannot replay a different fresh row");
   NSMutableArray *many=[NSMutableArray array];for(int i=0;i<35;i++)[many addObject:track([NSString stringWithFormat:@"spotify:track:%d",i],[NSString stringWithFormat:@"track %d",i])];
   SGRHarnessSetState(state(now,many,@[next]));[q.view layoutIfNeeded];header=q.table.tableHeaderView;rows=[header valueForKey:@"rows"];
   check(rows.count==25 && [[[rows.firstObject valueForKey:@"view"] accessibilityLabel] isEqual:@"track 10"] && [[[rows.lastObject valueForKey:@"view"] accessibilityLabel] isEqual:@"track 34"],@"newest chronological suffix of 25 history entries is shown");
   check(header.frame.size.height>q.table.bounds.size.height && q.table.contentSize.height>header.frame.size.height,@"long history stays in the original table scroll with future rows");
   check(q.table.dataSource==source && q.table.delegate==delegate,@"history updates do not replace future editing/reorder ownership");
   NSMutableArray *completeHistory=[NSMutableArray array];
   for (NSUInteger i=0;i<6;i++) [completeHistory addObject:track([NSString stringWithFormat:@"spotify:track:complete-%lu",(unsigned long)i],[NSString stringWithFormat:@"complete %lu",(unsigned long)i])];
   SGRHarnessSetHistoryQueueTracks(completeHistory);SGRPlayerUpdateHistory(q);
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),dispatch_get_main_queue(),^{
    header=q.table.tableHeaderView;rows=[header valueForKey:@"rows"];
    check(rows.count==6 && [[[rows.firstObject valueForKey:@"view"] accessibilityLabel] isEqual:@"complete 0"] && [[[rows.lastObject valueForKey:@"view"] accessibilityLabel] isEqual:@"complete 5"],@"complete native prevTracks supplies history beyond the short state reverse window");
    SGRHarnessDeferHistoryQueue(YES);SGRPlayerUpdateHistory(q);
    SPTPlayerTrack *changedCurrent=track(@"spotify:track:new-context-current",@"new context current");
    SPTPlayerTrack *newOld=track(@"spotify:track:new-context-old",@"new context old");
    SPTPlayerTrack *newNear=track(@"spotify:track:new-context-near",@"new context near");
    SGRHarnessSetState(state(changedCurrent,@[newOld,newNear],@[next]));
    rows=[q.table.tableHeaderView valueForKey:@"rows"];
    check(rows.count==2 && [[[rows.firstObject valueForKey:@"view"] accessibilityLabel] isEqual:@"new context old"],@"new playback identity immediately falls back to its own state history");
    SGRHarnessCompleteHistoryQueueAtIndex(0,completeHistory);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),dispatch_get_main_queue(),^{
     rows=[q.table.tableHeaderView valueForKey:@"rows"];
     check(rows.count==2 && [[[rows.firstObject valueForKey:@"view"] accessibilityLabel] isEqual:@"new context old"],@"late full-queue response from the prior playback identity is ignored");
     SGRHarnessDeferHistoryQueue(NO);SGRHarnessSetHistoryQueueTracks(nil);
     SGRHarnessSetEnabled(NO);SGRPlayerLayoutHistory(q);[q.view layoutIfNeeded];
     check(q.table.tableHeaderView==nil && q.stack.arrangedSubviews[1]==original && !original.translatesAutoresizingMaskIntoConstraints,@"turning off restores the original current view, position and layout policy");
     SGRHarnessSetEnabled(YES);SGRHarnessSetState(initial);SGRPlayerUpdateHistory(q);
     check(q.table.tableHeaderView!=nil,@"re-enabling rebuilds history in the same original queue");
     SGRHarnessSetState(state(now,@[],@[next]));
     check(q.table.tableHeaderView==nil && original.superview==q.stack,@"empty reverse history restores the native queue without empty replacement UI");
     q.rendererFails=YES;SGRHarnessSetState(initial);
     check(q.table.tableHeaderView==nil && original.superview==q.stack,@"unsupported native renderer leaves native queue functional");q.rendererFails=NO;
     SGRHarnessSetRedesigned(NO);SGRPlayerUpdateHistory(q);
     check(q.table.tableHeaderView==nil,@"Native UI is unchanged");
     NSLog(@"PASS player-history: %d checks (native queue adapter, exact targeted replay, duplicates, stale state, cap, scrolling, restoration)",checks);exit(0);
    });
   });
  } @catch(NSException *e) { NSLog(@"FAIL player-history exception: %@\n%@",e,[NSThread callStackSymbols]);exit(1); }
 });return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(SGRHarnessDelegate.class)); } }
