#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../../tweak/Sources/Redesigned/Home/HomeLayout.h"

static void stays_inside_after_rotation(CGFloat width, CGRect proposed) {
    CGRect pill = SGRHomeClampPillToWidth(proposed, width, 16);
    assert(CGRectGetMinX(pill) >= 16);
    assert(CGRectGetMaxX(pill) <= width - 16);
}

int main(void) {
    // Landscape -> portrait with a stale trailing-edge position, then a wide iPad layout.
    stays_inside_after_rotation(834, CGRectMake(720, 64, 110, 44));
    stays_inside_after_rotation(390, CGRectMake(720, 64, 110, 44));
    stays_inside_after_rotation(1024, CGRectMake(-80, 64, 110, 44));

    CGRect tint = SGRHomeTintFrame(CGSizeMake(390, 900), 480);
    assert(tint.size.width == 390 && tint.size.height == 480);
    tint = SGRHomeTintFrame(CGSizeMake(1024, 768), 480);
    assert(tint.size.width == 1024 && tint.size.height == 480);
    puts("home layout geometry: passed");
    return 0;
}
