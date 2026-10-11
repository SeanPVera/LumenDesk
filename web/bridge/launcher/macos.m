#import <AppKit/AppKit.h>

@interface BridgeLauncher : NSObject <NSApplicationDelegate>
@property(strong) NSStatusItem *status;
@property(strong) NSTask *task;
@property(strong) NSPipe *input;
@property(strong) NSPipe *output;
@property(strong) NSMutableData *buffer;
@property(copy) NSString *url;
@property BOOL quitting;
@property BOOL errorShown;
@property BOOL ready;
@end

@implementation BridgeLauncher
- (void)showError:(NSString *)message {
    if (self.quitting || self.errorShown) return;
    self.errorShown = YES;
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"LumenDesk Bridge could not connect";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"Quit"];
    [alert runModal];
    [NSApp terminate:nil];
}
- (void)open:(id)sender {
    if (self.url) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:self.url]];
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    [self open:nil];
    return YES;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.status = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.status.button.title = @"LD";
    self.status.button.toolTip = @"LumenDesk Bridge — Open or Quit";
    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"LumenDesk Bridge" action:nil keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *open = [menu addItemWithTitle:@"Open LumenDesk" action:@selector(open:) keyEquivalent:@""];
    open.target = self;
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit LumenDesk Bridge" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    self.status.menu = menu;
    self.buffer = [NSMutableData data];
    self.input = [NSPipe pipe];
    self.output = [NSPipe pipe];
    self.task = [[NSTask alloc] init];
    NSString *resources = NSBundle.mainBundle.resourcePath;
    self.task.executableURL = [NSURL fileURLWithPath:[resources stringByAppendingPathComponent:@"runtime/node"]];
    self.task.arguments = @[[resources stringByAppendingPathComponent:@"launcher/launch.mjs"]];
    self.task.standardInput = self.input;
    self.task.standardOutput = self.output;
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@".lumendesk"];
    NSError *directoryError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:&directoryError];
    NSString *log = [directory stringByAppendingPathComponent:@"bridge-launcher.log"];
    if (![[NSFileManager defaultManager] createFileAtPath:log contents:nil attributes:@{NSFilePosixPermissions: @0600}]) {
        [self showError:@"LumenDesk cannot write its local log. Check that your home folder is writable, then reopen the app."];
        return;
    }
    self.task.standardError = [NSFileHandle fileHandleForWritingAtPath:log];
    __weak BridgeLauncher *weakSelf = self;
    self.output.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) { handle.readabilityHandler = nil; return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            BridgeLauncher *owner = weakSelf;
            if (!owner) return;
            [owner.buffer appendData:data];
            for (;;) {
                const unsigned char *bytes = owner.buffer.bytes;
                NSUInteger length = owner.buffer.length, end = 0;
                while (end < length && bytes[end] != '\n') end++;
                if (end == length) break;
                NSData *line = [owner.buffer subdataWithRange:NSMakeRange(0, end)];
                [owner.buffer replaceBytesInRange:NSMakeRange(0, end + 1) withBytes:NULL length:0];
                NSDictionary *event = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                if ([event[@"event"] isEqual:@"ready"]) {
                    owner.ready = YES;
                    owner.url = event[@"url"];
                    [owner open:nil];
                } else if ([event[@"event"] isEqual:@"error"]) {
                    [owner showError:event[@"message"] ?: @"Reopen the app to try again."];
                }
            }
        });
    };
    self.task.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BridgeLauncher *owner = weakSelf;
            if (!owner.quitting && task.terminationStatus != 0) {
                [owner showError:@"The local bridge stopped. Reopen LumenDesk Bridge to reconnect. Details are in ~/.lumendesk/bridge-launcher.log."];
            }
        });
    };
    NSError *error = nil;
    if (![self.task launchAndReturnError:&error]) [self showError:error.localizedDescription];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    self.quitting = YES;
    if (self.task.running) {
        @try { [self.input.fileHandleForWriting writeData:[@"quit\n" dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (NSException *exception) { [self.task terminate]; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (self.task.running) [self.task terminate];
        });
        return NSTerminateLater;
    }
    return NSTerminateNow;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.input.fileHandleForWriting closeFile];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--smoke-test") == 0) {
            NSString *resources = NSBundle.mainBundle.resourcePath;
            NSTask *task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:[resources stringByAppendingPathComponent:@"runtime/node"]];
            task.arguments = @[[resources stringByAppendingPathComponent:@"launcher/launch.mjs"], @"--smoke-test"];
            NSError *error = nil;
            if (![task launchAndReturnError:&error]) { NSLog(@"%@", error); return 1; }
            [task waitUntilExit];
            return task.terminationStatus;
        }
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        BridgeLauncher *launcher = [[BridgeLauncher alloc] init];
        app.delegate = launcher;
        // Wait for the child to finish cleanup when Quit is selected.
        [[NSNotificationCenter defaultCenter] addObserverForName:NSTaskDidTerminateNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                if (launcher.quitting && note.object == launcher.task) [app replyToApplicationShouldTerminate:YES];
            }];
        [app run];
    }
    return 0;
}
