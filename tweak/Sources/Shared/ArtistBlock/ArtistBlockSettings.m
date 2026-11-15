// The Blocked artists page: the switch, whether a featured credit counts, blocking someone off the
// track playing now, and the list, swiped to unblock. The hook reads all of it per track, so a change
// needs no restart.
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "ArtistBlock.h"

typedef NS_ENUM(NSInteger, SGArtistSection) {
    SGArtistSectionSwitch,
    SGArtistSectionMode,
    SGArtistSectionAdd,
    SGArtistSectionList,
    SGArtistSectionCount,
};

@interface SGArtistBlockPage : SGPage
@end

@implementation SGArtistBlockPage {
    NSArray<NSDictionary *> *_blocked;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = @"차단한 아티스트";
    _blocked = SGBlockedArtists();
    return self;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)reload {
    _blocked = SGBlockedArtists();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return SGArtistSectionCount;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    if (section == SGArtistSectionMode) return 2;
    if (section == SGArtistSectionList) return MAX((NSInteger)_blocked.count, 1);
    return 1;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    if (section == SGArtistSectionMode) return SGSectionHeader(table, @"아티스트가 다음에 해당하면 건너뛰기");
    if (section == SGArtistSectionList) return SGSectionHeader(table, @"Blocked");
    return nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return section == SGArtistSectionMode || section == SGArtistSectionList ? SGSectionHeaderHeight() : SGSectionGap;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"artist");
    switch (path.section) {
        case SGArtistSectionSwitch: {
            SGFillCell(cell, @"차단한 아티스트 건너뛰기", nil, nil, nil);
            UISwitch *toggle = [UISwitch new];
            toggle.onTintColor = SGGreen();
            toggle.on = SGFlag(SGKeyArtistBlock, NO);
            [toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            break;
        }
        case SGArtistSectionMode: {
            BOOL featured = path.row == 1;
            SGFillCell(cell, featured ? @"주 아티스트 또는 피처링" : @"주 아티스트",
                       featured ? @"곡 크레딧에 포함된 모든 아티스트" : @"곡의 첫 아티스트", nil, nil);
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            if (featured == SGFlag(SGKeyArtistBlockFeatured, NO)) {
                UIImageView *tick = SGSymbolView(@"checkmark", 13, UIImageSymbolWeightSemibold, 16);
                tick.tintColor = SGGreen();
                cell.accessoryView = tick;
            }
            break;
        }
        case SGArtistSectionAdd:
            SGFillCell(cell, @"현재 재생 중인 아티스트 차단…", nil, nil, @"person.crop.circle.badge.xmark");
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            break;
        default:
            if (!_blocked.count) {
                SGFillCell(cell, @"아직 없음", nil, SGGrey(), nil);
                break;
            }
            NSDictionary *artist = _blocked[(NSUInteger)path.row];
            SGFillCell(cell, artist[SGArtistName], artist[SGArtistURI], nil, nil);
            break;
    }
    return cell;
}

- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGArtistSectionList && _blocked.count > 0;
}

- (NSString *)tableView:(UITableView *)table titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)path {
    return @"Unblock";
}

- (void)tableView:(UITableView *)table commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete) return;
    SGUnblockArtist(_blocked[(NSUInteger)path.row][SGArtistURI]);
    [self reload];
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == SGArtistSectionMode) {
        SGSetEnabled(SGKeyArtistBlockFeatured, path.row == 1);
        [self reload];
    } else if (path.section == SGArtistSectionAdd) {
        [self pickFromPlaying:[table cellForRowAtIndexPath:path]];
    }
}

- (void)pickFromPlaying:(UIView *)source {
    NSArray<NSDictionary *> *artists = SGPlayingArtists();
    if (!artists.count) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"재생 중인 곡 없음"
                                                                      message:@"먼저 이 아티스트의 곡을 재생한 후 다시 여세요."
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Block"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [artists enumerateObjectsUsingBlock:^(NSDictionary *artist, NSUInteger index, BOOL *stop) {
        BOOL blocked = SGArtistBlocked(artist[SGArtistURI]);
        NSString *title = index == 0 ? artist[SGArtistName] : [NSString stringWithFormat:@"%@ (featured)", artist[SGArtistName]];
        UIAlertAction *action = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            SGBlockArtist(artist);
            [self reload];
        }];
        action.enabled = !blocked;
        [sheet addAction:action];
    }];
    [sheet addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = source;
    sheet.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)toggled:(UISwitch *)toggle {
    SGSetEnabled(SGKeyArtistBlock, toggle.on);
}

@end

UIViewController *SGArtistBlockSettingsPage(void) {
    return [SGArtistBlockPage new];
}
