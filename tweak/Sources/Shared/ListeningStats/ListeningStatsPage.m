// ListeningStats.h says what Listening stats is. This is its page: the switch, a row per period opening
// its tops, the export picked and merged in, and the log erased. Built from SGModPage's rows, so it looks
// the same under either look.
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "ListeningStats.h"
#import "SGPlayLog.h"

static const int64_t kDay = 86400;

static NSString *duration(int64_t ms) {
    int64_t minutes = ms / 60000;
    if (minutes < 60) return [NSString stringWithFormat:@"%lld분", minutes];
    return [NSString stringWithFormat:@"%lld시간 %lld분", minutes / 60, minutes % 60];
}

static NSString *playsText(NSUInteger plays) {
    return [NSString stringWithFormat:plays == 1 ? @"%lu회 재생" : @"%lu회 재생", (unsigned long)plays];
}

static void showAlert(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static SGModSection *topSection(NSString *title, NSArray<SGStatEntry *> *entries) {
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    [entries enumerateObjectsUsingBlock:^(SGStatEntry *entry, NSUInteger i, BOOL *stop) {
        NSString *plays = playsText(entry.plays);
        SGModRow *row = SGStatRow([NSString stringWithFormat:@"%lu. %@", (unsigned long)i + 1, entry.name], ^NSString *{ return plays; });
        row.subtitle = entry.detail;
        [rows addObject:row];
    }];
    if (!rows.count) [rows addObject:SGStatRow(@"아직 없음", nil)];
    return SGSection(title, rows);
}

// Added up once, as the page opens: the rows hand back what was worked out then.
static UIViewController *periodPage(NSString *title, int64_t since) {
    SGStats *stats = SGStatsSince(SGListeningLog().plays, since, 25);
    NSString *time = duration(stats.ms), *plays = playsText(stats.plays);
    return [[SGModPage alloc] initWithTitle:title intro:nil sections:@[
        SGSection(nil, @[
            SGStatRow(@"감상 시간", ^NSString *{ return time; }),
            SGStatRow(@"재생 횟수", ^NSString *{ return plays; }),
        ]),
        topSection(@"많이 들은 곡", stats.tracks),
        topSection(@"많이 들은 아티스트", stats.artists),
        topSection(@"많이 들은 앨범", stats.albums),
    ] footer:nil];
}

// The period rows' values are asked each time the page appears, so they sum without the tops.
static int64_t msSince(int64_t since) {
    int64_t ms = 0;
    for (SGPlay *play in SGListeningLog().plays) if (play.end >= since) ms += play.ms;
    return ms;
}

#pragma mark - import

// From the pick until the plays are merged: the import row reads Importing… and takes no second pick.
static BOOL sg_importing;

@interface SGExportPicker : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, weak) UITableViewController *page;
@end

@implementation SGExportPicker

// The export runs to tens of megabytes, so it is unzipped and parsed off the main thread; the log is
// the main thread's, so the merge comes back to it.
- (void)documentPicker:(UIDocumentPickerViewController *)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    UITableViewController *page = self.page;
    sg_importing = YES;
    [page.tableView reloadData];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Importing");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<SGPlay *> *plays = [NSMutableArray array];
        NSUInteger files = 0;
        for (NSURL *url in urls) {
            NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
            NSArray<NSData *> *jsons = [url.pathExtension.lowercaseString isEqualToString:@"zip"] ? SGJSONFilesInZip(data) : (data ? @[data] : @[]);
            for (NSData *json in jsons) {
                NSArray<SGPlay *> *found = SGPlaysFromExport(json);
                if (!found) continue;
                files++;
                [plays addObjectsFromArray:found];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_importing = NO;
            [page.tableView reloadData];
            if (!files) {
                showAlert(@"감상 기록을 찾지 못했습니다", @"Spotify 데이터의 StreamingHistory_music 또는 Streaming_History_Audio 파일이나 해당 ZIP을 선택하세요.");
                return;
            }
            NSUInteger added = [SGListeningLog() merge:plays];
            SGLog(@"stats: %lu plays in %lu files, %lu new", (unsigned long)plays.count, (unsigned long)files, (unsigned long)added);
            [page.tableView reloadData];
            showAlert(@"Imported", [NSString stringWithFormat:@"%@ 추가 · %lu %@ 중 기존 항목 %lu개 건너뜀", playsText(added),
                                   (unsigned long)files, files == 1 ? @"file" : @"files", (unsigned long)(plays.count - added)]);
        });
    });
}

@end

static void pickExport(UITableViewController *page) {
    if (sg_importing) return;
    static SGExportPicker *delegate;
    if (!delegate) delegate = [SGExportPicker new];
    delegate.page = page;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON, UTTypeZIP] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = delegate;
    [SGTopController() presentViewController:picker animated:YES completion:nil];
}

static void confirmErase(UITableViewController *page) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"감상 기록을 지울까요?"
                                                                  message:@"이 휴대전화에 기록하거나 가져온 감상 기록을 모두 삭제합니다. Spotify 자체 기록은 유지됩니다."
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Erase" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [SGListeningLog() erase];
        [page.tableView reloadData];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

#pragma mark - page

UIViewController *SGListeningStatsPage(void) {
    NSMutableArray<SGModRow *> *periods = [NSMutableArray array];
    NSArray *names = @[@"최근 일주일", @"최근 한 달", @"최근 일 년", @"전체 기간"];
    NSArray *days = @[@7, @30, @365, @0];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *name = names[i];
        int64_t back = [days[i] longLongValue] * kDay;
        int64_t (^since)(void) = ^int64_t { return back ? (int64_t)time(NULL) - back : 0; };
        SGModRow *row = SGPageRow(name, ^UIViewController *{ return periodPage(name, since()); });
        row.value = ^NSString *{ return duration(msSince(since())); };
        [periods addObject:row];
    }

    SGModRow *import = SGWithSymbol(SGStatActionRow(@"Spotify 데이터 내보내기 가져오기", nil,
                                                    ^NSString *{ return sg_importing ? @"Importing…" : nil; }, nil), @"square.and.arrow.down");
    SGModRow *erase = SGWithSymbol(SGActionRow(@"감상 기록 지우기", nil, nil), @"trash");
    erase.color = SGRed();
    SGModPage *page = [[SGModPage alloc] initWithTitle:@"감상 통계" intro:nil sections:@[
        SGNotedSection(nil, @[SGSwitchRow(@"재생 기록 저장", nil, SGKeyListeningStats)],
                       @"30초 또는 더 짧은 곡의 절반을 재생하면 한 번으로 기록합니다. 모든 기록은 이 휴대전화에만 저장됩니다."),
        SGSection(nil, periods),
        SGNotedSection(nil, @[
            SGStatRow(@"재생 횟수", ^NSString *{ return [NSString stringWithFormat:@"%lu", (unsigned long)SGListeningLog().plays.count]; }),
            import,
        ], @"Spotify 계정 개인정보 설정에서 데이터를 요청하세요. 계정 데이터의 StreamingHistory_music 또는 확장 감상 기록의 Streaming_History_Audio JSON 파일이나 ZIP을 선택하면 됩니다. 이미 있는 기록은 건너뜁니다."),
        SGSection(nil, @[erase]),
    ] footer:nil];
    __weak SGModPage *weakPage = page;
    import.action = ^{ pickExport(weakPage); };
    erase.action = ^{ confirmErase(weakPage); };
    return page;
}
