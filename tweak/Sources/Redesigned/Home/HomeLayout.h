// Small, pure geometry helpers used by HomeHeader.x and its Mac-side layout checks.
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>

static inline CGRect SGRHomeClampPillToWidth(CGRect pill, CGFloat width, CGFloat margin) {
    CGFloat available = fmax(0, width - 2 * margin);
    if (pill.size.width > available) pill.size.width = available;
    CGFloat minimum = margin;
    CGFloat maximum = fmax(minimum, width - margin - pill.size.width);
    pill.origin.x = fmin(fmax(pill.origin.x, minimum), maximum);
    return pill;
}

static inline CGRect SGRHomeTintFrame(CGSize pageSize, CGFloat height) {
    return CGRectMake(0, 0, fmax(0, pageSize.width), height);
}
