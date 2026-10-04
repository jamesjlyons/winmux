#ifndef CHROME_BROWSER_WINMUX_HOST_WINDOW_H_
#define CHROME_BROWSER_WINMUX_HOST_WINDOW_H_
#include <cstdint>
#include <memory>
#include "base/functional/callback.h"
#include "ui/gfx/geometry/size.h"
class BrowserWindowInterface;
namespace ui { class BaseWindow; }
namespace winmux {
uint32_t BrowserHostWindowID(ui::BaseWindow* window);
gfx::Size BrowserHostMinimumSize(ui::BaseWindow* window);
gfx::Size BrowserManagedHostMinimumSize();
bool SetBrowserHostManaged(BrowserWindowInterface* browser, bool managed);
bool IsBrowserHostManaged(BrowserWindowInterface* browser);
bool IsBrowserHostMinimized(BrowserWindowInterface* browser);
bool IsBrowserHostFullscreen(BrowserWindowInterface* browser);
bool IsBrowserHostZoomed(BrowserWindowInterface* browser);
bool IsBrowserHostSuspended(BrowserWindowInterface* browser);
void MinimizeBrowserHost(BrowserWindowInterface* browser);
void RestoreMinimizedBrowserHost(BrowserWindowInterface* browser);
void ToggleBrowserHostFullscreen(BrowserWindowInterface* browser);
void ZoomBrowserHost(BrowserWindowInterface* browser);
class BrowserHostWindowObserver {
 public:
  virtual ~BrowserHostWindowObserver() = default;
};
std::unique_ptr<BrowserHostWindowObserver> ObserveBrowserHostWindow(
    BrowserWindowInterface* browser, base::RepeatingClosure changed);
}
#endif
