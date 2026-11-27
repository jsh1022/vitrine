#import <Foundation/Foundation.h>

// Protocol-compatible implementation informed by Laya/Mornye (see docs). No app proof is fabricated.
typedef NSDictionary * (^SGHostedRequest)(NSURLRequest *request);
BOOL SGHostedProvider(NSString *provider);
NSArray<NSString *> *SGHostedProviderIdentifiers(void);
NSString *SGHostedProviderName(NSString *provider);
BOOL SGHostedVerified(NSString *provider);
// Local evidence only: an elapsed server expiry or explicit gateway reauthentication response.
BOOL SGHostedAuthenticationExpired(NSString *provider);
BOOL SGHostedServerWaiting(void);
void SGHostedServerResponse(NSInteger status, NSString *retryAfter);
void SGHostedForget(NSString *provider);
void SGHostedCancelAuthentication(NSString *provider);
NSString *SGHostedAppVersion(NSString *provider);
NSDictionary *SGHostedSignedHeaders(NSDictionary *record, NSString *version, NSString *method,
                                   NSString *path, NSData *body, NSDate *date, NSString *nonce);
// All networking is delegated to the existing bounded, cancellable addon worker.
NSDictionary *SGHostedSearch(NSString *provider, NSString *query, SGHostedRequest request, NSString **error);
NSDictionary *SGHostedStream(NSString *provider, NSString *track, SGHostedRequest request, NSString **error);
NSDictionary *SGHostedStreamResponse(NSString *provider, NSDictionary *payload);
// Authentication runs on a separate serial queue; completion always returns on main.
void SGHostedBeginAuthentication(NSString *provider, void (^completion)(NSURL *challenge, NSString *error));
void SGHostedCompleteAuthentication(NSString *provider, NSString *grant, void (^completion)(NSString *error));
