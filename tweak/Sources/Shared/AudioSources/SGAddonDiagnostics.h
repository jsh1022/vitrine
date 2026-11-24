#import <Foundation/Foundation.h>

// In-memory, sanitized preparation diagnostics. Safe to call from any thread.
void SGAddonDiagnostic(NSString *sourceID, NSString *stage, NSString *event, NSDictionary *details);
NSArray<NSDictionary *> *SGAddonDiagnosticEvents(void);
void SGAddonDiagnosticsNameSource(NSString *sourceID, NSString *name);
NSString *SGAddonDiagnosticsSourceName(NSString *sourceID);
void SGAddonDiagnosticsBindFile(NSString *path, NSString *sourceID);
NSString *SGAddonDiagnosticSourceForFile(NSString *path);
NSString *SGAddonDiagnosticsSafeText(NSString *text);
NSString *SGAddonDiagnosticsSafeSourceID(NSString *sourceID);
void SGShowAddonPreparationDetails(void);
