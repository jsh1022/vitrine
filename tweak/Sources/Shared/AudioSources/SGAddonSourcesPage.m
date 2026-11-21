// Source management only. Credentials remain in Keychain; cells never display URLs.
#import "SGAddons.h"
#import "SGAddonProtocol.h"
#import "SGAudioPresentation.h"
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"

@interface SGAddonSourcesController : SGPage
@property(nonatomic, copy) NSArray<NSDictionary *> *sources;
@end
@implementation SGAddonSourcesController
- (void)reloadSources {
    self.sources = SGAddonSources();
    [self.tableView reloadData];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"음원을 찾는 순서";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 100;
    [self reloadSources];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadSources]; }
- (void)showMessage:(NSString *)text {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"애드온 소스" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
    SGShowAudioController(alert);
}
- (NSString *)nameOf:(NSDictionary *)source {
    NSString *name = [source[@"name"] isKindOfClass:NSString.class] ? source[@"name"] : nil;
    return name.length ? name : ([NSURL URLWithString:source[@"url"]].host ?: @"애드온");
}
- (NSString *)detailOf:(NSDictionary *)source {
    NSString *detail = [source[@"description"] isKindOfClass:NSString.class] ? source[@"description"] : nil;
    NSString *version = [source[@"version"] isKindOfClass:NSString.class] ? source[@"version"] : nil;
    return [@[version.length ? [@"버전 " stringByAppendingString:version] : @"", detail.length ? detail : @"소스 정보를 새로고침하면 설명을 확인할 수 있습니다."] componentsJoinedByString:@"\n"];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { return section == 0 ? self.sources.count : 1; }
- (NSString *)tableView:(UITableView *)table titleForHeaderInSection:(NSInteger)section { return section == 0 ? @"켜진 소스를 위에서부터 조회합니다" : nil; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section {
    return section == 0 ? @"오른쪽 손잡이를 드래그하여 순서를 바꿉니다. 소스를 탭하면 전체 설명·정보 새로고침·검사·삭제 메뉴가 열립니다. 꺼진 소스는 조회하지 않습니다." : nil;
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"addon-source");
    if (path.section == 1) {
        cell.accessoryView = nil; cell.editingAccessoryView = nil; cell.showsReorderControl = NO;
        SGFillCell(cell, @"추가 음원 서비스 연결", @"발급받은 HTTPS 루트 또는 manifest 링크로 추가", nil, @"plus");
        return cell;
    }
    NSDictionary *source = self.sources[(NSUInteger)path.row];
    BOOL enabled = ![source[@"enabled"] isEqual:@NO];
    SGFillCell(cell, [NSString stringWithFormat:@"%ld. %@", (long)path.row + 1, [self nameOf:source]], [self detailOf:source], enabled ? nil : UIColor.secondaryLabelColor, @"puzzlepiece.extension.fill");
    UIListContentConfiguration *content = [(UIListContentConfiguration *)cell.contentConfiguration copy];
    content.textProperties.numberOfLines = 2;
    content.secondaryTextProperties.numberOfLines = 3;
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    UISwitch *toggle = [UISwitch new];
    toggle.accessibilityIdentifier = source[@"id"];
    toggle.accessibilityLabel = [self nameOf:source];
    toggle.on = enabled;
    [toggle addTarget:self action:@selector(toggleSource:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle; cell.editingAccessoryView = toggle;
    cell.showsReorderControl = YES;
    return cell;
}
- (void)toggleSource:(UISwitch *)sender {
    if (!SGAddonSetSourceEnabled(sender.accessibilityIdentifier, sender.on)) [self showMessage:@"저장하지 못했습니다. 기기 잠금을 해제하고 다시 시도해 주세요."];
    [self reloadSources];
}
- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path { return path.section == 0; }
- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path { return path.section == 0; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path { return UITableViewCellEditingStyleNone; }
- (BOOL)tableView:(UITableView *)table shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)path { return NO; }
- (NSIndexPath *)tableView:(UITableView *)table targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to { return to.section == 0 ? to : from; }
- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSString *identifier = self.sources[(NSUInteger)from.row][@"id"];
    if (!SGAddonMoveSource(identifier, (NSUInteger)to.row)) [self showMessage:@"소스 순서를 저장하지 못했습니다."];
    [self reloadSources];
}
- (void)refreshInfo:(NSString *)identifier {
    __weak SGAddonSourcesController *weakSelf = self;
    SGAddonRefreshSourceInfo(identifier, ^(NSString *error) {
        [weakSelf reloadSources];
        if (error) [weakSelf showMessage:error];
    });
}
- (void)addSource {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"추가 음원 서비스 연결" message:@"본인이 사용할 권한이 있는 HTTPS 루트 또는 manifest 링크를 입력하세요. 최대 8개를 저장합니다." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"HTTPS 소스 링크"; field.keyboardType = UIKeyboardTypeURL;
        field.autocorrectionType = UITextAutocorrectionTypeNo; field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak SGAddonSourcesController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"추가" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *input = alert.textFields.firstObject.text;
        if (!SGAddonAddSource(input)) { [weakSelf showMessage:@"소스를 추가하지 못했습니다. HTTPS 링크, 저장 가능한 개수와 기기 잠금 상태를 확인하세요."]; return; }
        [weakSelf reloadSources];
        // Fetch just manifest metadata, never a test search for every saved source.
        for (NSDictionary *source in weakSelf.sources) if ([source[@"url"] isEqual:SGAddonBaseURL(input).absoluteString]) { [weakSelf refreshInfo:source[@"id"]]; break; }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    SGShowAudioController(alert);
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    if (path.section == 1) { [self addSource]; return; }
    NSDictionary *source = self.sources[(NSUInteger)path.row];
    NSString *identifier = source[@"id"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[self nameOf:source] message:[self detailOf:source] preferredStyle:UIAlertControllerStyleAlert];
    __weak SGAddonSourcesController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"정보 새로고침" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf refreshInfo:identifier]; }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"소스 검사" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        SGAddonTestSource(identifier, ^(NSString *status) { [weakSelf reloadSources]; [weakSelf showMessage:status]; });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"삭제" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        if (!SGAddonRemoveSource(identifier)) [weakSelf showMessage:@"소스를 삭제하지 못했습니다."];
        [weakSelf reloadSources];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    SGShowAudioController(alert);
}
@end
UIViewController *SGAddonSourcesPage(void) { return [[SGAddonSourcesController alloc] initWithStyle:UITableViewStyleInsetGrouped]; }
