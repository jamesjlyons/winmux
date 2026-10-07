#ifndef CHROME_BROWSER_WINMUX_MANAGED_TOOLBAR_H_
#define CHROME_BROWSER_WINMUX_MANAGED_TOOLBAR_H_

#include "ui/base/class_property.h"

namespace ui { class SimpleMenuModel; }

namespace winmux {
// Presentation capability negotiated for this native page host. It survives
// temporary fullscreen/zoom presentation and clears when management releases it.
extern const ui::ClassProperty<bool>* const kIntegratedToolbar;

// Browser UI consumes this interface without depending on the workspace bridge.
// The host owns the implementation and releases it with its managed presentation.
class ManagedPageMenu {
 public:
  enum Command { kKeepActive = 59001, kSiteBlocking, kPrivacySettings };
  virtual ~ManagedPageMenu() = default;
  virtual void Build(ui::SimpleMenuModel* menu) const = 0;
  virtual bool IsChecked(int command) const = 0;
  virtual bool IsEnabled(int command) const = 0;
  virtual void Execute(int command) = 0;
  static bool Handles(int command) {
    return command >= kKeepActive && command <= kPrivacySettings;
  }
};
extern const ui::ClassProperty<ManagedPageMenu*>* const kManagedPageMenu;
}  // namespace winmux

DECLARE_UI_CLASS_PROPERTY_TYPE(winmux::ManagedPageMenu*)

#endif
