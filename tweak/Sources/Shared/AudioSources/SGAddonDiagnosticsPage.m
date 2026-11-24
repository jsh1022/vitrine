#import "SGAddonDiagnostics.h"
#import "SGAddons.h"
#import "Core/SGGlass.h"
#import "Settings/SGPageStyle.h"
#import <UIKit/UIKit.h>

static NSString *SGAddonSourceLabel(NSString *identifier) {
    NSString *name = SGAddonDiagnosticsSourceName(identifier);
    NSString *safeID = SGAddonDiagnosticsSafeSourceID(identifier);
    if ([safeID isEqual:@"common"]) return @"공통 처리";
    NSString *suffix = safeID.length > 8 ? [safeID substringFromIndex:safeID.length - 8] : safeID;
    return name.length ? [NSString stringWithFormat:@"%@ · %@", name, suffix] : [NSString stringWithFormat:@"애드온 %@", suffix];
}
static NSString *SGAddonEventText(NSDictionary *entry) {
    NSMutableArray *parts = [NSMutableArray new]; NSDictionary *details = entry[@"details"];
    NSDictionary *labels = @{@"httpStatus": @"HTTP", @"errorDomain": @"오류 종류", @"errorCode": @"오류 코드",
        @"receivedBytes": @"받은 바이트", @"expectedBytes": @"예상 바이트", @"fileBytes": @"파일 바이트",
        @"fileExists": @"파일 있음", @"growing": @"다운로드 중", @"complete": @"완료", @"cancelled": @"취소됨",
        @"timeout": @"시간 초과", @"epochChanged": @"오디오 출력 기준 변경", @"generationChanged": @"작업 취소 기준 변경", @"correlation": @"소리 일치 점수"};
    NSArray *keyOrder = @[@"httpStatus", @"errorDomain", @"errorCode", @"receivedBytes", @"expectedBytes", @"fileBytes",
        @"fileExists", @"growing", @"complete", @"cancelled", @"timeout", @"epochChanged", @"generationChanged", @"correlation"];
    for (NSString *key in keyOrder) if (details[key]) {
        id value = details[key];
        if ([key hasSuffix:@"Bytes"]) value = [NSByteCountFormatter stringFromByteCount:[value longLongValue] countStyle:NSByteCountFormatterCountStyleFile];
        else if ([value isKindOfClass:NSNumber.class] && ![key isEqual:@"errorCode"] && ![key isEqual:@"httpStatus"] && ![key isEqual:@"correlation"])
            value = [value boolValue] ? @"예" : @"아니요";
        [parts addObject:[NSString stringWithFormat:@"%@ %@", labels[key], value]];
    }
    static NSDateFormatter *formatter; static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter=[NSDateFormatter new]; formatter.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat=@"HH:mm:ss";
    });
    return [NSString stringWithFormat:@"%@  %@ · %@ · %@%@", [formatter stringFromDate:entry[@"time"]], SGAddonSourceLabel(entry[@"source"]), entry[@"stage"], entry[@"event"],
        parts.count ? [@"\n" stringByAppendingString:[parts componentsJoinedByString:@"  "]] : @""];
}
static NSString *SGAddonSafeStatus(void) {
    NSString *status = SGAddonStatus();
    return status.length ? SGAddonDiagnosticsSafeText(status) : @"상태 정보 없음";
}
static NSString *SGAddonDiagnosticLog(void) {
    NSMutableArray *lines = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"준비 상태: %@\n%@", SGAddonStatusSummary() ?: @"알 수 없음", SGAddonSafeStatus()]];
    for (NSDictionary *entry in SGAddonDiagnosticEvents()) [lines addObject:SGAddonEventText(entry)];
    return [lines componentsJoinedByString:@"\n"];
}

@interface SGAddonDiagnosticsController : UITableViewController
@property(nonatomic, copy) NSArray<NSDictionary *> *events;
@property(nonatomic, strong) NSTimer *refreshTimer;
@end
@implementation SGAddonDiagnosticsController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"애드온 준비 기록"; self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 68;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"닫기" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.leftBarButtonItem.accessibilityLabel = @"닫기";
    self.navigationItem.prompt = @"1초마다 자동 갱신";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"복사" style:UIBarButtonItemStylePlain target:self action:@selector(copyLog)];
    [self refresh];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refresh]; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated]; [self refresh];
    [self.refreshTimer invalidate];
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
}
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; [self.refreshTimer invalidate]; self.refreshTimer = nil; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)refresh { self.events = SGAddonDiagnosticEvents().reverseObjectEnumerator.allObjects; [self.tableView reloadData]; }
- (void)copyLog {
    UIPasteboard.generalPasteboard.string = SGAddonDiagnosticLog();
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"복사했습니다" message:@"민감한 주소와 파일 경로를 제외한 준비 기록을 복사했습니다." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
    SGPresentDark(alert); [self presentViewController:alert animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 1 : MAX(1, self.events.count); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section == 0 ? @"현재 준비 상태" : @"최근 이벤트"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"diagnostic"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"diagnostic"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone; cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    if (indexPath.section == 0) { cell.textLabel.text = SGAddonStatusSummary() ?: @"알 수 없음"; cell.detailTextLabel.text = SGAddonSafeStatus(); }
    else if (!self.events.count) { cell.textLabel.text = @"기록된 이벤트가 없습니다"; cell.detailTextLabel.text = @"음원을 준비하면 기록이 자동으로 표시됩니다."; }
    else { NSDictionary *entry = self.events[(NSUInteger)indexPath.row]; cell.textLabel.text = SGAddonEventText(entry); cell.detailTextLabel.text = nil; }
    return cell;
}
@end

void SGShowAddonPreparationDetails(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[SGAddonDiagnosticsController new]];
        navigation.modalPresentationStyle = UIModalPresentationPageSheet;
        SGPresentDark(navigation);
        UIViewController *owner = SGTopController();
        if (owner && owner.viewIfLoaded.window) [owner presentViewController:navigation animated:YES completion:nil];
    });
}
