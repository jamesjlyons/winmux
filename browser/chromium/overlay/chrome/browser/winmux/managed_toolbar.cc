#include "chrome/browser/winmux/managed_toolbar.h"

DEFINE_UI_CLASS_PROPERTY_TYPE(winmux::ManagedPageMenu*)
DEFINE_UI_CLASS_PROPERTY_TYPE(winmux::ManagedFullscreenObserver*)

namespace winmux {
DEFINE_UI_CLASS_PROPERTY_KEY(bool, kIntegratedToolbar, false)
DEFINE_UI_CLASS_PROPERTY_KEY(bool, kCompactToolbar, false)
DEFINE_UI_CLASS_PROPERTY_KEY(ManagedFullscreenObserver*, kManagedFullscreenObserver, nullptr)
DEFINE_OWNED_UI_CLASS_PROPERTY_KEY(ManagedPageMenu, kManagedPageMenu)
}  // namespace winmux
