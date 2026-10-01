#include "chrome/browser/winmux/workspace_bridge.h"
#include "chrome/browser/winmux/workspace_bridge_state.h"

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

@interface WMChromiumWorkspaceBridge : NSObject {
  winmux::WorkspaceBridgeState _state;
}
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSXPCConnection* connection;
@property(nonatomic, copy) NSString* reportPath;
@property(nonatomic, copy) NSString* team;
@property(nonatomic) BOOL disconnectOnceForTesting;
- (void)startWithRegistration:(BOOL)registerHelper;
- (void)connect;
- (void)retryGeneration:(uint64_t)generation state:(NSString*)state detail:(NSString*)detail;
- (void)report:(NSString*)state detail:(NSString*)detail;
@end

@implementation WMChromiumWorkspaceBridge
@synthesize queue = _queue;
@synthesize connection = _connection;
@synthesize reportPath = _reportPath;
@synthesize team = _team;
@synthesize disconnectOnceForTesting = _disconnectOnceForTesting;

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
    @"scope": @"chromium_signed_xpc_transport_with_recovery",
    @"state": state,
    @"detail": detail,
    @"team_identifier": self.team ?: @"",
    @"browser_identifier": kBrowserID,
    @"presentation_measured": @NO,
    @"native_window_management_enabled": @NO,
    @"connection_generation": @(_state.generation()),
    @"authenticated_connections": @(_state.authenticated_connections()),
  };
  NSError* error = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
  if (data && ![data writeToFile:self.reportPath options:NSDataWritingAtomic error:&error])
    NSLog(@"WinMux bridge diagnostic write failed: %@", error.localizedDescription);
}

- (void)retryGeneration:(uint64_t)generation state:(NSString*)state detail:(NSString*)detail {
  auto delay = _state.Disconnect(generation);
  if (!delay)
    return;  // A stale callback or another error already scheduled this retry.
  self.connection.invalidationHandler = nil;
  self.connection.interruptionHandler = nil;
  [self.connection invalidate];
  self.connection = nil;
  [self report:state detail:detail];
  __weak WMChromiumWorkspaceBridge* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, *delay * NSEC_PER_SEC), self.queue, ^{
    WMChromiumWorkspaceBridge* bridge = weakSelf;
    if (bridge && bridge->_state.CanRetry(generation))
      [bridge connect];
  });
}

- (void)connect {
  const uint64_t generation = _state.BeginAttempt();
  SMAppService* service = [SMAppService agentServiceWithPlistName:[kHelperID stringByAppendingString:@".plist"]];
  if (service.status != SMAppServiceStatusEnabled) {
    [self retryGeneration:generation
          state:service.status == SMAppServiceStatusRequiresApproval ? @"requires_approval" : @"helper_not_registered"
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
      [bridge retryGeneration:generation state:@"disconnected" detail:@"Browser controls remain available; reconnect scheduled"];
    });
  };
  self.connection.interruptionHandler = ^{
    WMChromiumWorkspaceBridge* bridge = weakSelf;
    if (!bridge) return;
    dispatch_async(bridge.queue, ^{
      [bridge retryGeneration:generation state:@"interrupted" detail:@"Browser controls remain available; reconnect scheduled"];
    });
  };
  [self.connection resume];
  id<WMWorkspaceBridge> remote = [self.connection remoteObjectProxyWithErrorHandler:^(NSError* error) {
    WMChromiumWorkspaceBridge* bridge = weakSelf;
    if (!bridge) return;
    dispatch_async(bridge.queue, ^{
      [bridge retryGeneration:generation state:@"connection_rejected" detail:error.localizedDescription];
    });
  }];
  [remote negotiateVersion:1 reply:^(NSInteger version, NSString* epoch) {
    dispatch_async(self.queue, ^{
      if (!self->_state.IsConnecting(generation)) return;
      if (version != 1 || !epoch.length) {
        [self retryGeneration:generation state:@"negotiation_failed" detail:@"Unsupported bridge version or missing epoch"];
        return;
      }
      [remote pingEpoch:epoch sequence:1 reply:^(BOOL accepted, uint64_t sequence) {
        dispatch_async(self.queue, ^{
          if (!self->_state.IsConnecting(generation)) return;
          if (!accepted || sequence != 1) {
            [self retryGeneration:generation state:@"probe_rejected" detail:@"Helper rejected the new connection's epoch probe"];
            return;
          }
          self->_state.Authenticate(generation);
          [self report:@"authenticated"
                detail:@"Chromium browser process and packaged Swift helper exchanged an asynchronous probe"];
          if (self.disconnectOnceForTesting) {
            self.disconnectOnceForTesting = NO;
            // Invalidate only this opt-in headless test client's connection.
            // The enrolled helper and other browser clients remain untouched.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self.queue, ^{
              if (self->_state.generation() == generation)
                [self.connection invalidate];
            });
          }
        });
      }];
    });
  }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), self.queue, ^{
    if (self->_state.IsConnecting(generation))
      [self retryGeneration:generation state:@"timeout" detail:@"Helper did not reply within 15 seconds"];
  });
}

- (void)startWithRegistration:(BOOL)registerHelper {
  dispatch_async(self.queue, ^{
    self.team = OwnTeam();
    if (!self.team) {
      [self report:@"invalid_browser_identity" detail:@"Apple team and exact alpha identifier required"];
      return;
    }
    // Enrollment remains an explicit launch option, never a reconnect action.
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
    [self connect];
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
  bridge.disconnectOnceForTesting = command->HasSwitch("headless") &&
      bridge.reportPath.length && command->HasSwitch("winmux-bridge-test-disconnect-once");
  [bridge startWithRegistration:command->HasSwitch("winmux-register-helper")];
}
}  // namespace winmux
