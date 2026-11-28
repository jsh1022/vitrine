#import "SGRTrackPopularity.h"
#import "Core/SGCore.h"
#import "Shared/Player/SGTrackPopularity.h"
#import "Redesigned/Player/Player.h"
#import <objc/message.h>

static char kBinding;
static NSHashTable<UIView *> *cells;

@interface SGRPopularityRowBinding : NSObject
@property(nonatomic, copy) NSString *uri;
@property(nonatomic, strong) NSNumber *value;
@property(nonatomic, strong) UIView *badge;
@property(nonatomic, strong) UILabel *number;
@property(nonatomic, weak) UILabel *label;
@end
@implementation SGRPopularityRowBinding
@end

static void place(SGRPopularityRowBinding *binding, UIView *cell) {
    UILabel *label = binding.label;
    UIView *badge = binding.badge;
    badge.hidden = YES;
    if (!binding.value || !cell.window || !label.window || !SGFlag(SGRKeyPlayerPopularity, YES)) return;
    for (UIView *v = label; v && v != cell; v = v.superview) if (v.hidden || v.alpha < 0.01) return;
    CGRect frame = [label convertRect:label.bounds toView:cell];
    CGFloat textWidth = ceil([label.text sizeWithAttributes:@{NSFontAttributeName:label.font}].width);
    // A truncated/marquee label has no free space beside its text.
    if (textWidth > frame.size.width + 0.5) return;
    binding.number.text = binding.value.stringValue;
    CGFloat width = ceil([binding.number sizeThatFits:CGSizeMake(CGFLOAT_MAX, 16)].width) + 22;
    CGFloat x = CGRectGetMinX(frame) + textWidth + 8;
    CGFloat y = CGRectGetMidY(frame) - 8;
    // Stay inside the label's original text slot, never under explicit/menu controls.
    if (x + width > CGRectGetMaxX(frame) || y < 0 || y + 16 > cell.bounds.size.height) return;
    badge.frame = CGRectMake(x, y, width, 16);
    badge.layer.cornerRadius = 8;
    binding.number.frame = CGRectMake(17, 0, width - 22, 16);
    badge.backgroundColor = [UIColor colorWithWhite:0.10 alpha:UIAccessibilityIsReduceTransparencyEnabled() ? 1 : 0.35];
    badge.accessibilityLabel = [NSString stringWithFormat:@"인기도 %@", binding.value];
    badge.hidden = NO;
}
void SGRTrackPopularityRow(UIView *cell, UIView *title) {
    SGRPopularityRowBinding *binding = objc_getAssociatedObject(cell, &kBinding);
    if (!SGFlag(SGRKeyPlayerPopularity, YES) || !title) {
        binding.uri = nil; binding.value = nil; binding.badge.hidden = YES; return;
    }
    if (!cell.window) { binding.badge.hidden = YES; return; }
    __block UILabel *label = nil;
    SGForEachView(title, ^(UIView *view) {
        if (!label && [view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) label = (UILabel *)view;
    });
    if (!label) { binding.badge.hidden = YES; return; }
    Class identity = NSClassFromString(@"SGRPopularityIdentity");
    SEL selector = NSSelectorFromString(@"trackURIFromObject:");
    NSString *uri = [identity respondsToSelector:selector] ? ((id (*)(id, SEL, id))objc_msgSend)(identity, selector, cell) : nil;
    if (!uri) { binding.uri = nil; binding.value = nil; binding.badge.hidden = YES; return; }
    if (!binding) {
        binding = [SGRPopularityRowBinding new];
        binding.badge = [UIView new]; binding.badge.userInteractionEnabled = NO;
        binding.badge.isAccessibilityElement = YES;
        UIImageView *flame = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"flame.fill"
            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIImageSymbolWeightMedium]]];
        flame.tintColor = UIColor.whiteColor; flame.contentMode = UIViewContentModeScaleAspectFit;
        flame.frame = CGRectMake(5, 3, 9, 10); [binding.badge addSubview:flame];
        binding.number = [UILabel new]; binding.number.font = [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightMedium];
        binding.number.textColor = UIColor.whiteColor; [binding.badge addSubview:binding.number];
        objc_setAssociatedObject(cell, &kBinding, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cell addSubview:binding.badge];
        if (!cells) cells = [NSHashTable weakObjectsHashTable]; [cells addObject:cell];
    }
    binding.label = label;
    if ([binding.uri isEqualToString:uri]) { place(binding, cell); return; }
    binding.uri = uri; binding.value = nil; binding.badge.hidden = YES;
    __weak UIView *weakCell = cell;
    __weak SGRPopularityRowBinding *weakBinding = binding;
    SGTrackPopularityRequest(uri, ^(NSNumber *value) {
        SGRPopularityRowBinding *current = weakBinding;
        if (!current || ![current.uri isEqualToString:uri]) return;
        current.value = value;
        if (weakCell) place(current, weakCell);
    });
}
void SGRTrackPopularityRowsChanged(void) {
    for (UIView *cell in cells) {
        SGRPopularityRowBinding *binding = objc_getAssociatedObject(cell, &kBinding);
        binding.uri = nil; binding.value = nil; binding.badge.hidden = YES;
        [cell setNeedsLayout];
    }
}
