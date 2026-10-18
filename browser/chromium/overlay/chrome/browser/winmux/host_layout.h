#ifndef CHROME_BROWSER_WINMUX_HOST_LAYOUT_H_
#define CHROME_BROWSER_WINMUX_HOST_LAYOUT_H_
#include <cstddef>
#include <string>
class BrowserWindowInterface;
namespace winmux {
// A layout request places every browser page across all Spaces, so it must
// admit as many pages as inventory does. Keep these in step with the helper.
inline constexpr size_t kMaximumHostLayoutPages = 10000;
inline constexpr size_t kMaximumHostLayoutBytes = 8 * 1024 * 1024;
std::string ApplyHostLayout(const std::string& json);
void ReleaseHostLayout();
void ReconcileBrowserHostPages(BrowserWindowInterface* browser);
}
#endif
