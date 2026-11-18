// Adapter lifecycle/command fixture only. This does not represent Spotify's UI;
// rendering/ABI are checked separately against the real Spotify executable.
#import <UIKit/UIKit.h>
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"
#import "Redesigned/Player/PlayerHistory.h"
#import "Redesigned/Player/PlayerHistoryRows.h"
static BOOL sg_enabled = YES, sg_redesigned = YES;
static SPTPlayerState *sg_state;
static id sg_player;
static NSHashTable *sg_observers;
static BOOL sg_deferHistoryQueue;
static NSMutableArray *sg_historyQueueCallbacks;
BOOL SGRedesignedUI(void) { return sg_redesigned; }
BOOL SGFlag(NSString *key, BOOL fallback) { return [key isEqual:SGRKeyPlayerHistory] ? sg_enabled : fallback; }
void SGLog(NSString *format, ...) {}
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) { if (!sg_observers) sg_observers=[NSHashTable weakObjectsHashTable]; [sg_observers addObject:observer]; }
SPTPlayerState *SGPlayerState(void) { return sg_state; }
id SGPlayer(void) { return sg_player; }
NSString *SGURIString(id uri) { return [uri isKindOfClass:NSString.class] ? uri : [uri isKindOfClass:NSURL.class] ? [uri absoluteString] : nil; }
@interface SPTPlayerTrack ()
@property(nonatomic, readwrite) id URI;
@property(nonatomic, readwrite) NSString *artistName, *trackTitle;
@property(nonatomic, readwrite) NSDictionary *metadata;
@property(nonatomic, readwrite, copy) NSString *provider;
@property(nonatomic, readwrite, copy) NSString *UID;
- (instancetype)initWithURI:(NSURL *)uri albumURI:(NSURL *)album artistURI:(NSURL *)artist andUID:(NSString *)uid;
@end
@implementation SPTPlayerTrack
- (instancetype)initWithURI:(NSURL *)uri albumURI:(NSURL *)album artistURI:(NSURL *)artist andUID:(NSString *)uid {
    if ((self = [super init])) { _URI = uri; _UID = uid; }
    return self;
}
@end
@interface SPTPlayerState ()
@property(nonatomic, readwrite) SPTPlayerTrack *track;
@property(nonatomic, readwrite) id contextURI;
@property(nonatomic, readwrite) NSArray *future, *reverse;
@property(nonatomic, readwrite) double duration;
@end
@implementation SPTPlayerState @end
@interface SGRFakeQueue : NSObject
@property(nonatomic,copy) NSArray *prevTracks;
@end
@implementation SGRFakeQueue @end
@interface SGRFakeTask : NSObject
@property(nonatomic,copy) void (^success)(id);
@property(nonatomic,copy) void (^failure)(NSError *);
- (void)fulfill;
- (void)fail;
@end
@implementation SGRFakeTask
- (id)addCallback:(void (^)(id))callback on:(dispatch_queue_t)queue { self.success = callback; return self; }
- (id)addErrorCallback:(void (^)(NSError *))callback on:(dispatch_queue_t)queue { self.failure = callback; return self; }
- (void)fulfill { if (self.success) self.success(nil); }
- (void)fail { if (self.failure) self.failure([NSError errorWithDomain:@"harness" code:42 userInfo:nil]); }
@end
@interface SPTPlayerQueueWrapperImpl : NSObject
@property(nonatomic,strong) id player;
- (instancetype)initWithPlayer:(id)player;
- (id)queueTrackPlayNext:(SPTPlayerTrack *)track;
@end
@interface SGRFakePlayer : NSObject
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *calls;
@property(nonatomic,strong) NSMutableArray<SGRFakeTask *> *queueTasks;
@property(nonatomic,strong) NSMutableArray<SGRFakeTask *> *skipTasks;
@property(nonatomic,strong) SPTPlayerTrack *stateTrack;
@property(nonatomic,copy) NSArray<SPTPlayerTrack *> *historyQueueTracks;
- (id)getQueueWithCallback:(void (^)(id))callback;
@end
@implementation SPTPlayerQueueWrapperImpl
- (instancetype)initWithPlayer:(id)player { if ((self=[super init])) _player=player; return self; }
- (id)queueTrackPlayNext:(SPTPlayerTrack *)track { SGRFakePlayer *player=self.player; SGRFakeTask *task=[SGRFakeTask new]; [player.queueTasks addObject:task]; [player.calls addObject:@{@"selector":NSStringFromSelector(_cmd),@"track":track}]; return task; }
@end
@implementation SGRFakePlayer
- (instancetype)init { if ((self=[super init])) { _calls=[NSMutableArray array]; _queueTasks=[NSMutableArray array]; _skipTasks=[NSMutableArray array]; } return self; }
- (id)getQueueWithCallback:(void (^)(id))callback {
    NSLog(@"fake getQueue callback request: defer=%d tracks=%lu",sg_deferHistoryQueue,(unsigned long)self.historyQueueTracks.count);
    NSObject *token=[NSObject new];
    if (sg_deferHistoryQueue) { if (!sg_historyQueueCallbacks) sg_historyQueueCallbacks=[NSMutableArray array]; [sg_historyQueueCallbacks addObject:[callback copy]]; }
    else { SGRFakeQueue *queue=[SGRFakeQueue new]; queue.prevTracks=self.historyQueueTracks; NSLog(@"fake returning prevTracks=%lu",(unsigned long)queue.prevTracks.count); callback(queue); }
    return token;
}
- (id)skipToNextTrackWithOptions:(id)o { [_calls addObject:@{@"selector":NSStringFromSelector(_cmd),@"options":o ?: NSNull.null}]; SGRFakeTask *task=[SGRFakeTask new]; [_skipTasks addObject:task]; return task; }
@end
@interface SGRNativeHistoryRow ()
@property(nonatomic, readwrite, strong) UIView *view;
@end
@implementation SGRNativeHistoryRow @end
@implementation SGRNativeHistoryRenderer
+ (BOOL)isEditingQueueOf:(UIViewController *)controller { return [[controller valueForKey:@"editMode"] boolValue]; }
+ (UIView *)currentTrackContainerOf:(UIViewController *)controller { return [controller valueForKey:@"current"]; }
+ (SGRNativeHistoryRow *)rowInController:(UIViewController *)controller title:(NSString *)title subtitle:(NSString *)subtitle artwork:(NSURL *)artwork {
    if ([[controller valueForKey:@"rendererFails"] boolValue]) return nil;
    SGRNativeHistoryRow *row=[SGRNativeHistoryRow new]; row.view=[UIView new]; row.view.accessibilityLabel=title; return row;
}
@end
void SGRHarnessSetState(SPTPlayerState *state) { sg_state=state; for (id<SGPlayerStateObserver> observer in sg_observers.allObjects) [observer playerStateDidReport:state]; }
void SGRHarnessSetStateWithoutReport(SPTPlayerState *state) { sg_state=state; }
void SGRHarnessSetEnabled(BOOL enabled) { sg_enabled=enabled; }
void SGRHarnessSetRedesigned(BOOL enabled) { sg_redesigned=enabled; }
void SGRHarnessSetPlayer(id player) { sg_player=player; }
void SGRHarnessSetHistoryQueueTracks(NSArray *tracks) { [sg_player setValue:tracks forKey:@"historyQueueTracks"]; }
void SGRHarnessDeferHistoryQueue(BOOL defer) { sg_deferHistoryQueue=defer; if (!defer) [sg_historyQueueCallbacks removeAllObjects]; }
void SGRHarnessCompleteHistoryQueue(NSArray *tracks) {
    NSArray *callbacks=[sg_historyQueueCallbacks copy]; [sg_historyQueueCallbacks removeAllObjects];
    SGRFakeQueue *queue=[SGRFakeQueue new]; queue.prevTracks=tracks;
    for (void (^callback)(id) in callbacks) callback(queue);
}
void SGRHarnessCompleteHistoryQueueAtIndex(NSUInteger index, NSArray *tracks) {
    if (index >= sg_historyQueueCallbacks.count) return;
    void (^callback)(id)=[sg_historyQueueCallbacks[index] copy]; [sg_historyQueueCallbacks removeObjectAtIndex:index];
    SGRFakeQueue *queue=[SGRFakeQueue new]; queue.prevTracks=tracks; callback(queue);
}
