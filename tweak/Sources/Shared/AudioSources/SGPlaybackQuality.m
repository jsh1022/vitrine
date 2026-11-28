#import "SGPlaybackQuality.h"
#import "SGAddons.h"
#import "SGAudioPresentation.h"
#import "Shared/Lossless/SGLossless.h"
#import "Shared/Player/SpeedPitch.h"
#import <AVFoundation/AVFoundation.h>

static NSString *rateText(double rate) {
    return rate > 0 ? [NSString stringWithFormat:@"%g kHz", rate / 1000] : @"확인 불가";
}
NSDictionary<NSString *, NSString *> *SGPlaybackQualityInfo(void) {
    BOOL external = SGLosslessRendering();
    NSDictionary *info = external ? SGLosslessSourceInfo() : @{};
    double rate = [info[@"rate"] doubleValue];
    NSInteger bits = [info[@"bits"] integerValue];
    AudioStreamBasicDescription client = {0};
    BOOL knownClient = external && info.count && SGPlayerMusicClientFormat(&client) && client.mSampleRate > 0;
    double output = AVAudioSession.sharedInstance.sampleRate;
    // BitChord NerdStats.isHiRes: measured depth > 16 OR measured rate > 48 kHz.
    NSString *quality = external && info.count ? (rate > 48000 || bits > 16 ? @"고해상도 무손실" : @"무손실") : @"확인 불가";
    NSString *depth = bits > 0 ? [NSString stringWithFormat:@" · %ld비트", (long)bits] : @"";
    BOOL known = external && rate > 0 && knownClient && output > 0;
    BOOL converted = known && (fabs(rate - client.mSampleRate) > 0.5 || fabs(client.mSampleRate - output) > 0.5);
    NSString *source = external ? (SGAddonMediaInfo()[@"sourceName"] ?: @"로컬 파일") : @"Spotify";
    NSString *label = external && info.count ? quality : @"기본";
    return @{@"label": label,
             @"shines": external && info.count ? @"1" : @"0",
             @"symbol": @"waveform",
             @"quality": external && info.count ? [quality stringByAppendingString:depth] : label,
             @"sourceRate": rateText(rate), @"outputRate": rateText(output),
             @"resampling": known ? (converted ? @"예" : @"아니요") : @"확인 불가", @"source": source};
}

@interface SGPlaybackQualityPopover : UIViewController <UIPopoverPresentationControllerDelegate>
@property(nonatomic, strong) UIStackView *contentStack;
@end
@implementation SGPlaybackQualityPopover
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    // Let UIKit draw the same translucent material and arrow as other system presentations.
    self.view.backgroundColor = UIColor.clearColor;
    NSDictionary *info = SGPlaybackQualityInfo();
    UILabel *title = [UILabel new]; title.text = @"오디오 품질";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.adjustsFontForContentSizeCategory = YES; title.textColor = UIColor.labelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title]];
    self.contentStack = stack;
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 10;
    [stack setCustomSpacing:16 afterView:title];
    NSArray *names = @[@"음질", @"샘플레이트", @"출력", @"리샘플링", @"소스"];
    NSArray *keys = @[@"quality", @"sourceRate", @"outputRate", @"resampling", @"source"];
    for (NSUInteger i = 0; i < names.count; ++i) {
        UILabel *name = [UILabel new]; name.text = names[i]; name.textColor = UIColor.secondaryLabelColor;
        name.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        name.adjustsFontForContentSizeCategory = YES; name.numberOfLines = 0;
        UILabel *value = [UILabel new]; value.text = info[keys[i]]; value.textColor = UIColor.labelColor;
        value.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleSubheadline] scaledFontForFont:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium]];
        value.adjustsFontForContentSizeCategory = YES; value.numberOfLines = 0;
        value.textAlignment = NSTextAlignmentRight;
        [name.widthAnchor constraintEqualToConstant:90].active = YES;
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, value]];
        row.axis = UILayoutConstraintAxisHorizontal; row.spacing = 10; row.alignment = UIStackViewAlignmentTop;
        [stack addArrangedSubview:row];
    }
    UIButton *details = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = @"상세 재생 정보 보기";
    configuration.baseForegroundColor = UIColor.labelColor;
    configuration.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(10, 12, 10, 12);
    details.configuration = configuration;
    details.accessibilityIdentifier = @"vitrine.audio-quality.details";
    [details.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [details addTarget:self action:@selector(showDetails) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:details];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-18],
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:18],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:-8],
    ]];
    self.view.accessibilityIdentifier = @"vitrine.audio-quality.popover";
    [self updateContentSize];
}
- (void)updateContentSize {
    CGFloat width = self.preferredContentSize.width > 0 ? self.preferredContentSize.width : 310;
    if (self.view.window && self.view.bounds.size.width > 36) width = self.view.bounds.size.width;
    CGSize content = [self.contentStack systemLayoutSizeFittingSize:CGSizeMake(width - 36, UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    CGSize size = CGSizeMake(width, ceil(content.height) + 18 + 8);
    if (fabs(self.preferredContentSize.height - size.height) > 0.5 || fabs(self.preferredContentSize.width - size.width) > 0.5)
        self.preferredContentSize = size;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateContentSize];
}
- (void)showDetails {
    [self dismissViewControllerAnimated:YES completion:^{ SGShowPlaybackDetails(); }];
}
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller {
    return UIModalPresentationNone;
}
- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traits {
    return UIModalPresentationNone;
}
@end

void SGShowPlaybackQuality(UIView *anchor) {
    if (!NSThread.isMainThread || !anchor.window) return;
    SGPlaybackQualityPopover *controller = [SGPlaybackQualityPopover new];
    controller.modalPresentationStyle = UIModalPresentationPopover;
    [controller loadViewIfNeeded];
    UIPopoverPresentationController *popover = controller.popoverPresentationController;
    popover.sourceView = anchor; popover.sourceRect = anchor.bounds;
    popover.permittedArrowDirections = UIPopoverArrowDirectionDown | UIPopoverArrowDirectionUp;
    popover.backgroundColor = nil; popover.delegate = controller;
    SGShowAudioController(controller);
}
