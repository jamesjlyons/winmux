#ifndef CHROME_BROWSER_WINMUX_HOST_WINDOW_H_
#define CHROME_BROWSER_WINMUX_HOST_WINDOW_H_
#include <cstdint>
#include <memory>
#include "base/functional/callback.h"
#include "ui/gfx/geometry/size.h"
class BrowserWindowInterface;
namespace gfx { class Rect; }
namespace ui { class BaseWindow; }
namespace winmux {
uint32_t BrowserHostWindowID(ui::BaseWindow* window);
gfx::Size BrowserHostMinimumSize(ui::BaseWindow* window);
gfx::Size BrowserManagedHostMinimumSize();
bool SetBrowserHostManaged(BrowserWindowInterface* browser, bool managed, bool integrated_toolbar = false);
bool IsBrowserHostManaged(BrowserWindowInterface* browser);
bool IsBrowserHostMinimized(BrowserWindowInterface* browser);
bool IsBrowserHostFullscreen(BrowserWindowInterface* browser);
bool IsBrowserHostZoomed(BrowserWindowInterface* browser);
bool IsBrowserHostSuspended(BrowserWindowInterface* browser);
void MinimizeBrowserHost(BrowserWindowInterface* browser);
void RestoreMinimizedBrowserHost(BrowserWindowInterface* browser);
void ToggleBrowserHostFullscreen(BrowserWindowInterface* browser);
void ShowBrowserDownloads(BrowserWindowInterface* browser);
void ZoomBrowserHost(BrowserWindowInterface* browser);
// A layout glide resizes the host on every display frame. While it runs, the
// host's resize notifications do not publish inventory; ending it publishes once.
void SetBrowserHostGliding(BrowserWindowInterface* browser, bool gliding);
// Glides stay on one display; a move between displays is applied directly.
bool BrowserHostFramesShareDisplay(const gfx::Rect& from, const gfx::Rect& to);
// A held pointer may be dragging a host; a glide then finishes immediately.
bool IsPointerButtonHeld();
// Paces layout glides on the display's refresh. The tick runs on the UI thread.
void StartHostDisplayLink(base::RepeatingClosure tick);
void StopHostDisplayLink();
bool IsHostDisplayLinkRunning();
class BrowserHostWindowObserver {
 public:
  virtual ~BrowserHostWindowObserver() = default;
};
std::unique_ptr<BrowserHostWindowObserver> ObserveBrowserHostWindow(
    BrowserWindowInterface* browser, base::RepeatingClosure changed);
}
#endif
