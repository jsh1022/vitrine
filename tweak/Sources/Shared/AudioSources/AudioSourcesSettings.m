#import "SGAddons.h"
#import "SGWireGuard.h"
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static void message(NSString *title, NSString *text) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    SGPresentDark(alert);
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
    dispatch_async(dispatch_get_main_queue(), ^{ message(@"WireGuard", ok ? @"Profile validated and saved in this device's Keychain. Enable WireGuard to tunnel addon requests." : reason ?: @"Choose a UTF-8 WireGuard .conf file smaller than 64 KiB."); });
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
        SGPresentDark(alert);
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
            SGPresentDark(alert);
        });
        row.visible = ^BOOL { return sourceAt(i) != nil; };
        [rows addObject:row];
    }
    SGModPage *page = [[SGModPage alloc] initWithTitle:@"Lossless sources & WireGuard" intro:@"Enable Lossless files on the Player page and restart Spotify once to install the playback hooks. Source and network settings below apply to new requests."
        sections:@[
            SGNotedSection(@"Playback", @[enabled, cellular, SGActionRow(@"Retry current track", @"Respects each source's request budget", ^{ SGAddonRetryCurrentTrack(); }), SGStatRow(@"Preparation", ^NSString *{ return SGAddonStatus(); })], @"Direct stereo FLAC/ALAC files only. Each file is checked by the native decoder and aligned against Spotify's sound. HLS, DASH, DRM and official-app-only sources are unsupported. Karaoke and speeds other than 1× retain Spotify audio."),
            SGSection(@"Sources (in priority order)", rows),
            SGNotedSection(@"App-local WireGuard", @[
                tunnel,
                SGStatRow(@"Profile", ^NSString *{ return SGWireGuardHasProfile() ? @"Saved in Keychain" : @"Not imported"; }),
                SGStatRow(@"Tunnel", ^NSString *{ return SGWireGuardStatus()[@"state"]; }),
                SGStatRow(@"Last handshake", ^NSString *{
                    NSNumber *age = SGWireGuardStatus()[@"engine"][@"handshakeAgeSec"];
                    return age && age.doubleValue >= 0 ? [NSString stringWithFormat:@"%.0f s ago", age.doubleValue] : @"Not verified";
                }),
                SGActionRow(@"Import .conf file", @"Single-peer WireGuard profile", ^{
                    sg_importer = [SGWGImporter new];
                    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:NO];
                    picker.delegate = sg_importer;
                    SGPresentDark(picker);
                }),
                SGActionRow(@"Delete saved profile", @"Disable WireGuard and restart to stop the running engine", ^{
                    SGSetEnabled(SGKeySourceWireGuard, NO); SGAddonRetryCurrentTrack();
                    message(@"WireGuard", SGWireGuardDelete() ? @"Saved profile deleted. Restart Spotify to release an engine already running in memory." : @"Keychain could not delete the profile.");
                    [weakPage refreshVisibility];
                }),
            ], @"This is not a system VPN and does not tunnel Spotify's own traffic. When enabled, an unavailable tunnel blocks addon requests. No direct fallback. The server endpoint's hostname may require local DNS before the tunnel starts. A ready proxy does not prove a successful peer handshake."),
        ] footer:@"No provider endpoints or credentials are bundled. Requests identify this client as Vitrine. Source URLs and WireGuard keys are excluded from settings backups."];
    weakPage = page;
    return page;
}
