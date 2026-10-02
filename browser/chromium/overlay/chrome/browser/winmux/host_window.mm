#include "chrome/browser/winmux/host_window.h"
#include <algorithm>
#include <cmath>
#import <AppKit/AppKit.h>
#include "ui/base/base_window.h"
#include "ui/gfx/native_ui_types.h"

namespace winmux {
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
