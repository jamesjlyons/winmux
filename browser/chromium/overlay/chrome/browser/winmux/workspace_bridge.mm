#include "chrome/browser/winmux/workspace_bridge.h"
#include "chrome/browser/winmux/browser_inventory.h"
#include "chrome/browser/winmux/workspace_bridge_state.h"

#include <atomic>

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/uuid.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
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

@interface WMChromiumWorkspaceBridge : NSObject <WMBrowserSurfaceOwner> {
  winmux::WorkspaceBridgeState _state;
  std::atomic<uint64_t> _activeGeneration;
  std::atomic<uint64_t> _latestFocus;
  std::atomic<bool> _stopped;
}
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSXPCConnection* connection;
@property(nonatomic, copy) NSString* reportPath;
@property(nonatomic, copy) NSString* team;
@property(nonatomic) BOOL disconnectOnceForTesting;
@property(nonatomic, copy) NSString* serviceName;
@property(nonatomic, copy) NSString* epoch;
@property(nonatomic) NSInteger protocolVersion;
@property(nonatomic) uint64_t sequence;
- (void)startWithRegistration:(BOOL)registerHelper;
- (void)connect;
- (void)stop;
- (void)negotiate:(NSInteger)requested remote:(id<WMWorkspaceBridge>)remote generation:(uint64_t)generation;
- (void)publish:(NSData*)data epoch:(NSString*)epoch;
- (void)retryGeneration:(uint64_t)generation state:(NSString*)state detail:(NSString*)detail;
- (void)report:(NSString*)state detail:(NSString*)detail;
@end

@implementation WMChromiumWorkspaceBridge
@synthesize queue = _queue;
@synthesize connection = _connection;
@synthesize reportPath = _reportPath;
@synthesize team = _team;
@synthesize disconnectOnceForTesting = _disconnectOnceForTesting;
@synthesize serviceName = _serviceName;
@synthesize epoch = _epoch;
@synthesize protocolVersion = _protocolVersion;
@synthesize sequence = _sequence;

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
    @"protocol_version": @(self.protocolVersion),
    @"inventory_enabled": @(self.protocolVersion == 2),
  };
  NSError* error = nil;
  NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
  if (data && ![data writeToFile:self.reportPath options:NSDataWritingAtomic error:&error])
    NSLog(@"WinMux bridge diagnostic write failed: %@", error.localizedDescription);
}

- (void)retryGeneration:(uint64_t)generation state:(NSString*)state detail:(NSString*)detail {
  if (_stopped.load()) return;
  auto delay = _state.Disconnect(generation);
  if (!delay)
    return;  // A stale callback or another error already scheduled this retry.
  _activeGeneration.store(0);
  self.epoch = nil;
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
  if (_stopped.load()) return;
  const uint64_t generation = _state.BeginAttempt();
  SMAppService* service = [SMAppService agentServiceWithPlistName:[kHelperID stringByAppendingString:@".plist"]];
  if ([self.serviceName isEqualToString:kHelperID] && service.status != SMAppServiceStatusEnabled) {
    [self retryGeneration:generation
          state:service.status == SMAppServiceStatusRequiresApproval ? @"requires_approval" : @"helper_not_registered"
          detail:[NSString stringWithFormat:@"SMAppService status %ld", (long)service.status]];
    return;
  }
  self.connection = [[NSXPCConnection alloc] initWithMachServiceName:self.serviceName options:0];
  self.connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(WMWorkspaceBridge)];
  self.connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(WMBrowserSurfaceOwner)];
  self.connection.exportedObject = self;
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
  [self negotiate:2 remote:remote generation:generation];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), self.queue, ^{
    if (self->_state.IsConnecting(generation))
      [self retryGeneration:generation state:@"timeout" detail:@"Helper did not reply within 15 seconds"];
  });
}

- (void)negotiate:(NSInteger)requested remote:(id<WMWorkspaceBridge>)remote generation:(uint64_t)generation {
  [remote negotiateVersion:requested reply:^(NSInteger version, NSString* epoch) {
    dispatch_async(self.queue, ^{
      if (self->_stopped.load() || !self->_state.IsConnecting(generation)) return;
      if (requested == 2 && version == 1 && !epoch.length) {
        [self negotiate:1 remote:remote generation:generation];
        return;
      }
      if (version != requested || !epoch.length) {
        [self retryGeneration:generation state:@"negotiation_failed" detail:@"Unsupported bridge version or missing epoch"];
        return;
      }
      [remote pingEpoch:epoch sequence:1 reply:^(BOOL accepted, uint64_t sequence) {
        dispatch_async(self.queue, ^{
          if (self->_stopped.load() || !self->_state.IsConnecting(generation)) return;
          if (!accepted || sequence != 1) {
            [self retryGeneration:generation state:@"probe_rejected" detail:@"Helper rejected the new connection's epoch probe"];
            return;
          }
          self->_state.Authenticate(generation);
          self.epoch = epoch;
          self.protocolVersion = version;
          self.sequence = 1;
          self->_latestFocus.store(0);
          self->_activeGeneration.store(generation);
          if (version == 2) {
            content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(
                &winmux::BeginBrowserInventoryEpoch, base::SysNSStringToUTF8(epoch)));
          }
          [self report:@"authenticated"
                detail:@"Chromium browser process and packaged Swift helper exchanged an asynchronous probe"];
          if (self.disconnectOnceForTesting) {
            self.disconnectOnceForTesting = NO;
            // Invalidate only this opt-in headless test client's connection.
            // The enrolled helper and other browser clients remain untouched.
            const int delay = [self.serviceName isEqualToString:kHelperID] ? 1 : 3;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), self.queue, ^{
              if (self->_state.generation() == generation)
                [self.connection invalidate];
            });
          }
        });
      }];
    });
  }];
}

- (void)publish:(NSData*)data epoch:(NSString*)epoch {
  dispatch_async(self.queue, ^{
    const uint64_t generation = self->_state.generation();
    if (self->_stopped.load() || !self->_state.IsConnected(generation) || self.protocolVersion != 2 ||
        ![epoch isEqualToString:self.epoch]) return;
    id<WMWorkspaceBridge> remote = [self.connection remoteObjectProxyWithErrorHandler:^(NSError*) {
      dispatch_async(self.queue, ^{
        [self retryGeneration:generation state:@"inventory_disconnected" detail:@"Inventory transport interrupted"];
      });
    }];
    [remote publishInventory:data epoch:epoch sequence:++self.sequence reply:^(BOOL accepted, uint64_t revision) {
      if (!accepted) {
        dispatch_async(self.queue, ^{
          [self retryGeneration:generation state:@"inventory_rejected" detail:@"Fresh inventory required"];
        });
      }
    }];
  });
}

- (void)performAction:(NSString*)action surface:(NSString*)surface epoch:(NSString*)epoch
           operation:(NSString*)operation revision:(uint64_t)revision generation:(uint64_t)focusGeneration
               reply:(void (^)(NSString*))reply {
  dispatch_async(self.queue, ^{
    const uint64_t generation = self->_state.generation();
    if (self->_stopped.load() || !self->_state.IsConnected(generation) || self.protocolVersion != 2 ||
        ![epoch isEqualToString:self.epoch]) { reply(@"stale_epoch"); return; }
    if (action.length > 16 || surface.length > 128 || operation.length > 40) {
      reply(@"invalid_request"); return;
    }
    if ([action isEqualToString:@"focus"] || [action isEqualToString:@"cancel_focus"]) {
      if (!focusGeneration || focusGeneration < self->_latestFocus.load()) {
        reply(@"stale_focus"); return;
      }
      self->_latestFocus.store(focusGeneration);
    }
    winmux::BrowserSurfaceAction request{base::SysNSStringToUTF8(action), base::SysNSStringToUTF8(surface),
        base::SysNSStringToUTF8(operation), revision, focusGeneration};
    content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(
        [](WMChromiumWorkspaceBridge* bridge, uint64_t activeGeneration, std::string requestEpoch,
           winmux::BrowserSurfaceAction request, void (^completion)(NSString*)) {
          if (bridge->_activeGeneration.load() != activeGeneration) { completion(@"stale_epoch"); return; }
          if (request.action == "focus" && request.generation < bridge->_latestFocus.load()) {
            completion(@"stale_focus"); return;
          }
          completion(base::SysUTF8ToNSString(winmux::PerformBrowserSurfaceAction(requestEpoch, std::move(request))));
        }, self, generation, base::SysNSStringToUTF8(epoch), std::move(request), [reply copy]));
  });
}

- (void)startWithRegistration:(BOOL)registerHelper {
  dispatch_async(self.queue, ^{
    if (self->_stopped.load()) return;
    self.team = OwnTeam();
    if (!self.team) {
      [self report:@"invalid_browser_identity" detail:@"Apple team and exact alpha identifier required"];
      return;
    }
    // Enrollment remains an explicit launch option, never a reconnect action.
    SMAppService* service = [SMAppService agentServiceWithPlistName:[kHelperID stringByAppendingString:@".plist"]];
    if (registerHelper && [self.serviceName isEqualToString:kHelperID] &&
        (service.status == SMAppServiceStatusNotRegistered ||
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

- (void)stop {
  // Cancel already queued UI actions before destroying their owner registry.
  _stopped.store(true);
  _activeGeneration.store(0);
  dispatch_async(self.queue, ^{
    self.epoch = nil;
    self.connection.invalidationHandler = nil;
    self.connection.interruptionHandler = nil;
    self.connection.exportedObject = nil;
    [self.connection invalidate];
    self.connection = nil;
  });
}
@end

namespace winmux {
namespace {
WMChromiumWorkspaceBridge* bridge = nil;
}
void StartWorkspaceBridge() {
  // Raw control bundles never enroll or contact the alpha helper.
  if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:kBrowserID])
    return;
  if (bridge)
    return;
  bridge = [[WMChromiumWorkspaceBridge alloc] init];
  const auto* command = base::CommandLine::ForCurrentProcess();
  bridge.reportPath = base::SysUTF8ToNSString(command->GetSwitchValueNative("winmux-bridge-report"));
  bridge.serviceName = kHelperID;
  bool isolated_test = false;
  auto service = command->GetSwitchValueASCII("winmux-test-service");
  const std::string prefix = base::SysNSStringToUTF8(kHelperID) + ".test.";
  if ((command->HasSwitch("headless") || command->HasSwitch("winmux-sidebar-preview")) &&
      command->HasSwitch("user-data-dir") && bridge.reportPath.length &&
      service.starts_with(prefix) &&
      base::Uuid::ParseCaseInsensitive(service.substr(prefix.size())).is_valid()) {
    bridge.serviceName = base::SysUTF8ToNSString(service);
    isolated_test = true;
  }
  StartBrowserInventory(base::BindRepeating([](WMChromiumWorkspaceBridge* owner,
      std::string epoch, std::string json) {
    [owner publish:[NSData dataWithBytes:json.data() length:json.size()]
              epoch:base::SysUTF8ToNSString(epoch)];
  }, bridge), isolated_test && command->HasSwitch("winmux-test-inventory-actions"));
  bridge.disconnectOnceForTesting = command->HasSwitch("headless") &&
      bridge.reportPath.length && command->HasSwitch("winmux-bridge-test-disconnect-once");
  [bridge startWithRegistration:command->HasSwitch("winmux-register-helper")];
}
void StopWorkspaceBridge() {
  [bridge stop];
  StopBrowserInventory();
}
}  // namespace winmux
