#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "WMBridgeProtocol.h"
#include <cstdio>
#include <cstdlib>

// Objective-C++ is the Chromium side of the wire. This program is a transport
// probe, not a browser or a latency benchmark for presentation/input readiness.
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    bool expect_rejection = argc == 2 && strcmp(argv[1], "--expect-rejection") == 0;
    SecCodeRef self = nullptr;
    CFDictionaryRef raw = nullptr;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) != errSecSuccess ||
        SecCodeCopySigningInformation(self, kSecCSSigningInformation, &raw) != errSecSuccess) return 2;
    NSDictionary *info = CFBridgingRelease(raw);
    CFRelease(self);
    NSString *team = info[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    if (team.length != 10) return 2;
    NSXPCConnection *connection = [[NSXPCConnection alloc]
        initWithMachServiceName:@"com.jameslyons.winmux.browser.alpha.workspace" options:0];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(WMWorkspaceBridge)];
    [connection setCodeSigningRequirement:[NSString stringWithFormat:
        @"anchor apple generic and identifier \"com.jameslyons.winmux.browser.alpha.workspace\" and certificate leaf[subject.OU] = \"%@\"", team]];
    [connection resume];
    id<WMWorkspaceBridge> remote = [connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
      fprintf(stderr, "XPC connection rejected: %ld\n", (long)error.code);
      exit(expect_rejection ? 0 : 1);
    }];
    [remote negotiateVersion:1 reply:^(NSInteger version, NSString *epoch) {
      if (expect_rejection || version != 1 || !epoch) exit(3);
      [remote pingEpoch:epoch sequence:1 reply:^(BOOL accepted, uint64_t sequence) {
        if (!accepted || sequence != 1) exit(4);
        [remote pingEpoch:epoch sequence:1 reply:^(BOOL duplicate, uint64_t ignored) {
          if (duplicate) exit(5);
          [remote pingEpoch:@"stale-epoch" sequence:2 reply:^(BOOL stale, uint64_t ignored2) {
            if (stale) exit(6);
            puts("PASS: authenticated Objective-C++/Swift XPC, duplicate and stale-epoch rejection");
            exit(0);
          }];
        }];
      }];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      fputs("FAIL: XPC proof timed out\n", stderr);
      exit(7);
    });
    dispatch_main();
  }
}
