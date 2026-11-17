#import <UIKit/UIKit.h>
#import "Headers/SPTPlayer.h"
#import "Shared/Player/PlayerState.h"
#import "Redesigned/Player/PlayerHistory.h"
static BOOL sg_enabled = YES;
static SPTPlayerState *sg_state;
static id sg_player;
static id<SGPlayerStateObserver> sg_observer;
static UIViewController *sg_presented;
BOOL SGRedesignedUI(void) { return YES; }
BOOL SGFlag(NSString *key, BOOL fallback) { return [key isEqual:SGRKeyPlayerHistory] ? sg_enabled : fallback; }
void SGPresentDark(UIViewController *controller) { sg_presented = controller; }
BOOL SGOpenSpotifyURI(NSURL *uri) { return YES; }
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) { sg_observer = observer; }
SPTPlayerState *SGPlayerState(void) { return sg_state; }
id SGPlayer(void) { return sg_player; }
NSString *SGURIString(id uri) { return [uri isKindOfClass:NSString.class] ? uri : nil; }
@interface SPTPlayerTrack ()
@property(nonatomic, readwrite) id URI;
@property(nonatomic, readwrite) NSString *artistName, *trackTitle;
@property(nonatomic, readwrite) NSDictionary *metadata;
@property(nonatomic, readwrite, copy) NSString *provider;
@end
@implementation SPTPlayerTrack @end
@interface SPTPlayerState ()
@property(nonatomic, readwrite) SPTPlayerTrack *track;
@property(nonatomic, readwrite) id contextURI;
@property(nonatomic, readwrite) NSArray *future, *reverse;
@property(nonatomic, readwrite) double duration;
@end
@implementation SPTPlayerState @end
@interface SGRFakePlayer : NSObject
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *calls;
@end
@implementation SGRFakePlayer
- (instancetype)init { if ((self=[super init])) _calls=[NSMutableArray array]; return self; }
- (id)skipToPreviousTrackWithOptions:(id)o track:(id)t loggingParams:(id)p { [_calls addObject:@{@"selector":NSStringFromSelector(_cmd),@"options":o ?: NSNull.null,@"track":t,@"params":p ?: NSNull.null}]; return nil; }
- (id)skipToNextTrackWithOptions:(id)o track:(id)t loggingParams:(id)p { [_calls addObject:@{@"selector":NSStringFromSelector(_cmd),@"options":o ?: NSNull.null,@"track":t,@"params":p ?: NSNull.null}]; return nil; }
- (id)setShufflingContext:(BOOL)v { [_calls addObject:@{@"selector":NSStringFromSelector(_cmd)}]; return nil; }
- (id)setRepeatingContext:(BOOL)v { [_calls addObject:@{@"selector":NSStringFromSelector(_cmd)}]; return nil; }
- (id)setRepeatingTrack:(BOOL)v { [_calls addObject:@{@"selector":NSStringFromSelector(_cmd)}]; return nil; }
@end
void SGRHarnessSetState(SPTPlayerState *state) { sg_state=state; if (sg_observer) [sg_observer playerStateDidReport:state]; }
void SGRHarnessSetEnabled(BOOL enabled) { sg_enabled=enabled; }
void SGRHarnessSetPlayer(id player) { sg_player=player; }
UIViewController *SGRHarnessPresented(void) { return sg_presented; }
