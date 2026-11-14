#import "SGAddons.h"
#import "SGWireGuard.h"
#import "SGAudioPresentation.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static void message(NSString *title, NSString *text) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    SGShowAudioController(alert);
}
@interface SGWGImporter : NSObject <UIDocumentPickerDelegate>
@end
static SGWGImporter *sg_importer;
@implementation SGWGImporter
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    BOOL access = [url startAccessingSecurityScopedResource];
    NSNumber *size;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    NSString *text = size && size.unsignedLongLongValue <= 65536 ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (access) [url stopAccessingSecurityScopedResource];
    NSString *reason;
    BOOL ok = text.length && SGWireGuardImport(text, &reason);
    if (ok) SGAddonRetryCurrentTrack();
    dispatch_async(dispatch_get_main_queue(), ^{ message(@"WireGuard", ok ? @"Profile validated and saved in this device's Keychain. Enable Spotify app proxy and restart, or select optional addon-only routing." : reason ?: @"Choose a UTF-8 WireGuard .conf file smaller than 64 KiB."); });
    sg_importer = nil;
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { sg_importer = nil; }
@end
static NSDictionary *sourceAt(NSUInteger index) {
    NSArray *sources = SGAddonSources();
    return index < sources.count ? sources[index] : nil;
}
UIViewController *SGAudioSourcesPage(void) {
    __block __weak SGModPage *weakPage;
    SGModRow *enabled = SGOptionRow(@"HTTP lossless addons", @"Prepare a matching file while Spotify plays", SGKeyAddons);
    enabled.changed = ^(BOOL on) { SGAddonRetryCurrentTrack(); };
    SGModRow *cellular = SGOptionRow(@"Allow cellular downloads", @"Off: only unmetered networks; files can be up to 128 MiB", SGKeyAddonCellular);
    cellular.changed = ^(BOOL on) { SGAddonRetryCurrentTrack(); };
    SGModRow *tunnel = SGOptionRow(@"WireGuard for addons", @"Addon JSON and audio only · iOS 17+", SGKeySourceWireGuard);
    tunnel.changed = ^(BOOL on) { SGAddonRetryCurrentTrack(); };
    SGModRow *add = SGActionRow(@"Add source", @"Paste a generated HTTPS root or manifest URL", ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add lossless source" message:@"Use a server you can access. Setup webpages are not addon URLs. Sources are tried in the order added (up to eight)." preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = @"https://server/secret/manifest.json";
            field.keyboardType = UIKeyboardTypeURL; field.secureTextEntry = YES;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Add" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (!SGAddonAddSource(alert.textFields.firstObject.text)) message(@"Source not saved", @"Use an HTTPS root or manifest URL, with no username or password. A maximum of eight sources is supported. Keychain must be available.");
            [weakPage refreshVisibility];
        }]];
        SGShowAudioController(alert);
    });
    NSMutableArray *rows = [NSMutableArray arrayWithObject:add];
    for (NSUInteger i = 0; i < 8; i++) {
        SGModRow *row = SGActionRow([NSString stringWithFormat:@"Source %lu", (unsigned long)i + 1], @"Test or remove", ^{
            NSDictionary *source = sourceAt(i);
            if (!source) return;
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Lossless source" message:@"Source URLs are credentials and are kept in Keychain. A manifest test uses the same network and WireGuard settings as playback." preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Test manifest" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                SGAddonTestSource(source[@"id"], ^(NSString *status) { message(@"Source test", status); });
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
                if (!SGAddonRemoveSource(source[@"id"])) message(@"Could not remove source", @"Keychain is unavailable. Try again after unlocking the device.");
                [weakPage refreshVisibility];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            SGShowAudioController(alert);
        });
        row.visible = ^BOOL { return sourceAt(i) != nil; };
        [rows addObject:row];
    }
    SGModPage *page = [[SGModPage alloc] initWithTitle:@"Lossless sources" intro:@"Enable Lossless files on the Player page and restart Spotify once to install the playback hooks. Source and network settings below apply to new requests."
        sections:@[
            SGNotedSection(@"Playback", @[enabled, cellular, SGActionRow(@"Retry current track", @"Respects each source's request budget", ^{ SGAddonRetryCurrentTrack(); }), SGStatRow(@"Preparation", ^NSString *{ return SGAddonStatus(); })], @"Direct stereo FLAC/ALAC files only. Each file is checked by the native decoder and aligned against Spotify's sound. HLS, DASH, DRM and official-app-only sources are unsupported. Karaoke and speeds other than 1× retain Spotify audio."),
            SGSection(@"Sources (in priority order)", rows),
            SGNotedSection(@"Optional routing", @[tunnel,
                SGPageRow(@"WireGuard proxy", ^UIViewController *{ return SGWireGuardSettingsPage(); }),
            ], @"Addons work without WireGuard. App proxy mode applies to their URLSession traffic too, regardless of this per-addon switch."),
        ] footer:@"No provider endpoints or credentials are bundled. Requests identify this client as Vitrine. Source URLs and WireGuard keys are excluded from settings backups."];
    weakPage = page;
    return page;
}

UIViewController *SGWireGuardSettingsPage(void) {
    __block BOOL testing = NO;
    __block NSString *testState = @"Not run";
    SGModRow *app = SGOptionRow(@"Spotify app proxy", @"Route URLSession through WireGuard · restart required", SGKeyAppWireGuard);
    app.changed = ^(BOOL on) {
        if (on) {
            BOOL supported = NO;
#if SG_WIREGUARD
            supported = [NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){17, 0, 0}];
#endif
            if (!supported || !SGWireGuardHasProfile()) {
                SGSetEnabled(SGKeyAppWireGuard, NO);
                message(@"WireGuard not enabled", supported ? @"Import a valid .conf profile first, then enable the app proxy." : @"This feature requires iOS 17+ and a build with WireGuard included.");
                return;
            }
        }
        message(@"Restart Spotify", @"The app-wide URLSession proxy is selected at launch. Fully close and reopen Spotify to apply this change. Import your profile before enabling. Lossless addons can stay off.");
    };
    return [[SGModPage alloc] initWithTitle:@"WireGuard proxy" intro:@"Import your own .conf, optionally test tunnel DNS, then enable Spotify app proxy and restart Spotify. Requires iOS 17+."
        sections:@[
            SGNotedSection(@"App-local WireGuard", @[
                app,
                SGStatRow(@"App proxy this launch", ^NSString *{ return SGWireGuardAppProxyActive() ? @"On · disable requires restart" : @"Off · enable requires restart"; }),
                SGStatRow(@"Routed configurations", ^NSString *{ return [SGWireGuardProxyCounters()[@"configurations"] stringValue]; }),
                SGStatRow(@"Blocked configurations", ^NSString *{ return [SGWireGuardProxyCounters()[@"blockedConfigurations"] stringValue]; }),
                SGStatRow(@"Proxy TCP connections", ^NSString *{
                    NSNumber *count = SGWireGuardStatus()[@"engine"][@"connections"][@"total"];
                    return count ? count.stringValue : @"0";
                }),
                SGStatRow(@"Tunnel bytes received / sent", ^NSString *{
                    NSDictionary *engine = SGWireGuardStatus()[@"engine"];
                    return [NSString stringWithFormat:@"%.1f / %.1f KiB", [engine[@"wgRxBytes"] doubleValue] / 1024, [engine[@"wgTxBytes"] doubleValue] / 1024];
                }),
                SGStatRow(@"Profile", ^NSString *{ return SGWireGuardHasProfile() ? @"Saved in Keychain" : @"Not imported"; }),
                SGStatRow(@"Tunnel", ^NSString *{ return SGWireGuardStatus()[@"state"]; }),
                SGStatRow(@"Last handshake", ^NSString *{
                    NSNumber *age = SGWireGuardStatus()[@"engine"][@"handshakeAgeSec"];
                    return age && age.doubleValue >= 0 ? [NSString stringWithFormat:@"%.0f s ago", age.doubleValue] : @"Not verified";
                }),
                SGStatRow(@"Tunnel DNS test", ^NSString *{ return testState; }),
                SGActionRow(@"Test tunnel DNS", @"Resolve api.spotify.com through the peer", ^{
                    if (testing) return;
                    testing = YES; testState = @"Testing…";
                    SGWireGuardTestDNS(^(NSString *result) { testing = NO; testState = result; message(@"WireGuard test", result); });
                }),
                SGActionRow(@"Import .conf file", @"Single-peer profile · numeric DNS · default routes", ^{
                    sg_importer = [SGWGImporter new];
                    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
                    picker.delegate = sg_importer;
                    SGShowAudioController(picker);
                }),
                SGActionRow(@"Delete saved profile", @"Disable WireGuard and restart to stop the running engine", ^{
                    SGSetEnabled(SGKeyAppWireGuard, NO); SGSetEnabled(SGKeySourceWireGuard, NO); SGAddonRetryCurrentTrack();
                    message(@"WireGuard", SGWireGuardDelete() ? @"Saved profile deleted. Restart Spotify to release an engine already running in memory." : @"Keychain could not delete the profile.");
                }),
            ], @"This app-local proxy routes new Spotify/Vitrine URLSession traffic, even with lossless addons off. It is not a system VPN. Raw sockets, Spotify Connect discovery, other apps, and WebKit/AVFoundation processes are outside the verified scope. Enabled URLSession configurations block when the tunnel is unavailable. A ready proxy does not prove a peer handshake. A hostname peer endpoint requires one local DNS lookup at startup."),
        ] footer:@"Keep the same signed app Identifier when reinstalling to preserve Keychain. To replace or stop an in-memory engine, disable both app and addon routing and restart first."];
}
