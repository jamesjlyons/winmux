#ifndef CHROME_BROWSER_WINMUX_HOST_LAYOUT_H_
#define CHROME_BROWSER_WINMUX_HOST_LAYOUT_H_
#include <string>
namespace winmux {
std::string ApplyHostLayout(const std::string& json);
void ReleaseHostLayout();
}
#endif
