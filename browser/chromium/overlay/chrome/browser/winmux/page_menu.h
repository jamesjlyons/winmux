#ifndef CHROME_BROWSER_WINMUX_PAGE_MENU_H_
#define CHROME_BROWSER_WINMUX_PAGE_MENU_H_

#include <memory>
#include "chrome/browser/winmux/managed_toolbar.h"

class BrowserWindowInterface;
namespace winmux {
std::unique_ptr<ManagedPageMenu> CreateManagedPageMenu(BrowserWindowInterface* browser);
}
#endif
