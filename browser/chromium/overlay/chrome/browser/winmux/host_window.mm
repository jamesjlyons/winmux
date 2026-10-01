#include "chrome/browser/winmux/host_window.h"
#import <AppKit/AppKit.h>
#include "ui/base/base_window.h"
#include "ui/gfx/native_ui_types.h"

namespace winmux {
uint32_t BrowserHostWindowID(ui::BaseWindow* window) {
  NSWindow* native = window ? window->GetNativeWindow().GetNativeNSWindow() : nil;
  NSInteger number = native.windowNumber;
  return number > 0 && number <= UINT32_MAX ? static_cast<uint32_t>(number) : 0;
}
}
