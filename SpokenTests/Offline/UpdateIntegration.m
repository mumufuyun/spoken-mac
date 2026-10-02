#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

// An isolated app exercises Sparkle's real download, validation, installer and relaunch.
// It never loads Spoken's configuration, microphone, shortcuts, or credentials.
static void record(NSString *event) {
    NSString *path = NSBundle.mainBundle.infoDictionary[@"TestResultPath"];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file) { [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; file = [NSFileHandle fileHandleForWritingAtPath:path]; }
    [file seekToEndOfFile];
    [file writeData:[[event stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [file closeFile];
}

#import "UpdateIntegration.h"
@implementation TestDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { record(@"CHECK"); }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    record([@"FOUND " stringByAppendingString:item.versionString]); reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    record(@"NO_UPDATE"); acknowledgement(); [NSApp terminate:nil];
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    record([NSString stringWithFormat:@"ERROR %ld %@", (long)error.code, error.localizedDescription]);
    acknowledgement(); [NSApp terminate:nil];
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { record(@"DOWNLOAD"); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { record(@"EXTRACT"); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { record(@"READY"); reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement { record(@"INSTALLED"); acknowledgement(); }
- (void)dismissUpdateInstallation {}
- (void)showUpdateInFocus {}
@end

