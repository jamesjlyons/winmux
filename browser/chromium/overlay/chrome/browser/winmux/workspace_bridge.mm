#include "chrome/browser/winmux/workspace_bridge.h"
#include "chrome/browser/winmux/page_lifetime.h"
#include "chrome/browser/winmux/browser_inventory.h"
#include "chrome/browser/winmux/workspace_bridge_state.h"

#include <atomic>

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/uuid.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/ui/profiles/profile_picker.h"
#include "chrome/browser/ui/startup/startup_browser_creator.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#import "chrome/browser/winmux/WMBridgeProtocol.h"

namespace {
NSString* const kBrowserID = @"com.jameslyons.winmux.browser.alpha";
NSString* const kHelperID = @"com.jameslyons.winmux.browser.alpha.workspace";
bool setup_launch = false;

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
  std::atomic<uint64_t> _latestLayout;
  std::atomic<bool> _stopped;
}
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) NSXPCConnection* connection;
@property(nonatomic, copy) NSString* reportPath;
@property(nonatomic, copy) NSString* team;
@property(nonatomic) BOOL disconnectOnceForTesting;
@property(nonatomic) BOOL traceLayouts;
@property(nonatomic) BOOL dropLayoutReplyOnceForTesting;
@property(nonatomic) BOOL startupProfilePickerSuppressed;
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
- (void)openWorkspaceSetup:(id)sender;
- (void)installWorkspaceMenu;
@end

@implementation WMChromiumWorkspaceBridge
@synthesize queue = _queue;
@synthesize connection = _connection;
@synthesize reportPath = _reportPath;
@synthesize team = _team;
@synthesize disconnectOnceForTesting = _disconnectOnceForTesting;
@synthesize traceLayouts = _traceLayouts;
@synthesize dropLayoutReplyOnceForTesting = _dropLayoutReplyOnceForTesting;
@synthesize startupProfilePickerSuppressed = _startupProfilePickerSuppressed;
@synthesize serviceName = _serviceName;
@synthesize epoch = _epoch;
@synthesize protocolVersion = _protocolVersion;
@synthesize sequence = _sequence;

- (void)openWorkspaceSetup:(id)sender {
  NSURL* helper = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:
      @"Contents/Helpers/WinMux Workspace.app"];
  NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
  configuration.createsNewApplicationInstance = YES;
  configuration.arguments = setup_launch ? @[@"--workspace-setup", @"--open-workspace"] : @[@"--workspace-setup"];
  [NSWorkspace.sharedWorkspace openApplicationAtURL:helper configuration:configuration
      completionHandler:^(NSRunningApplication* app, NSError* error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (error) {
            NSAlert* alert = [[NSAlert alloc] init];
            alert.messageText = @"WinMux setup could not open";
            alert.informativeText = [@"Keep the WinMux app in Applications and try again. "
                stringByAppendingString:error.localizedDescription];
            [alert runModal];
          } else if (setup_launch) {
            // Only the empty launcher exits. A managed browser opened through
            // its setup menu must keep all its existing pages alive.
            [NSApp terminate:nil];
          }
        });
      }];
}

- (void)installWorkspaceMenu {
  if (_stopped.load()) return;
  NSMenu* menu = NSApp.mainMenu.itemArray.firstObject.submenu;
  if (!menu || [menu itemWithTitle:@"Workspace Setup…"]) return;
  NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"Workspace Setup…"
      action:@selector(openWorkspaceSetup:) keyEquivalent:@""];
  item.target = self;
  [menu insertItem:item atIndex:MIN(2, menu.numberOfItems)];
}

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
    @"inventory_enabled": @(self.protocolVersion >= 2),
    @"startup_profile_picker_suppressed": @(self.startupProfilePickerSuppressed),
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
  content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(&winmux::ReleaseBrowserLayout));
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
  [self negotiate:10 remote:remote generation:generation];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), self.queue, ^{
    if (self->_state.IsConnecting(generation))
      [self retryGeneration:generation state:@"timeout" detail:@"Helper did not reply within 15 seconds"];
  });
}

- (void)negotiate:(NSInteger)requested remote:(id<WMWorkspaceBridge>)remote generation:(uint64_t)generation {
  [remote negotiateVersion:requested reply:^(NSInteger version, NSString* epoch) {
    dispatch_async(self.queue, ^{
      if (self->_stopped.load() || !self->_state.IsConnecting(generation)) return;
      if (requested > version && version >= 1 && version <= 10 && !epoch.length) {
        [self negotiate:version remote:remote generation:generation];
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
          self->_latestLayout.store(0);
          self->_activeGeneration.store(generation);
          if (version >= 2) {
            content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(
                &winmux::BeginBrowserInventoryEpoch, base::SysNSStringToUTF8(epoch), version >= 7));
          }
          [self report:@"authenticated"
                detail:@"Chromium browser process and packaged Swift helper exchanged an asynchronous probe"];
          if (self.disconnectOnceForTesting) {
            self.disconnectOnceForTesting = NO;
            // Invalidate only this opt-in headless test client's connection.
            // The enrolled helper and other browser clients remain untouched.
            const int delay = [self.serviceName isEqualToString:kHelperID] ? 1 : 10;
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
    if (self->_stopped.load() || !self->_state.IsConnected(generation) || self.protocolVersion < 2 ||
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

- (void)openBrowserTabInWorkspaceProfile:(NSString*)key name:(NSString*)name url:(NSString*)url
                                 epoch:(NSString*)epoch operation:(NSString*)operation revision:(uint64_t)revision
                                 reply:(void (^)(NSString*, NSString*))reply {
  dispatch_async(self.queue, ^{
    const uint64_t generation = self->_state.generation();
    if (self->_stopped.load() || !self->_state.IsConnected(generation) || self.protocolVersion < 7 ||
        ![epoch isEqualToString:self.epoch]) { reply(@"stale_epoch", nil); return; }
    if (key.length > 36 || !key.length || !name.length || operation.length > 40 ||
        [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 128 ||
        (url && [url lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 16384)) {
      reply(@"invalid_request", nil); return;
    }
    winmux::BrowserSurfaceAction request{"open_tab", "workspace:" + base::SysNSStringToUTF8(key),
        base::SysNSStringToUTF8(operation), revision, 0,
        url ? std::make_optional(base::SysNSStringToUTF8(url)) : std::nullopt,
        base::SysNSStringToUTF8(name)};
    content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(
        [](WMChromiumWorkspaceBridge* bridge, uint64_t activeGeneration, std::string requestEpoch,
           winmux::BrowserSurfaceAction request, void (^completion)(NSString*, NSString*)) {
          if (bridge->_activeGeneration.load() != activeGeneration) { completion(@"stale_epoch", nil); return; }
          winmux::OpenBrowserTab(requestEpoch, std::move(request), base::BindOnce(
              [](void (^done)(NSString*, NSString*), std::string outcome, std::string surface) {
                done(base::SysUTF8ToNSString(outcome), surface.empty() ? nil : base::SysUTF8ToNSString(surface));
              }, [completion copy]));
        }, self, generation, base::SysNSStringToUTF8(epoch), std::move(request), [reply copy]));
  });
}

- (void)openBrowserTab:(NSString*)source profile:(NSString*)profile url:(NSString*)url
                  epoch:(NSString*)epoch operation:(NSString*)operation revision:(uint64_t)revision
                  reply:(void (^)(NSString*, NSString*))reply {
  dispatch_async(self.queue, ^{
    const uint64_t generation = self->_state.generation();
    if (self->_stopped.load() || !self->_state.IsConnected(generation) || self.protocolVersion < 5 ||
        ![epoch isEqualToString:self.epoch]) { reply(@"stale_epoch", nil); return; }
    if (source.length > 128 || profile.length > 40 || operation.length > 40 ||
        (source.length && profile.length && ![source.lowercaseString hasPrefix:
            [NSString stringWithFormat:@"browser:%@:", profile.lowercaseString]]) ||
        (url && [url lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 16384)) {
      reply(@"invalid_request", nil); return;
    }
    std::string context = source.length ? base::SysNSStringToUTF8(source) :
        profile.length ? "profile:" + base::SysNSStringToUTF8(profile) : std::string();
    winmux::BrowserSurfaceAction request{"open_tab", std::move(context), base::SysNSStringToUTF8(operation),
        revision, 0, url ? std::make_optional(base::SysNSStringToUTF8(url)) : std::nullopt};
    content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(
        [](WMChromiumWorkspaceBridge* bridge, uint64_t activeGeneration, std::string requestEpoch,
           winmux::BrowserSurfaceAction request, void (^completion)(NSString*, NSString*)) {
          if (bridge->_activeGeneration.load() != activeGeneration) { completion(@"stale_epoch", nil); return; }
          winmux::OpenBrowserTab(requestEpoch, std::move(request), base::BindOnce(
              [](void (^done)(NSString*, NSString*), std::string outcome, std::string surface) {
                done(base::SysUTF8ToNSString(outcome), surface.empty() ? nil : base::SysUTF8ToNSString(surface));
              }, [completion copy]));
        }, self, generation, base::SysNSStringToUTF8(epoch), std::move(request), [reply copy]));
  });
}

- (void)queryHistory:(NSString*)query surface:(NSString*)surface epoch:(NSString*)epoch
                reply:(void (^)(NSData*))reply {
  dispatch_async(self.queue, ^{
    const uint64_t generation = self->_activeGeneration.load();
    if (self.protocolVersion < 10 || !self.connection || self->_stopped.load() ||
        ![epoch isEqualToString:self.epoch] || query.length > 2048 || surface.length > 128) {
      reply(nil); return;
    }
    const bool posted = content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(
        [](WMChromiumWorkspaceBridge* bridge, uint64_t generation, std::string epoch,
           std::string surface, std::string query, void (^completion)(NSData*)) {
          if (bridge->_stopped.load() || generation != bridge->_activeGeneration.load()) { completion(nil); return; }
          winmux::QueryBrowserHistory(epoch, surface, query, base::BindOnce(
              [](WMChromiumWorkspaceBridge* bridge, uint64_t generation, void (^completion)(NSData*), std::string json) {
                if (bridge->_stopped.load() || generation != bridge->_activeGeneration.load()) { completion(nil); return; }
                completion([NSData dataWithBytes:json.data() length:json.size()]);
              }, bridge, generation, [completion copy]));
        }, self, generation, base::SysNSStringToUTF8(epoch), base::SysNSStringToUTF8(surface),
        base::SysNSStringToUTF8(query), [reply copy]));
    if (!posted) reply(nil);
  });
}

- (void)performAction:(NSString*)action surface:(NSString*)surface epoch:(NSString*)epoch
           operation:(NSString*)operation revision:(uint64_t)revision generation:(uint64_t)focusGeneration
               reply:(void (^)(NSString*))reply {
  if (![action isEqualToString:@"focus"] && ![action isEqualToString:@"close"] &&
      ![action isEqualToString:@"cancel_focus"]) { reply(@"unsupported"); return; }
  [self dispatchAction:action surface:surface url:nil epoch:epoch operation:operation
              revision:revision generation:focusGeneration minimumVersion:2 reply:reply];
}

- (void)performBrowserAction:(NSString*)action surface:(NSString*)surface url:(NSString*)url
                      epoch:(NSString*)epoch operation:(NSString*)operation revision:(uint64_t)revision
                 generation:(uint64_t)focusGeneration reply:(void (^)(NSString*))reply {
  [self dispatchAction:action surface:surface url:url epoch:epoch operation:operation
              revision:revision generation:focusGeneration minimumVersion:([@[@"downloads", @"extension_action", @"unpin_extension"] containsObject:action] ? 9 : [@[@"search", @"privacy", @"keep_active", @"site_blocking"] containsObject:action] ? 8 : 4) reply:reply];
}

- (void)dispatchAction:(NSString*)action surface:(NSString*)surface url:(NSString*)url
                 epoch:(NSString*)epoch operation:(NSString*)operation revision:(uint64_t)revision
            generation:(uint64_t)focusGeneration minimumVersion:(NSInteger)minimumVersion
                 reply:(void (^)(NSString*))reply {
  dispatch_async(self.queue, ^{
    const uint64_t generation = self->_state.generation();
    if (self->_stopped.load() || !self->_state.IsConnected(generation) || self.protocolVersion < minimumVersion ||
        ![epoch isEqualToString:self.epoch]) { reply(@"stale_epoch"); return; }
    if (action.length > 32 || surface.length > 128 || operation.length > 40 ||
        (url && [url lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 16384)) {
      reply(@"invalid_request"); return;
    }
    if ([action isEqualToString:@"focus"] || [action isEqualToString:@"cancel_focus"]) {
      if (!focusGeneration || focusGeneration < self->_latestFocus.load()) {
        reply(@"stale_focus"); return;
      }
      self->_latestFocus.store(focusGeneration);
    }
    winmux::BrowserSurfaceAction request{base::SysNSStringToUTF8(action), base::SysNSStringToUTF8(surface),
        base::SysNSStringToUTF8(operation), revision, focusGeneration,
        url ? std::make_optional(base::SysNSStringToUTF8(url)) : std::nullopt};
    content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(
        [](WMChromiumWorkspaceBridge* bridge, uint64_t activeGeneration, std::string requestEpoch,
           winmux::BrowserSurfaceAction request, void (^completion)(NSString*)) {
          if (bridge->_activeGeneration.load() != activeGeneration) { completion(@"stale_epoch"); return; }
          if (request.action == "focus" && request.generation < bridge->_latestFocus.load()) {
            completion(@"stale_focus"); return;
          }
          winmux::PerformBrowserSurfaceActionAsync(requestEpoch, std::move(request), base::BindOnce(
              [](void (^reply)(NSString*), std::string result) { reply(base::SysUTF8ToNSString(result)); }, [completion copy]));
        }, self, generation, base::SysNSStringToUTF8(epoch), std::move(request), [reply copy]));
  });
}

- (void)applyLayout:(NSData*)layout epoch:(NSString*)epoch operation:(NSString*)operation
           revision:(uint64_t)revision generation:(uint64_t)layoutGeneration reply:(void (^)(NSString*))reply {
  dispatch_async(self.queue, ^{
    const uint64_t generation = self->_state.generation();
    if (self.traceLayouts)
      NSLog(@"WinMux layout: received generation=%llu revision=%llu", layoutGeneration, revision);
    if (self->_stopped.load() || !self->_state.IsConnected(generation) || self.protocolVersion < 3 ||
        ![epoch isEqualToString:self.epoch]) { reply(@"stale_epoch"); return; }
    if (layout.length > 262144 || operation.length > 40) { reply(@"invalid_request"); return; }
    if (!layoutGeneration || layoutGeneration < self->_latestLayout.load()) { reply(@"stale_layout"); return; }
    self->_latestLayout.store(layoutGeneration);
    std::string json(static_cast<const char*>(layout.bytes), layout.length);
    const bool posted = content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(
        [](WMChromiumWorkspaceBridge* bridge, uint64_t activeGeneration, std::string epoch,
           std::string operation, uint64_t revision, uint64_t layoutGeneration, std::string json,
           void (^completion)(NSString*)) {
          if (bridge.traceLayouts)
            NSLog(@"WinMux layout: ui_begin generation=%llu", layoutGeneration);
          if (bridge->_activeGeneration.load() != activeGeneration) { completion(@"stale_epoch"); return; }
          if (layoutGeneration < bridge->_latestLayout.load()) { completion(@"stale_layout"); return; }
          NSString* outcome = base::SysUTF8ToNSString(
              winmux::PerformBrowserLayout(epoch, operation, revision, layoutGeneration, json));
          if (bridge.traceLayouts)
            NSLog(@"WinMux layout: ui_end generation=%llu outcome=%@", layoutGeneration, outcome);
          if (bridge.dropLayoutReplyOnceForTesting && [outcome isEqualToString:@"issued"]) {
            bridge.dropLayoutReplyOnceForTesting = NO;
            NSLog(@"WinMux layout: test_dropped_reply generation=%llu", layoutGeneration);
            return;
          }
          completion(outcome);
        }, self, generation, base::SysNSStringToUTF8(epoch), base::SysNSStringToUTF8(operation), revision,
        layoutGeneration, std::move(json), [reply copy]));
    if (!posted) reply(@"unavailable");
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
void PrepareWorkspaceLaunch() {
  auto* command = base::CommandLine::ForCurrentProcess();
  setup_launch = [NSBundle.mainBundle.bundleIdentifier isEqualToString:kBrowserID] &&
      ([[NSBundle.mainBundle objectForInfoDictionaryKey:@"WinMuxWorkspaceViews"] boolValue] || [[NSBundle.mainBundle objectForInfoDictionaryKey:@"WinMuxWorkspaceViewsTrial"] boolValue]) &&
      !command->HasSwitch("user-data-dir") && !command->HasSwitch("headless") &&
      !command->HasSwitch("winmux-managed-workspace") &&
      !command->HasSwitch("winmux-register-helper") &&
      !command->HasSwitch("winmux-test-service");
  if (setup_launch) {
    command->AppendSwitchASCII("profile-directory", "Default");
    command->AppendSwitch("no-startup-window");
    command->AppendSwitch("no-first-run");
    command->AppendSwitch("no-default-browser-check");
  }
}
void StartWorkspaceBridge() {
  // Raw control bundles never enroll or contact the alpha helper.
  if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:kBrowserID])
    return;
  if (bridge)
    return;
  // macOS Dock/reopen callbacks consult GetStartupMode directly and ignore
  // --profile-directory. Space profiles replace this automatic chooser for
  // the trial, including existing multi-profile installations. Explicit
  // profile management and policy/locked-profile handling remain Chromium's.
  if (([[NSBundle.mainBundle objectForInfoDictionaryKey:@"WinMuxWorkspaceViews"] boolValue] || [[NSBundle.mainBundle objectForInfoDictionaryKey:@"WinMuxWorkspaceViewsTrial"] boolValue])) {
    g_browser_process->local_state()->SetBoolean(prefs::kBrowserShowProfilePickerOnStartup, false);
  }
  bridge = [[WMChromiumWorkspaceBridge alloc] init];
  bridge.startupProfilePickerSuppressed = ProfilePicker::GetStartupMode() != StartupProfileMode::kProfilePicker;
  if (setup_launch) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [bridge installWorkspaceMenu];
      [bridge openWorkspaceSetup:nil];
    });
    return;  // Setup owns activation; the launcher never connects or enrolls.
  }
  const auto* command = base::CommandLine::ForCurrentProcess();
  bridge.reportPath = base::SysUTF8ToNSString(command->GetSwitchValueNative("winmux-bridge-report"));
  // Opt-in diagnostics record only protocol metadata, never page content.
  bridge.traceLayouts = command->HasSwitch("winmux-trace-layout");
  bridge.serviceName = kHelperID;
  if (command->HasSwitch("winmux-managed-workspace") && command->HasSwitch("user-data-dir"))
    bridge.serviceName = [kHelperID stringByAppendingString:@".managed"];
  if (!command->HasSwitch("headless")) {
    dispatch_async(dispatch_get_main_queue(), ^{ [bridge installWorkspaceMenu]; });
  }
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
  // Fault injection cannot affect an enrolled user workspace: it requires the
  // existing isolated service, dedicated profile and diagnostic report gates.
  bridge.dropLayoutReplyOnceForTesting = isolated_test &&
      command->HasSwitch("winmux-test-drop-layout-reply-once");
  [bridge startWithRegistration:command->HasSwitch("winmux-register-helper")];
}
void StopWorkspaceBridge() {
  StopWorkspacePageLifetime();
  [bridge stop];
  StopBrowserInventory();
}
}  // namespace winmux
