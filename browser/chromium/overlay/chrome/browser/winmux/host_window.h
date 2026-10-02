#ifndef CHROME_BROWSER_WINMUX_HOST_WINDOW_H_
#define CHROME_BROWSER_WINMUX_HOST_WINDOW_H_
#include <cstdint>
#include "ui/gfx/geometry/size.h"
namespace ui { class BaseWindow; }
namespace winmux {
uint32_t BrowserHostWindowID(ui::BaseWindow* window);
gfx::Size BrowserHostMinimumSize(ui::BaseWindow* window);
}
#endif
