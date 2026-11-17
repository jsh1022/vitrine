#import <Foundation/Foundation.h>

@interface SPTPlayerTrack : NSObject
@property(nonatomic, strong) id URI;
@end

@interface SPTPlayerState : NSObject
@property(nonatomic, strong) SPTPlayerTrack *track;
@property(nonatomic) BOOL isPaused;
@property(nonatomic) BOOL isPlaying;
@end

@protocol SPTPlayer <NSObject>
- (id)pause:(id)options;
- (id)resume:(id)options;
- (id)seekTo:(double)position relative:(long long)relative options:(id)options creatorTimestampPositionMs:(double)creator;
- (id)skipToNextTrackWithOptions:(id)options track:(id)track loggingParams:(id)params;
- (id)skipToPreviousTrackWithOptions:(id)options track:(id)track loggingParams:(id)params;
- (id)stop;
@end

@protocol SGPlayerStateObserver <NSObject>
- (void)playerStateDidChange:(SPTPlayerState *)state;
@end

NSString *SGURIString(id uri);
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer);
SPTPlayerState *SGPlayerState(void);
id<SPTPlayer> SGPlayer(void);
