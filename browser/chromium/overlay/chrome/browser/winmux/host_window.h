#ifndef CHROME_BROWSER_WINMUX_HOST_WINDOW_H_
#define CHROME_BROWSER_WINMUX_HOST_WINDOW_H_
#include <cstdint>
namespace ui { class BaseWindow; }
namespace winmux {
uint32_t BrowserHostWindowID(ui::BaseWindow* window);
}
#endif
