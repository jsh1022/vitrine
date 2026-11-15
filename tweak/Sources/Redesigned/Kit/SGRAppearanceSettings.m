#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "SGRAccent.h"
#import "SGRHeaderInfo.h"

// The preset is read off the color stored, so the hooks keep the one key they read and a color set before
// presets existed stays in effect: Apple Music's red reads as Apple Music, Spotify's own (-1) as Spotify, and
// any other color as Custom, the redesign's own green when nothing is stored among them. The custom color
// is put aside while a preset is in place, so Custom brings it back.
static NSArray<NSString *> *presets(void) {
    return @[@"Spotify", @"Apple Music", @"사용자 설정"];
}

static NSInteger preset(void) {
    NSInteger rgb = SGInt(SGRKeyAccent, SGRDefaultAccent);
    if (rgb < 0 || rgb > 0xFFFFFF) return 0;
    return rgb == SGAppleMusicRed ? 1 : 2;
}

static void choosePreset(NSInteger index) {
    if (preset() == 2) SGSetInt(SGRKeyAccentCustom, SGRAccentRGB());
    NSInteger custom = SGInt(SGRKeyAccentCustom, SGRDefaultAccent);
    if (custom < 0 || custom > 0xFFFFFF) custom = SGRDefaultAccent;
    SGSetInt(SGRKeyAccent, index == 0 ? -1 : index == 1 ? SGAppleMusicRed : custom);
}

// The redesign's rows of the Appearance page (App/Pages.m): the preset from a menu, then the color in effect,
// which opens the picker; a color stored from there is Custom. AMOLED has no row: the redesign is always black.
NSArray<SGModRow *> *SGRAppearanceRows(void) {
    SGModRow *menu = SGMenuRow(@"강조 색상 프리셋", presets(), ^NSString *{ return presets()[(NSUInteger)preset()]; },
                               ^(NSInteger index) { choosePreset(index); });
    SGModRow *colour = SGStatActionRow(@"강조 색상", nil, ^NSString *{ return [NSString stringWithFormat:@"#%06lX", (long)SGRAccentRGB()]; }, ^{
        SGPickColor(@"강조 색상", SGRAccentRGB(), ^(NSInteger rgb) {
            SGSetInt(SGRKeyAccent, rgb);
            SGSetInt(SGRKeyAccentCustom, rgb);
        });
    });
    colour.swatch = ^UIColor *{ return SGColorRGB(SGRAccentRGB()); };
    return @[
        SGWithSymbol(menu, @"paintpalette"),
        SGWithSymbol(colour, @"eyedropper"),
        SGWithSymbol(SGOptionRow(@"단순 체크 표시", @"저장한 곡의 체크 표시를 원 없이 강조 색상으로 표시", SGRKeyPlainCheck), @"checkmark"),
        SGWithSymbol(SGSwitchRow(@"상단 전체 너비 커버", @"앨범과 플레이리스트 커버를 상단 전체 너비로 표시합니다. 끄면 정사각형 커버를 사용하며 움직이는 커버는 상단을 계속 채웁니다.", SGRKeyFullBleedCovers), @"photo"),
    ];
}
