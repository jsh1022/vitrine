#import "SGSourceSecrets.h"
#import <Security/Security.h>

static NSDictionary *query(NSString *account) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: @"spotifyglass.audio-sources",
             (__bridge id)kSecAttrAccount: account};
}
NSString *SGSourceSecret(NSString *account) {
    NSMutableDictionary *q = [query(account) mutableCopy];
    q[(__bridge id)kSecReturnData] = @YES;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef value = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &value) != errSecSuccess) return nil;
    return [[NSString alloc] initWithData:CFBridgingRelease(value) encoding:NSUTF8StringEncoding];
}
BOOL SGSaveSourceSecret(NSString *account, NSString *value) {
    NSDictionary *q = query(account);
    if (!value.length) {
        OSStatus s = SecItemDelete((__bridge CFDictionaryRef)q);
        return s == errSecSuccess || s == errSecItemNotFound;
    }
    NSDictionary *attributes = @{(__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus s = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)attributes);
    if (s == errSecItemNotFound) {
        NSMutableDictionary *item = [q mutableCopy];
        [item addEntriesFromDictionary:attributes];
        s = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return s == errSecSuccess;
}
