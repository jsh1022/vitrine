#import <UIKit/UIKit.h>
#define SGRKeyPlayerHistory @"spotifyglass.redesign.player.showHistory"
// Extend Spotify's existing queue, keeping its controller, table and controls.
void SGRPlayerUpdateHistory(UIViewController *controller);
void SGRPlayerLayoutHistory(UIViewController *controller);
// A user/remote transport command supersedes a pending history enqueue.
void SGRPlayerHistoryTransportCommand(void);
