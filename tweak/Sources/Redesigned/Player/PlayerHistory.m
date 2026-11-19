// History extends Spotify's existing queue. Its native current-track view moves
// into the same scrolling header as native TrackRowQueue history rows; the title,
// table data source, future cells, editing, shuffle/repeat and timer stay Spotify's.
#import "PlayerHistory.h"
#import "PlayerHistoryRows.h"
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>

static const NSUInteger kHistoryLimit = 25;
static char kHistoryAdapter;
static atomic_uint_fast64_t sgr_historyCommands;
static _Thread_local BOOL sgr_historyOwnCommand;

void SGRPlayerHistoryTransportCommand(void) {
    if (!sgr_historyOwnCommand) atomic_fetch_add(&sgr_historyCommands, 1);
}

// Same SPTask callbacks used by Shared/AlbumQueue; supported in 9.1.90.
@protocol SGRHistoryTask <NSObject>
- (id)addCallback:(void (^)(id))callback on:(dispatch_queue_t)queue;
- (id)addErrorCallback:(void (^)(NSError *))callback on:(dispatch_queue_t)queue;
@end

@interface SPTPlayerTrack (SGRHistoryQueueItem)
- (NSString *)UID;
- (instancetype)initWithURI:(NSURL *)uri albumURI:(NSURL *)album artistURI:(NSURL *)artist andUID:(NSString *)uid;
@end
@interface SGRHistoryQueueWrapper : NSObject
- (instancetype)initWithPlayer:(id)player;
- (id)queueTrackPlayNext:(SPTPlayerTrack *)track;
@end

static NSString *trackUID(SPTPlayerTrack *track) {
    id uid = [track respondsToSelector:@selector(UID)] ? track.UID : nil;
    return [uid isKindOfClass:NSString.class] ? uid : @"";
}
static NSArray *playbackIdentity(SPTPlayerState *state) {
    return @[SGURIString(state.contextURI) ?: @"", SGURIString(state.track.URI) ?: @"", trackUID(state.track)];
}

static NSArray<SPTPlayerTrack *> *historyTracks(NSArray *source) {
    if (![source isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *tracks = [NSMutableArray array];
    Class trackClass = objc_getClass("SPTPlayerTrack");
    for (id track in source) {
        if (trackClass && [track isKindOfClass:trackClass]) [tracks addObject:track];
    }
    // Native prevTracks/reverse are chronological: keep the newest suffix.
    return tracks.count > kHistoryLimit ? [tracks subarrayWithRange:NSMakeRange(tracks.count - kHistoryLimit, kHistoryLimit)] : tracks;
}
static NSURL *artwork(SPTPlayerTrack *track) {
    NSDictionary *metadata = [track.metadata isKindOfClass:NSDictionary.class] ? track.metadata : nil;
    for (NSString *key in @[@"image_xlarge_url", @"image_large_url", @"image_url"]) {
        NSString *url = metadata[key];
        if ([url isKindOfClass:NSString.class] && url.length) return [NSURL URLWithString:url];
    }
    return nil;
}
static NSArray *historyIdentity(SPTPlayerState *state, NSArray<SPTPlayerTrack *> *tracks) {
    NSMutableArray *identity = [NSMutableArray arrayWithArray:playbackIdentity(state)];
    // A repeated recording still has its own native queue occurrence.
    for (SPTPlayerTrack *track in tracks) {
        [identity addObject:@[SGURIString(track.URI) ?: @"", trackUID(track), track.trackTitle ?: @"", track.artistName ?: @"", artwork(track).absoluteString ?: @""]];
    }
    return identity;
}
static UITableView *queueTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for (UIView *child in view.subviews) {
        UITableView *table = queueTable(child);
        if (table) return table;
    }
    return nil;
}

@interface SGRHistoryHeader : UIView
@property(nonatomic, copy) NSArray<SGRNativeHistoryRow *> *rows;
@property(nonatomic, strong) UIView *current;
@property(nonatomic) CGFloat rowHeight;
@property(nonatomic) CGFloat topGap;
@end
@implementation SGRHistoryHeader
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat y = self.topGap;
    for (SGRNativeHistoryRow *row in self.rows) {
        row.view.frame = CGRectMake(0, y, self.bounds.size.width, self.rowHeight);
        y += self.rowHeight;
    }
    self.current.frame = CGRectMake(0, y, self.bounds.size.width, self.rowHeight);
}
@end

@interface SGRQueueHistory : NSObject <SGPlayerStateObserver>
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, strong) UITableView *table;
@property(nonatomic, strong) UIStackView *originalStack;
@property(nonatomic, strong) SGRHistoryHeader *header;
@property(nonatomic) NSUInteger originalIndex;
@property(nonatomic) BOOL originalTranslates;
@property(nonatomic) UIViewAutoresizing originalMask;
@property(nonatomic, copy) NSArray<SPTPlayerTrack *> *tracks;
@property(nonatomic, copy) NSArray *identity;
@property(nonatomic, copy) NSArray *fullHistory, *fullHistoryIdentity, *queriedHistoryIdentity;
@property(nonatomic, strong) id historyFetch;
@property(nonatomic) NSUInteger historyFetchSerial;
- (void)requestHistory;
@property(nonatomic) BOOL changingLayout;
@property(nonatomic) CFTimeInterval pinDeadline;
- (BOOL)pinToCurrentIfNeeded;
@property(nonatomic) BOOL warned;
@property(nonatomic, strong) id replayTask;
@property(nonatomic, strong) id replayWrapper;
@property(nonatomic, copy) NSString *replayTargetURI;
@property(nonatomic, copy) NSArray *replayOriginIdentity;
@property(nonatomic) NSUInteger replaySerial;
@property(nonatomic) BOOL replayWaitingForState;
@property(nonatomic) uint64_t replayCommandEpoch;
- (void)finishReplay:(NSString *)error;
- (void)replayTimedOut:(NSNumber *)serial;
- (void)watchReplayTask:(id)task serial:(NSUInteger)serial done:(void (^)(void))done;
- (void)refresh:(SPTPlayerState *)state;
- (void)layout;
- (void)restore;
@end

@implementation SGRQueueHistory
- (void)requestHistory {
    if (!SGFlag(SGRKeyPlayerHistory, NO) || !self.controller.viewIfLoaded.window) return;
    NSArray *origin = playbackIdentity(SGPlayerState());
    if ([origin isEqual:self.queriedHistoryIdentity]) return;
    id player = SGPlayer();
    SEL selector = NSSelectorFromString(@"getQueueWithCallback:");
    NSMethodSignature *signature = [player methodSignatureForSelector:selector];
    if (![player respondsToSelector:selector] || signature.numberOfArguments != 3 || signature.methodReturnType[0] != '@') return;
    self.queriedHistoryIdentity = origin;
    NSUInteger serial = ++self.historyFetchSerial;
    __weak SGRQueueHistory *weakSelf = self;
    id (^received)(id) = ^id(id queue) {
        NSArray *previous = [queue respondsToSelector:NSSelectorFromString(@"prevTracks")] ? [queue valueForKey:@"prevTracks"] : nil;
        NSArray *snapshot = [previous isKindOfClass:NSArray.class] ? [previous copy] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            SGRQueueHistory *history = weakSelf;
            if (!history || serial != history.historyFetchSerial || ![origin isEqual:playbackIdentity(SGPlayerState())] || !SGFlag(SGRKeyPlayerHistory, NO)) return;
            history.historyFetch = nil;
            if (!snapshot) return;
            history.fullHistory = snapshot;
            history.fullHistoryIdentity = origin;
            [history refresh:SGPlayerState()];
        });
        return nil;
    };
    // This API returns a cancellation token, not an SPTask. Its single argument
    // callback supplies the complete native queue, unlike state.reverse's 2-item window.
    self.historyFetch = ((id (*)(id, SEL, id))objc_msgSend)(player, selector, received);
}
- (void)unavailable {
    if (self.warned) return;
    self.warned = YES;
    SGLog(@"queue history: native queue renderer/layout unavailable; original queue kept");
}
- (void)playerStateDidChange:(SPTPlayerState *)state {}
- (void)playerStateDidReport:(SPTPlayerState *)state {
    if (self.replayTargetURI && self.replayCommandEpoch != atomic_load(&sgr_historyCommands)) {
        [self finishReplay:nil];
    } else if (self.replayTargetURI) {
        NSArray *current = playbackIdentity(state);
        BOOL newOccurrence = ![current[1] isEqual:self.replayOriginIdentity[1]] ||
            ([current[2] length] && ![current[2] isEqual:self.replayOriginIdentity[2]]);
        if (self.replayWaitingForState && [current[1] isEqual:self.replayTargetURI] && newOccurrence) {
            SGLog(@"queue history: replay confirmed by player state");
            [self finishReplay:nil];
        } else if (![current isEqual:self.replayOriginIdentity]) {
            SGLog(@"queue history: state identity changed %@ -> %@", self.replayOriginIdentity, current);
            // A user/remote track change supersedes a pending enqueue. Never skip
            // the new song when that old request eventually completes.
            [self finishReplay:nil];
        }
    }
    [self requestHistory];
    // Rebind command targets on every report; redraw only when the history changes.
    [self refresh:state];
}
- (void)refresh:(SPTPlayerState *)state {
    if (self.changingLayout) return;
    if (!SGRedesignedUI() || !SGFlag(SGRKeyPlayerHistory, NO)) {
        [self finishReplay:nil];
        [self restore]; self.tracks = @[]; self.identity = nil; return;
    }
    NSArray *tracks = historyTracks([self.fullHistoryIdentity isEqual:playbackIdentity(state)] ? self.fullHistory : state.reverse);
    NSArray *identity = historyIdentity(state, tracks);
    self.tracks = tracks;
    if (!tracks.count) {
        [self restore]; self.identity = identity; return;
    }
    UIViewController *controller = self.controller;
    if (!controller.isViewLoaded || !controller.view.window) return;
    if (self.header && [identity isEqual:self.identity]) { [self layout]; return; }

    UIView *current = self.header.current ?: [SGRNativeHistoryRenderer currentTrackContainerOf:controller];
    UIStackView *stack = self.originalStack ?: ([current.superview isKindOfClass:UIStackView.class] ? (UIStackView *)current.superview : nil);
    UITableView *table = self.table ?: queueTable(controller.view);
    if (!current || !stack || !table || (table.tableHeaderView && table.tableHeaderView != self.header)) {
        [self restore]; [self unavailable]; return;
    }
    if (!self.header && ![stack.arrangedSubviews containsObject:current]) { [self unavailable]; return; }
    NSMutableArray<SGRNativeHistoryRow *> *rows = [NSMutableArray array];
    for (NSUInteger displayIndex = 0; displayIndex < tracks.count; displayIndex++) {
        NSUInteger reverseIndex = displayIndex;
        SPTPlayerTrack *track = tracks[reverseIndex];
        SGRNativeHistoryRow *row = [SGRNativeHistoryRenderer rowInController:controller title:track.trackTitle ?: @"제목 없음" subtitle:track.artistName ?: @"" artwork:artwork(track)];
        if (!row) { [self restore]; [self unavailable]; return; }
        row.view.tag = (NSInteger)reverseIndex;
        row.view.accessibilityHint = @"이 곡 다시 재생";
        row.view.accessibilityTraits |= UIAccessibilityTraitButton;
        row.view.userInteractionEnabled = YES;
        [row.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(replay:)]];
        [rows addObject:row];
    }

    self.changingLayout = YES;
    BOOL first = self.header == nil;
    CGFloat previousHeight = self.header.frame.size.height;
    CGPoint oldOffset = table.contentOffset;
    [UIView performWithoutAnimation:^{
        if (first) {
            self.originalStack = stack; self.table = table;
            self.originalIndex = [stack.arrangedSubviews indexOfObject:current];
            self.originalTranslates = current.translatesAutoresizingMaskIntoConstraints;
            self.originalMask = current.autoresizingMask;
            self.header = [SGRHistoryHeader new];
            self.header.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            self.header.current = current;
            self.header.rowHeight = MAX(1, current.bounds.size.height);
            self.header.topGap = MAX(0, stack.spacing);
            [stack removeArrangedSubview:current];
            [current removeFromSuperview];
            current.translatesAutoresizingMaskIntoConstraints = YES;
            current.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [self.header addSubview:current];
        }
        for (SGRNativeHistoryRow *row in self.header.rows) [row.view removeFromSuperview];
        self.header.rows = rows;
        for (SGRNativeHistoryRow *row in rows) {
            row.view.translatesAutoresizingMaskIntoConstraints = YES;
            row.view.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [self.header addSubview:row.view];
        }
        CGFloat height = self.header.topGap + self.header.rowHeight * (rows.count + 1);
        self.header.frame = CGRectMake(0, 0, table.bounds.size.width, height);
        [self.header setNeedsLayout]; [self.header layoutIfNeeded];
        table.tableHeaderView = self.header;
        self.identity = identity;
        [controller.view setNeedsLayout]; [controller.view layoutIfNeeded];
        // Show the two nearest previous tracks on entry. Older rows remain above,
        // in this same table's scroll, without an extra screen or a nested list.
        if (first) self.pinDeadline = CACurrentMediaTime() + 1.5;
        if (![self pinToCurrentIfNeeded]) {
            CGFloat offset = oldOffset.y + height - previousHeight;
            CGFloat maxOffset = MAX(-table.adjustedContentInset.top, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
            table.contentOffset = CGPointMake(oldOffset.x, MIN(maxOffset, MAX(-table.adjustedContentInset.top, offset)));
        }
    }];
    self.changingLayout = NO;
}
- (BOOL)pinToCurrentIfNeeded {
    UITableView *table = self.table;
    if (!table || !self.header || CACurrentMediaTime() > self.pinDeadline) return NO;
    if (table.isTracking || table.isDragging || table.isDecelerating) return NO;
    CGFloat inset = table.adjustedContentInset.top;
    NSUInteger count = self.header.rows.count;
    CGFloat y = count > 2 ? self.header.topGap + (count - 2) * self.header.rowHeight : 0;
    CGFloat maxOffset = MAX(-inset, table.contentSize.height - table.bounds.size.height + table.adjustedContentInset.bottom);
    table.contentOffset = CGPointMake(table.contentOffset.x, MIN(maxOffset, MAX(-inset, y - inset)));
    return YES;
}
- (void)layout {
    if (self.changingLayout || !self.header) return;
    if (!SGFlag(SGRKeyPlayerHistory, NO)) { [self finishReplay:nil]; [self restore]; return; }
    if (self.table.tableHeaderView != self.header) { [self restore]; return; }
    CGFloat width = self.table.bounds.size.width;
    CGSize fitting = [self.header.current systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)
                                      withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGFloat rowHeight = fitting.height > 0 ? fitting.height : self.header.rowHeight;
    CGFloat height = self.header.topGap + rowHeight * (self.header.rows.count + 1);
    if (fabs(self.header.frame.size.width - width) < 0.5 && fabs(self.header.frame.size.height - height) < 0.5) return;
    self.changingLayout = YES;
    self.header.rowHeight = rowHeight;
    self.header.frame = CGRectMake(0, 0, width, height);
    [self.header setNeedsLayout];
    self.table.tableHeaderView = self.header;
    self.changingLayout = NO;
}
- (void)restore {
    if (!self.header || self.changingLayout) return;
    self.changingLayout = YES;
    [UIView performWithoutAnimation:^{
        UIView *current = self.header.current;
        if (current.superview == self.header) {
            [current removeFromSuperview];
            current.translatesAutoresizingMaskIntoConstraints = self.originalTranslates;
            current.autoresizingMask = self.originalMask;
            [self.originalStack insertArrangedSubview:current atIndex:MIN(self.originalIndex, self.originalStack.arrangedSubviews.count)];
        }
        if (self.table.tableHeaderView == self.header) self.table.tableHeaderView = nil;
        self.header = nil; self.originalStack = nil; self.table = nil;
        [self.controller.viewIfLoaded setNeedsLayout];
    }];
    self.changingLayout = NO;
}
- (void)finishReplay:(NSString *)error {
    if (self.replayTargetURI) SGLog(@"queue history: finishReplay err=%@ epoch=%llu now=%llu waiting=%d", error ?: @"nil", (unsigned long long)self.replayCommandEpoch, (unsigned long long)atomic_load(&sgr_historyCommands), self.replayWaitingForState);
    self.replaySerial++;
    self.replayTask = nil; self.replayWrapper = nil;
    self.replayTargetURI = nil; self.replayOriginIdentity = nil;
    self.replayWaitingForState = NO;
    if (!error) return;
    UIViewController *owner = self.controller;
    if (!owner.viewIfLoaded.window || owner.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"이전 곡을 재생할 수 없습니다" message:error preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
    SGPresentDark(alert); [owner presentViewController:alert animated:YES completion:nil];
}
- (void)replayTimedOut:(NSNumber *)serial {
    if (serial.unsignedIntegerValue != self.replaySerial || !self.replayTargetURI) return;
    BOOL superseded = self.replayCommandEpoch != atomic_load(&sgr_historyCommands);
    [self finishReplay:superseded ? nil : @"재생 요청을 확인하지 못했습니다. 대기열을 확인한 뒤 다시 시도해 주세요."];
}
- (void)watchReplayTask:(id<SGRHistoryTask>)task serial:(NSUInteger)serial done:(void (^)(void))done {
    if (serial != self.replaySerial || !self.replayTargetURI) return;
    if (![task respondsToSelector:@selector(addCallback:on:)] || ![task respondsToSelector:@selector(addErrorCallback:on:)]) {
        [self finishReplay:@"Spotify가 재생 요청의 결과를 반환하지 않았습니다. 대기열을 확인해 주세요."]; return;
    }
    self.replayTask = task;
    __weak SGRQueueHistory *weakSelf = self;
    __weak id weakTask = task;
    [task addCallback:^(id value) {
        SGRQueueHistory *history = weakSelf;
        if (!history || history.replaySerial != serial || history.replayTask != weakTask) return;
        if (history.replayCommandEpoch != atomic_load(&sgr_historyCommands)) { [history finishReplay:nil]; return; }
        done();
    } on:dispatch_get_main_queue()];
    [task addErrorCallback:^(NSError *failure) {
        SGRQueueHistory *history = weakSelf;
        if (!history || history.replaySerial != serial || history.replayTask != weakTask) return;
        if (history.replayCommandEpoch != atomic_load(&sgr_historyCommands)) { [history finishReplay:nil]; return; }
        SGLog(@"queue history: replay command failed (%@, %ld)", failure.domain, (long)failure.code);
        [history finishReplay:@"Spotify에서 재생 요청을 완료하지 못했습니다. 대기열을 확인한 뒤 다시 시도해 주세요."];
    } on:dispatch_get_main_queue()];
}
- (void)replay:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized || !SGFlag(SGRKeyPlayerHistory, NO) || self.replayTargetURI) return;
    UIViewController *controller = self.controller;
    if (!controller || [SGRNativeHistoryRenderer isEditingQueueOf:controller]) return;
    if (!self.header || gesture.view.superview != self.header) return;
    NSInteger index = gesture.view.tag;
    NSArray *shown = self.identity;
    [self refresh:SGPlayerState()];
    if (![shown isEqual:self.identity] || gesture.view.superview != self.header || index < 0 || (NSUInteger)index >= self.tracks.count) return;
    id<SPTPlayer> player = SGPlayer();
    Class wrapper = objc_getClass("SPTPlayerQueueWrapperImpl"), trackClass = objc_getClass("SPTPlayerTrack");
    NSString *uri = SGURIString(self.tracks[(NSUInteger)index].URI);
    if (!uri.length || !SGURIString(SGPlayerState().track.URI).length ||
        ![wrapper instancesRespondToSelector:@selector(initWithPlayer:)] ||
        ![wrapper instancesRespondToSelector:@selector(queueTrackPlayNext:)] ||
        ![trackClass instancesRespondToSelector:@selector(initWithURI:albumURI:artistURI:andUID:)] ||
        ![player respondsToSelector:@selector(skipToNextTrackWithOptions:)]) {
        [self finishReplay:@"현재 Spotify에서 대기열 재생 명령을 사용할 수 없습니다."]; return;
    }
    // A history entry's UID/provider belong to its old context occurrence. Ask
    // Spotify to enqueue a fresh recording through its own queue-next wrapper;
    // it supplies queue metadata/revision handling and keeps all existing next
    // tracks. Reusing a past entry as the terminal skip's track is a no-op in 9.1.90.
    SPTPlayerTrack *fresh = [[trackClass alloc] initWithURI:[NSURL URLWithString:uri] albumURI:nil artistURI:nil andUID:nil];
    if (!fresh) { [self finishReplay:@"Spotify에서 이전 곡을 준비하지 못했습니다."]; return; }
       self.replayTargetURI = uri;
    self.replayOriginIdentity = playbackIdentity(SGPlayerState());
    NSUInteger serial = ++self.replaySerial;
    self.replayWrapper = [[wrapper alloc] initWithPlayer:player];
    sgr_historyOwnCommand = YES;
    id task = [self.replayWrapper queueTrackPlayNext:fresh];
    sgr_historyOwnCommand = NO;
    self.replayCommandEpoch = atomic_load(&sgr_historyCommands);
    __weak SGRQueueHistory *weakSelf = self;
    [self watchReplayTask:task serial:serial done:^{
        SGRQueueHistory *history = weakSelf;
        if (!history) return;
        if (![playbackIdentity(SGPlayerState()) isEqual:history.replayOriginIdentity] || !SGFlag(SGRKeyPlayerHistory, NO)) {
            [history finishReplay:nil]; return;
        }
        SGLog(@"queue history: enqueue acknowledged, skipping to next");
        history.replayWaitingForState = YES;
        sgr_historyOwnCommand = YES;
        id next = [player skipToNextTrackWithOptions:nil];
        sgr_historyOwnCommand = NO;
        [history watchReplayTask:next serial:serial done:^{
            // A fulfilled task acknowledges a command. Only a changed native
            // playback occurrence confirms that the requested song really plays.
            [weakSelf playerStateDidReport:SGPlayerState()];
        }];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [weakSelf replayTimedOut:@(serial)];
    });
}

@end

void SGRPlayerUpdateHistory(UIViewController *controller) {
    if (!SGRedesignedUI() || !controller) return;
    SGRQueueHistory *history = objc_getAssociatedObject(controller, &kHistoryAdapter);
    if (!history && SGFlag(SGRKeyPlayerHistory, NO)) {
        history = [SGRQueueHistory new]; history.controller = controller;
        objc_setAssociatedObject(controller, &kHistoryAdapter, history, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGAddPlayerStateObserver(history);
    }
    history.queriedHistoryIdentity = nil;
    history.pinDeadline = CACurrentMediaTime() + 1.5;
    [history requestHistory];
    [history refresh:SGPlayerState()];
}
void SGRPlayerLayoutHistory(UIViewController *controller) {
    SGRQueueHistory *history = objc_getAssociatedObject(controller, &kHistoryAdapter);
    [history layout];
}
