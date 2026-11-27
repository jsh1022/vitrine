#import <Foundation/Foundation.h>

// Shared by the real WKWebView delegate and offline regression fixtures.
BOOL SGHostedAuthNavigationAllowed(NSURL *url, BOOL mainFrame);
BOOL SGHostedAuthBrokerURL(NSURL *url);
NSString *SGHostedAuthGrant(NSString *value);
NSString *SGHostedAuthBridgeScript(void);
