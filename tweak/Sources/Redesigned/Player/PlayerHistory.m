// The queue remains Spotify owned. Like BitChord's QueueSections, history is a distinct
// section; replay is Spotify's targeted previous command, never a reconstructed context.
#import "PlayerHistory.h"
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Navigation/Links.h"
#import <objc/message.h>
#import <objc/runtime.h>

@interface SGRHistoryQueue : UITableViewController <SGPlayerStateObserver>
@property(nonatomic, copy) NSArray<NSArray<SPTPlayerTrack *> *> *groups;
@property(nonatomic, copy) NSArray *identity;
@end
static NSArray *tracks(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *result = [NSMutableArray array];
    Class trackClass = objc_getClass("SPTPlayerTrack");
    for (id item in value) if (trackClass && [item isKindOfClass:trackClass]) [result addObject:item];
    return result;
}
@implementation SGRHistoryQueue
- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"재생 대기 목록";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    SGAddPlayerStateObserver(self);
    [self playerStateDidReport:SGPlayerState()];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Spotify 대기열" style:UIBarButtonItemStylePlain target:self action:@selector(stockQueue)];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)stockQueue {
    [self dismissViewControllerAnimated:YES completion:^{ SGOpenSpotifyURI([NSURL URLWithString:@"spotify:now-playing:queue"]); }];
}
- (void)playerStateDidChange:(SPTPlayerState *)state {}
- (void)playerStateDidReport:(SPTPlayerState *)state {
    NSArray *groups = @[tracks(state.reverse), state.track ? @[state.track] : @[], tracks(state.future)];
    NSMutableArray *identity = [NSMutableArray arrayWithObject:SGURIString(state.contextURI) ?: @""];
    for (NSArray *group in groups) {
        NSMutableArray *section = [NSMutableArray array];
        for (SPTPlayerTrack *track in group) [section addObject:@[SGURIString(track.URI) ?: @"", track.trackTitle ?: @"", track.artistName ?: @"", track.provider ?: @""]];
        [identity addObject:section];
    }
    BOOL changed = ![identity isEqual:self.identity];
    // Refresh native objects even if text/order stayed identical; command targets must be current.
    self.groups = groups; self.identity = identity;
    if (changed && self.isViewLoaded) [self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 3; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return self.groups[section].count; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { return @[@"이전 곡 · 최근 재생 순", @"현재 곡", @"다음 곡"][section]; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    if (section == 0 && !self.groups[0].count) return @"Spotify가 제공한 이전 곡이 없습니다.";
    if (section == 2) return @"Spotify의 셔플·반복·수동 대기열 순서를 사용합니다. 순서 편집과 삭제는 Spotify 대기열에서 할 수 있습니다.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:@"track"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"track"];
    SPTPlayerTrack *track = self.groups[index.section][index.row];
    cell.textLabel.text = track.trackTitle ?: @"제목 없음";
    cell.detailTextLabel.text = track.artistName ?: @"";
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:self.traitCollection];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote compatibleWithTraitCollection:self.traitCollection];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.accessibilityHint = index.section == 0 ? @"이 곡 다시 재생" : index.section == 2 ? @"이 곡으로 건너뛰기" : @"현재 재생 중인 곡";
    cell.selectionStyle = index.section == 1 ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)index {
    [table deselectRowAtIndexPath:index animated:YES];
    NSArray *shown = self.identity;
    [self playerStateDidReport:SGPlayerState()];
    if (![shown isEqual:self.identity] || index.section == 1 || index.row >= self.groups[index.section].count) return;
    id player = SGPlayer();
    SEL selector = NSSelectorFromString(index.section == 0 ? @"skipToPreviousTrackWithOptions:track:loggingParams:" : @"skipToNextTrackWithOptions:track:loggingParams:");
    NSMethodSignature *signature = [player methodSignatureForSelector:selector];
    if (![player respondsToSelector:selector] || signature.numberOfArguments != 5 || signature.methodReturnType[0] != '@') {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"이 곡을 선택할 수 없습니다" message:@"현재 Spotify에서 대상 곡 건너뛰기를 사용할 수 없습니다. Spotify 대기열을 이용하세요." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil]; return;
    }
    // These terminal selectors are evidenced in Spotify 9.1.90 and Shared/Sing/Sing.x.
    ((id (*)(id, SEL, id, id, id))objc_msgSend)(player, selector, nil, self.groups[index.section][index.row], nil);
}
@end

BOOL SGRPlayerShowHistory(void) {
    if (!SGRedesignedUI() || !SGFlag(SGRKeyPlayerHistory, NO)) return NO;
    SGRHistoryQueue *queue = [SGRHistoryQueue new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:queue];
    SGPresentDark(nav); return YES;
}
@interface SGRHistoryButton : UIButton
@end
@implementation SGRHistoryButton
- (void)open { SGRPlayerShowHistory(); }
@end
void SGRPlayerAttachHistory(UIView *queue) {
    static char key;
    SGRHistoryButton *button = objc_getAssociatedObject(queue, &key);
    if (!queue || !SGFlag(SGRKeyPlayerHistory, NO)) { [button removeFromSuperview]; return; }
    if (!button) {
        button = [SGRHistoryButton buttonWithType:UIButtonTypeCustom];
        button.backgroundColor = UIColor.clearColor;
        button.accessibilityLabel = @"재생 대기 목록 및 이전 곡";
        [button addTarget:button action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(queue, &key, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    button.frame = queue.bounds; button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [queue addSubview:button];
}
