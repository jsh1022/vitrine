#import "SGHostedAuthPolicy.h"

BOOL SGHostedAuthBrokerURL(NSURL *url) {
    return [url.scheme.lowercaseString isEqual:@"https"] && [url.host.lowercaseString isEqual:@"api.zarz.moe"] &&
        !url.user && !url.password && (!url.port || url.port.integerValue==443);
}
BOOL SGHostedAuthNavigationAllowed(NSURL *url, BOOL mainFrame) {
    // Turnstile creates sandboxed child frames using these browser-local documents.
    // They do not broaden top-level navigation or the trusted grant-message origin.
    if (!mainFrame && ([@"about:blank" isEqual:url.absoluteString] || [@"about:srcdoc" isEqual:url.absoluteString])) return YES;
    if (SGHostedAuthBrokerURL(url)) return YES;
    return !mainFrame && [url.scheme.lowercaseString isEqual:@"https"] && !url.user && !url.password &&
        (!url.port || url.port.integerValue==443) && [url.host.lowercaseString isEqual:@"challenges.cloudflare.com"];
}
NSString *SGHostedAuthGrant(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length>16384) return nil;
    NSString *grant=nil;
    if ([value hasPrefix:@"gr_"]) grant=value;
    else {
        NSURLComponents *u=[NSURLComponents componentsWithString:value];
        if (![u.scheme.lowercaseString isEqual:@"mornye"] || ![u.host isEqual:@"session-grant"] ||
            (u.path.length && ![u.path isEqual:@"/"]) || u.user || u.password || u.port || u.fragment) return nil;
        for (NSURLQueryItem *item in u.queryItems) if ([item.name isEqual:@"grant"]) { if(grant)return nil; grant=item.value; }
    }
    if (!grant.length || [grant rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound) return nil;
    return grant;
}
NSString *SGHostedAuthBridgeScript(void) {
    // The broker calls this after a real Turnstile verification. No widget API/token is altered.
    return @"window.MornyeGrant={postMessage:function(m){window.webkit.messageHandlers.mornyeGrant.postMessage(String(m))}};";
}
