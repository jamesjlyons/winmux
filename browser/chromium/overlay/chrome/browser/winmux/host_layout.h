#ifndef CHROME_BROWSER_WINMUX_HOST_LAYOUT_H_
#define CHROME_BROWSER_WINMUX_HOST_LAYOUT_H_
#include <string>
class BrowserWindowInterface;
namespace winmux {
std::string ApplyHostLayout(const std::string& json);
void ReleaseHostLayout();
void ReconcileBrowserHostPages(BrowserWindowInterface* browser);
}
#endif
