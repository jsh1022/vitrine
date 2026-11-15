#import "Settings/SGModPage.h"
#import "Privacy.h"

SGModSection *SGPrivacySection(void) {
    return SGSection(@"개인정보", @[
        SGWithSymbol(SGSwitchRow(@"원격 분석 차단", @"최근 항목에 필요한 Spotify 자체 이벤트는 계속 전송됩니다", SGKeyBlockTelemetry), @"antenna.radiowaves.left.and.right.slash"),
        SGWithSymbol(SGSwitchRow(@"공유 링크 추적 제거", @"복사하거나 공유하는 링크에서 추적 정보(si, utm)를 제거합니다", SGKeyCleanLinks), @"link"),
    ]);
}

SGModSection *SGPrivacyCountersSection(void) {
    NSMutableArray<SGModRow *> *counts = [NSMutableArray array];
    for (NSString *label in SGBlockedLabels()) {
        [counts addObject:SGStatRow(label, ^NSString *{
            return @(SGBlockedCount(label)).stringValue;
        })];
    }
    [counts addObject:SGStatRow(@"합계", ^NSString *{
        return @(SGBlockedCount(nil)).stringValue;
    })];
    [counts addObject:SGActionRow(@"원격 분석 카운터 초기화", nil, ^{ SGResetBlocked(); })];
    return SGSection(@"차단한 원격 분석 수", counts);
}
