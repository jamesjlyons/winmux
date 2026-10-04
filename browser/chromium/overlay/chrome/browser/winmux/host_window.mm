#include "chrome/browser/winmux/host_window.h"
#include <algorithm>
#include <cmath>
#include <utility>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "ui/base/base_window.h"
#include "ui/gfx/native_ui_types.h"

namespace winmux {
namespace {
char kSavedWindowPresentation;
char kRestoreManagedAfterFullscreen;
char kFullscreenTransition;
char kMinimizeTransition;
char kRestoreAfterMinimize;
char kOwnedZoom;
char kRestoreManagedAfterZoom;
char kZoomTransition;
char kHostStateChanged;

NSWindow* NativeWindow(BrowserWindowInterface* browser) {
  return browser ? browser->GetWindow()->GetNativeWindow().GetNativeNSWindow() : nil;
}

bool SetHostPresentation(BrowserWindowInterface* browser, bool managed) {
  auto* view = browser ? BrowserView::GetBrowserViewForBrowser(browser) : nullptr;
  NSWindow* native = browser
      ? browser->GetWindow()->GetNativeWindow().GetNativeNSWindow() : nil;
  if (!view || !native) return false;
  if (view->IsWinmuxManaged() == managed) return true;
  // Save per native window, not globally: release restores its own presentation.
  if (managed) {
    NSDictionary* saved = @{
      @"close": @([native standardWindowButton:NSWindowCloseButton].hidden),
      @"minimize": @([native standardWindowButton:NSWindowMiniaturizeButton].hidden),
      @"zoom": @([native standardWindowButton:NSWindowZoomButton].hidden),
      @"title": @(native.titleVisibility),
      @"transparent": @(native.titlebarAppearsTransparent),
      @"shadow": @(native.hasShadow),
      @"movable": @(native.movable),
      @"movable_by_background": @(native.movableByWindowBackground),
      @"animation_behavior": @(native.animationBehavior),
    };
    objc_setAssociatedObject(native, &kSavedWindowPresentation, saved,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [native standardWindowButton:NSWindowCloseButton].hidden = YES;
    [native standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [native standardWindowButton:NSWindowZoomButton].hidden = YES;
    native.titleVisibility = NSWindowTitleHidden;
    native.titlebarAppearsTransparent = YES;
    // Tiled pages use the Swift shell edge rather than a WindowServer shadow.
    native.hasShadow = NO;
    // The content window and Swift chrome form one managed surface. Letting
    // AppKit drag the content alone separates it from its header and backing.
    // Winmux owns surface movement through the authenticated layout channel.
    native.movable = NO;
    native.movableByWindowBackground = NO;
    // Cocoa's document-window ordering animation scales and bounces every page
    // during a group switch, including its disappearance. The workspace owns
    // visibility: present the existing frame immediately and without movement.
    native.animationBehavior = NSWindowAnimationBehaviorNone;
  } else {
    NSDictionary* saved = objc_getAssociatedObject(native, &kSavedWindowPresentation);
    if (saved) {
      [native standardWindowButton:NSWindowCloseButton].hidden = [saved[@"close"] boolValue];
      [native standardWindowButton:NSWindowMiniaturizeButton].hidden = [saved[@"minimize"] boolValue];
      [native standardWindowButton:NSWindowZoomButton].hidden = [saved[@"zoom"] boolValue];
      native.titleVisibility = static_cast<NSWindowTitleVisibility>([saved[@"title"] integerValue]);
      native.titlebarAppearsTransparent = [saved[@"transparent"] boolValue];
      native.hasShadow = [saved[@"shadow"] boolValue];
      native.movable = [saved[@"movable"] boolValue];
      native.movableByWindowBackground = [saved[@"movable_by_background"] boolValue];
      native.animationBehavior = static_cast<NSWindowAnimationBehavior>(
          [saved[@"animation_behavior"] integerValue]);
      objc_setAssociatedObject(native, &kSavedWindowPresentation, nil,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  }
  view->SetWinmuxManaged(managed);
  return true;
}

void PublishHostStateChanged(NSWindow* native) {
  void (^changed)(void) = objc_getAssociatedObject(native, &kHostStateChanged);
  if (changed) changed();
}

void ReconcileZoomPresentation(BrowserWindowInterface* browser);

void WatchFullscreenTransition(base::WeakPtr<BrowserWindowInterface> browser) {
  if (!browser || browser->IsDeleteScheduled()) return;
  NSWindow* native = NativeWindow(browser.get());
  if (![objc_getAssociatedObject(native, &kFullscreenTransition) boolValue]) return;
  // Cocoa can fail to enter fullscreen without its usual DidExit notification.
  // Chromium clears its target state on that path. Only recover when neither
  // Chromium nor the native window still expects/presents fullscreen.
  if (!browser->GetWindow()->IsFullscreen() &&
      !(native.styleMask & NSWindowStyleMaskFullScreen)) {
    const bool restore = [objc_getAssociatedObject(
        native, &kRestoreManagedAfterFullscreen) boolValue];
    objc_setAssociatedObject(native, &kFullscreenTransition, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(native, &kRestoreManagedAfterFullscreen, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (restore && !IsBrowserHostZoomed(browser.get()))
      SetHostPresentation(browser.get(), true);
    ReconcileZoomPresentation(browser.get());
    PublishHostStateChanged(native);
    return;
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&WatchFullscreenTransition, browser),
      base::Milliseconds(250));
}

void BeginFullscreenTransition(BrowserWindowInterface* browser) {
  NSWindow* native = NativeWindow(browser);
  if ([objc_getAssociatedObject(native, &kFullscreenTransition) boolValue]) return;
  objc_setAssociatedObject(native, &kFullscreenTransition, @YES,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&WatchFullscreenTransition, browser->GetWeakPtr()),
      base::Milliseconds(250));
}

void PrepareForFullscreen(BrowserWindowInterface* browser) {
  NSWindow* native = NativeWindow(browser);
  const bool managed = IsBrowserHostManaged(browser);
  SetHostPresentation(browser, false);
  objc_setAssociatedObject(native, &kRestoreManagedAfterFullscreen,
                           managed ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  BeginFullscreenTransition(browser);
}

void ReconcileZoomPresentation(BrowserWindowInterface* browser) {
  NSWindow* native = NativeWindow(browser);
  if (!IsBrowserHostZoomed(browser) || IsBrowserHostFullscreen(browser) ||
      [objc_getAssociatedObject(native, &kZoomTransition) boolValue] || native.zoomed)
    return;
  const bool restore = [objc_getAssociatedObject(native, &kRestoreManagedAfterZoom) boolValue];
  objc_setAssociatedObject(native, &kOwnedZoom, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(native, &kRestoreManagedAfterZoom, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (restore) SetHostPresentation(browser, true);
}

class CocoaBrowserHostWindowObserver final : public BrowserHostWindowObserver {
 public:
  CocoaBrowserHostWindowObserver(BrowserWindowInterface* browser,
                                base::RepeatingClosure changed) {
    NSWindow* native = NativeWindow(browser);
    native_ = native;
    objc_setAssociatedObject(native, &kHostStateChanged, [^{ changed.Run(); } copy],
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    auto host = browser->GetWeakPtr();
    observers_ = [NSMutableArray array];
    for (NSNotificationName name in @[
        NSWindowWillMiniaturizeNotification, NSWindowDidMiniaturizeNotification,
        NSWindowDidDeminiaturizeNotification, NSWindowWillEnterFullScreenNotification,
        NSWindowDidEnterFullScreenNotification, NSWindowWillExitFullScreenNotification,
        NSWindowDidExitFullScreenNotification, NSWindowDidResizeNotification]) {
      id observer = [NSNotificationCenter.defaultCenter
          addObserverForName:name object:native queue:nil
          usingBlock:^(NSNotification* notification) {
            if (!host || host->IsDeleteScheduled()) return;
            NSWindow* window = NativeWindow(host.get());
            if ([notification.name isEqualToString:NSWindowWillMiniaturizeNotification]) {
              objc_setAssociatedObject(window, &kMinimizeTransition, @YES,
                                       OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else if ([notification.name isEqualToString:NSWindowDidMiniaturizeNotification]) {
              objc_setAssociatedObject(window, &kMinimizeTransition, nil,
                                       OBJC_ASSOCIATION_RETAIN_NONATOMIC);
              const bool restore = [objc_getAssociatedObject(window, &kRestoreAfterMinimize) boolValue];
              objc_setAssociatedObject(window, &kRestoreAfterMinimize, nil,
                                       OBJC_ASSOCIATION_RETAIN_NONATOMIC);
              if (restore) {
                [window deminiaturize:nil];
                [window makeKeyAndOrderFront:nil];
              }
            } else if ([notification.name isEqualToString:NSWindowDidDeminiaturizeNotification]) {
              objc_setAssociatedObject(window, &kMinimizeTransition, nil,
                                       OBJC_ASSOCIATION_RETAIN_NONATOMIC);
              objc_setAssociatedObject(window, &kRestoreAfterMinimize, nil,
                                       OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else if ([notification.name isEqualToString:NSWindowWillEnterFullScreenNotification]) {
              PrepareForFullscreen(host.get());
            } else if ([notification.name isEqualToString:NSWindowWillExitFullScreenNotification]) {
              BeginFullscreenTransition(host.get());
            } else if ([notification.name isEqualToString:NSWindowDidEnterFullScreenNotification]) {
              objc_setAssociatedObject(window, &kFullscreenTransition, nil,
                                       OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else if ([notification.name isEqualToString:NSWindowDidExitFullScreenNotification]) {
              const bool restore = [objc_getAssociatedObject(
                  window, &kRestoreManagedAfterFullscreen) boolValue];
              objc_setAssociatedObject(window, &kFullscreenTransition, nil,
                                       OBJC_ASSOCIATION_RETAIN_NONATOMIC);
              objc_setAssociatedObject(window, &kRestoreManagedAfterFullscreen, nil,
                                       OBJC_ASSOCIATION_RETAIN_NONATOMIC);
              if (restore && !IsBrowserHostZoomed(host.get()))
                SetHostPresentation(host.get(), true);
            }
            if (IsBrowserHostZoomed(host.get()) &&
                ([notification.name isEqualToString:NSWindowDidResizeNotification] ||
                 [notification.name isEqualToString:NSWindowDidExitFullScreenNotification])) {
              // AppKit may send a resize before performZoom finishes changing
              // its zoom flag. Reconcile after the native operation has unwound.
              // Ordinary tile resizes have no owned zoom to reconcile. Posting
              // another inventory callback for each can defeat burst coalescing.
              base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
                  FROM_HERE, base::BindOnce(
                      [](base::WeakPtr<BrowserWindowInterface> browser,
                         base::RepeatingClosure changed) {
                        if (!browser || browser->IsDeleteScheduled()) return;
                        ReconcileZoomPresentation(browser.get());
                        changed.Run();
                      }, host, changed));
            }
            changed.Run();
          }];
      [observers_ addObject:observer];
    }
  }
  ~CocoaBrowserHostWindowObserver() override {
    for (id observer in observers_)
      [NSNotificationCenter.defaultCenter removeObserver:observer];
    objc_setAssociatedObject(native_, &kHostStateChanged, nil,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
  }

 private:
  NSMutableArray* __strong observers_;
  NSWindow* __weak native_ = nil;
};
}  // namespace

gfx::Size BrowserManagedHostMinimumSize() {
  // Must match BrowserView::GetMinimumSize() in the managed-page patch.
  return gfx::Size(160, 120);
}

bool IsBrowserHostManaged(BrowserWindowInterface* browser) {
  auto* view = browser ? BrowserView::GetBrowserViewForBrowser(browser) : nullptr;
  return (view && view->IsWinmuxManaged()) ||
      [objc_getAssociatedObject(NativeWindow(browser), &kRestoreManagedAfterFullscreen) boolValue] ||
      [objc_getAssociatedObject(NativeWindow(browser), &kRestoreManagedAfterZoom) boolValue];
}

bool IsBrowserHostMinimized(BrowserWindowInterface* browser) {
  NSWindow* native = NativeWindow(browser);
  if (!native) return browser && browser->GetWindow()->IsMinimized();
  return native.miniaturized ||
      [objc_getAssociatedObject(native, &kMinimizeTransition) boolValue];
}

bool IsBrowserHostFullscreen(BrowserWindowInterface* browser) {
  NSWindow* native = NativeWindow(browser);
  if (!native) return browser && browser->GetWindow()->IsFullscreen();
  return (native.styleMask & NSWindowStyleMaskFullScreen) ||
      [objc_getAssociatedObject(native, &kFullscreenTransition) boolValue];
}

bool IsBrowserHostSuspended(BrowserWindowInterface* browser) {
  return IsBrowserHostMinimized(browser) || IsBrowserHostFullscreen(browser) ||
      IsBrowserHostZoomed(browser);
}

bool IsBrowserHostZoomed(BrowserWindowInterface* browser) {
  // Only a workspace-owned zoom suspends tiling. Other conventional browser
  // windows can happen to match AppKit's standard frame without being adopted.
  return [objc_getAssociatedObject(NativeWindow(browser), &kOwnedZoom) boolValue];
}

bool SetBrowserHostManaged(BrowserWindowInterface* browser, bool managed) {
  NSWindow* native = NativeWindow(browser);
  if (!native) return false;
  // The page retains its workspace identity while native fullscreen owns its
  // presentation. Chromium controls provide the native way to leave that Space.
  const bool fullscreen = IsBrowserHostFullscreen(browser);
  const bool zoomed = IsBrowserHostZoomed(browser);
  objc_setAssociatedObject(native, &kRestoreManagedAfterFullscreen,
                           managed && fullscreen ? @YES : nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(native, &kRestoreManagedAfterZoom,
                           managed && zoomed ? @YES : nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  return SetHostPresentation(browser, managed && !fullscreen && !zoomed);
}

void MinimizeBrowserHost(BrowserWindowInterface* browser) {
  browser->GetWindow()->Minimize();
}

void RestoreMinimizedBrowserHost(BrowserWindowInterface* browser) {
  NSWindow* native = NativeWindow(browser);
  if ([objc_getAssociatedObject(native, &kMinimizeTransition) boolValue]) {
    // AppKit cannot reliably reverse the animation before DidMiniaturize.
    // Complete the requested focus as soon as the native minimize has finished.
    objc_setAssociatedObject(native, &kRestoreAfterMinimize, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return;
  }
  objc_setAssociatedObject(native, &kRestoreAfterMinimize, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [native deminiaturize:nil];
}

void ToggleBrowserHostFullscreen(BrowserWindowInterface* browser) {
  if (!IsBrowserHostFullscreen(browser)) PrepareForFullscreen(browser);
  // Chromium's controller drives NSWindow.toggleFullScreen and keeps browser
  // commands, native fullscreen animation and exit state synchronized.
  chrome::ToggleFullscreenMode(browser, /*user_initiated=*/true);
}

void ZoomBrowserHost(BrowserWindowInterface* browser) {
  NSWindow* native = NativeWindow(browser);
  // Restoring the toolbar can itself resize the window. Keep those synchronous
  // notifications from interpreting the presentation switch as a native unzoom.
  objc_setAssociatedObject(native, &kZoomTransition, @YES,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (!IsBrowserHostZoomed(browser)) {
    const bool managed = IsBrowserHostManaged(browser);
    objc_setAssociatedObject(native, &kOwnedZoom, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(native, &kRestoreManagedAfterZoom,
                             managed ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SetHostPresentation(browser, false);
  }
  [native performZoom:nil];
  objc_setAssociatedObject(native, &kZoomTransition, nil,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  ReconcileZoomPresentation(browser);
}

std::unique_ptr<BrowserHostWindowObserver> ObserveBrowserHostWindow(
    BrowserWindowInterface* browser, base::RepeatingClosure changed) {
  if (!NativeWindow(browser)) return nullptr;
  return std::make_unique<CocoaBrowserHostWindowObserver>(browser, std::move(changed));
}

gfx::Size BrowserHostMinimumSize(ui::BaseWindow* window) {
  NSWindow* native = window ? window->GetNativeWindow().GetNativeNSWindow() : nil;
  if (!native) return gfx::Size(1, 1);
  // Chromium's Cocoa bridge clamps SetBounds to this content minimum. Convert
  // to the same outer-frame coordinate system used by the workspace planner.
  NSRect frame = [native frameRectForContentRect:NSMakeRect(0, 0,
      native.contentMinSize.width, native.contentMinSize.height)];
  return gfx::Size(std::max(1, static_cast<int>(std::ceil(frame.size.width))),
                   std::max(1, static_cast<int>(std::ceil(frame.size.height))));
}
uint32_t BrowserHostWindowID(ui::BaseWindow* window) {
  NSWindow* native = window ? window->GetNativeWindow().GetNativeNSWindow() : nil;
  NSInteger number = native.windowNumber;
  return number > 0 && number <= UINT32_MAX ? static_cast<uint32_t>(number) : 0;
}
}
