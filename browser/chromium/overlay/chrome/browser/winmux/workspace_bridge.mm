#include "chrome/browser/winmux/workspace_bridge.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>

#include "base/command_line.h"
#include "base/strings/sys_string_conversions.h"
#import "chrome/browser/winmux/WMBridgeProtocol.h"

namespace {
NSString* const kBrowserID = @"com.jameslyons.winmux.browser.alpha";
NSString* const kHelperID = @"com.jameslyons.winmux.browser.alpha.workspace";

NSString* OwnTeam() {
  SecCodeRef code = nullptr;
  SecStaticCodeRef static_code = nullptr;
  CFDictionaryRef raw = nullptr;
  if (SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess)
    return nil;
  OSStatus status = SecCodeCopyStaticCode(code, kSecCSDefaultFlags, &static_code);
  CFRelease(code);
  if (status != errSecSuccess)
    return nil;
  status = SecCodeCopySigningInformation(static_code, kSecCSSigningInformation, &raw);
  CFRelease(static_code);
  if (status != errSecSuccess)
    return nil;
  NSDictionary* info = CFBridgingRelease(raw);
  NSString* team = info[(__bridge NSString*)kSecCodeInfoTeamIdentifier];
  NSString* identifier = info[(__bridge NSString*)kSecCodeInfoIdentifier];
  NSCharacterSet* invalid = [[NSCharacterSet characterSetWithCharactersInString:
      @"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"] invertedSet];
  if (![identifier isEqualToString:kBrowserID] || team.length != 10 ||
      [team rangeOfCharacterFromSet:invalid].location != NSNotFound)
    return nil;
  return team;
}
}  // namespace

@interface WMChromiumWorkspaceBridge : NSObject
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSXPCConnection* connection;
@property(nonatomic, copy) NSString* reportPath;
@property(nonatomic, copy) NSString* team;
@property(nonatomic) BOOL finished;
- (void)startWithRegistration:(BOOL)registerHelper;
- (void)report:(NSString*)state detail:(NSString*)detail;
@end

@implementation WMChromiumWorkspaceBridge
@synthesize queue = _queue;
@synthesize connection = _connection;
@synthesize reportPath = _reportPath;
@synthesize team = _team;
@synthesize finished = _finished;

- (instancetype)init {
  self = [super init];
  if (self)
    _queue = dispatch_queue_create("com.jameslyons.winmux.browser.bridge", DISPATCH_QUEUE_SERIAL);
  return self;
}

- (void)report:(NSString*)state detail:(NSString*)detail {
  // Diagnostic disk work stays on this background queue, away from focus/UI.
  NSLog(@"WinMux workspace bridge: %@ (%@)", state, detail);
  if (!self.reportPath.length)
    return;
  NSDictionary* report = @{
    @"scope": @"chromium_signed_xpc_transport_only",
    @"state": state,
    @"detail": detail,
    @"team_identifier": self.team ?: @"",
    @"browser_identifier": kBrowserID,
    @"presentation_measured": @NO,
    @"native_window_management_enabled": @NO,
  };
  NSError* error = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
  if (data && ![data writeToFile:self.reportPath options:NSDataWritingAtomic error:&error])
    NSLog(@"WinMux bridge diagnostic write failed: %@", error.localizedDescription);
}

- (void)startWithRegistration:(BOOL)registerHelper {
  dispatch_async(self.queue, ^{
    self.team = OwnTeam();
    if (!self.team) {
      [self report:@"invalid_browser_identity" detail:@"Apple team and exact alpha identifier required"];
      return;
    }
    SMAppService* service = [SMAppService agentServiceWithPlistName:[kHelperID stringByAppendingString:@".plist"]];
    if (registerHelper && (service.status == SMAppServiceStatusNotRegistered ||
                           service.status == SMAppServiceStatusNotFound)) {
      NSError* error = nil;
      if (![service registerAndReturnError:&error]) {
        [self report:@"registration_failed" detail:[NSString stringWithFormat:@"%@ (%@ %ld)",
            error.localizedDescription ?: @"Unknown registration error", error.domain, (long)error.code]];
        return;
      }
    }
    if (service.status != SMAppServiceStatusEnabled) {
      [self report:service.status == SMAppServiceStatusRequiresApproval ? @"requires_approval" : @"helper_not_registered"
            detail:[NSString stringWithFormat:@"SMAppService status %ld", (long)service.status]];
      return;
    }
    self.connection = [[NSXPCConnection alloc] initWithMachServiceName:kHelperID options:0];
    self.connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(WMWorkspaceBridge)];
    [self.connection setCodeSigningRequirement:[NSString stringWithFormat:
        @"anchor apple generic and identifier \"%@\" and certificate leaf[subject.OU] = \"%@\"", kHelperID, self.team]];
    __weak WMChromiumWorkspaceBridge* weakSelf = self;
    self.connection.invalidationHandler = ^{
      WMChromiumWorkspaceBridge* bridge = weakSelf;
      if (!bridge) return;
      dispatch_async(bridge.queue, ^{
        bridge.finished = YES;
        bridge.connection = nil;
        [bridge report:@"disconnected" detail:@"Browser controls remain available"];
      });
    };
    self.connection.interruptionHandler = ^{
      WMChromiumWorkspaceBridge* bridge = weakSelf;
      if (!bridge) return;
      dispatch_async(bridge.queue, ^{
        bridge.finished = YES;
        [bridge report:@"interrupted" detail:@"Browser controls remain available"];
      });
    };
    [self.connection resume];
    id<WMWorkspaceBridge> remote = [self.connection remoteObjectProxyWithErrorHandler:^(NSError* error) {
      WMChromiumWorkspaceBridge* bridge = weakSelf;
      if (!bridge) return;
      dispatch_async(bridge.queue, ^{
        bridge.finished = YES;
        [bridge report:@"connection_rejected" detail:error.localizedDescription];
      });
    }];
    [remote negotiateVersion:1 reply:^(NSInteger version, NSString* epoch) {
      dispatch_async(self.queue, ^{
        if (self.finished) return;
        if (version != 1 || !epoch.length) {
          self.finished = YES;
          [self report:@"negotiation_failed" detail:@"Unsupported bridge version or missing epoch"];
          return;
        }
        [remote pingEpoch:epoch sequence:1 reply:^(BOOL accepted, uint64_t sequence) {
          dispatch_async(self.queue, ^{
            if (self.finished) return;
            self.finished = YES;
            [self report:accepted && sequence == 1 ? @"authenticated" : @"probe_rejected"
                  detail:@"Chromium browser process and packaged Swift helper exchanged an asynchronous probe"];
          });
        }];
      });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), self.queue, ^{
      if (!self.finished) {
        self.finished = YES;
        [self report:@"timeout" detail:@"Helper did not reply within 15 seconds"];
        self.connection.invalidationHandler = nil;
        [self.connection invalidate];
        self.connection = nil;
      }
    });
  });
}
@end

namespace winmux {
void StartWorkspaceBridge() {
  // Raw control bundles never enroll or contact the alpha helper.
  if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:kBrowserID])
    return;
  static WMChromiumWorkspaceBridge* bridge = nil;
  if (bridge)
    return;
  bridge = [[WMChromiumWorkspaceBridge alloc] init];
  const auto* command = base::CommandLine::ForCurrentProcess();
  bridge.reportPath = base::SysUTF8ToNSString(command->GetSwitchValueNative("winmux-bridge-report"));
  [bridge startWithRegistration:command->HasSwitch("winmux-register-helper")];
}
}  // namespace winmux
