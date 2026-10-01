#ifndef CHROME_BROWSER_WINMUX_BROWSER_INVENTORY_H_
#define CHROME_BROWSER_WINMUX_BROWSER_INVENTORY_H_

#include <cstdint>
#include <string>
#include "base/functional/callback.h"

namespace winmux {
struct BrowserSurfaceAction {
  std::string action;
  std::string surface;
  std::string operation;
  uint64_t revision;
  uint64_t generation;
  bool operator==(const BrowserSurfaceAction&) const = default;
};

// All entry points run on Chromium's UI thread. The publisher only forwards
// immutable JSON to the asynchronous authenticated transport.
void StartBrowserInventory(base::RepeatingCallback<void(std::string, std::string)> publisher,
                           bool seed_isolated_test);
void BeginBrowserInventoryEpoch(std::string epoch);
void StopBrowserInventory();
std::string PerformBrowserLayout(const std::string& epoch, const std::string& operation,
                                 uint64_t revision, uint64_t generation, const std::string& json);
void ReleaseBrowserLayout();
std::string PerformBrowserSurfaceAction(const std::string& epoch,
                                        BrowserSurfaceAction request);
}  // namespace winmux
#endif
