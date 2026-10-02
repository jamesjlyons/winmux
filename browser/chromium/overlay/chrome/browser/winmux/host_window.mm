#include "chrome/browser/winmux/host_window.h"
#include <algorithm>
#include <cmath>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "ui/base/base_window.h"
#include "ui/gfx/native_ui_types.h"

namespace winmux {
namespace {
char kSavedWindowPresentation;
}

gfx::Size BrowserManagedHostMinimumSize() {
  // Must match BrowserView::GetMinimumSize() in the managed-page patch.
  return gfx::Size(160, 120);
}

bool IsBrowserHostManaged(BrowserWindowInterface* browser) {
  auto* view = browser ? BrowserView::GetBrowserViewForBrowser(browser) : nullptr;
  return view && view->IsWinmuxManaged();
}

bool SetBrowserHostManaged(BrowserWindowInterface* browser, bool managed) {
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
      @"movable": @(native.movable),
      @"movable_by_background": @(native.movableByWindowBackground),
    };
    objc_setAssociatedObject(native, &kSavedWindowPresentation, saved,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [native standardWindowButton:NSWindowCloseButton].hidden = YES;
    [native standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
    [native standardWindowButton:NSWindowZoomButton].hidden = YES;
    native.titleVisibility = NSWindowTitleHidden;
    native.titlebarAppearsTransparent = YES;
    // The content window and Swift chrome form one managed surface. Letting
    // AppKit drag the content alone separates it from its header and backing.
    // Winmux owns surface movement through the authenticated layout channel.
    native.movable = NO;
    native.movableByWindowBackground = NO;
  } else {
    NSDictionary* saved = objc_getAssociatedObject(native, &kSavedWindowPresentation);
    if (saved) {
      [native standardWindowButton:NSWindowCloseButton].hidden = [saved[@"close"] boolValue];
      [native standardWindowButton:NSWindowMiniaturizeButton].hidden = [saved[@"minimize"] boolValue];
      [native standardWindowButton:NSWindowZoomButton].hidden = [saved[@"zoom"] boolValue];
      native.titleVisibility = static_cast<NSWindowTitleVisibility>([saved[@"title"] integerValue]);
      native.titlebarAppearsTransparent = [saved[@"transparent"] boolValue];
      native.movable = [saved[@"movable"] boolValue];
      native.movableByWindowBackground = [saved[@"movable_by_background"] boolValue];
      objc_setAssociatedObject(native, &kSavedWindowPresentation, nil,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  }
  view->SetWinmuxManaged(managed);
  return true;
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
