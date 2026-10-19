#ifndef CHROME_BROWSER_WINMUX_MANAGED_TOOLBAR_H_
#define CHROME_BROWSER_WINMUX_MANAGED_TOOLBAR_H_

#include "ui/base/class_property.h"
#include "ui/base/command_id_constants.h"

namespace ui { class SimpleMenuModel; }

namespace winmux {
// Presentation capability negotiated for this native page host. It survives
// temporary fullscreen/zoom presentation and clears when management releases it.
extern const ui::ClassProperty<bool>* const kIntegratedToolbar;

// Effective desktop density applied to the integrated toolbar's descendants.
// Touch UI keeps Chromium's larger controls.
extern const ui::ClassProperty<bool>* const kCompactToolbar;
inline constexpr int kCompactToolbarHeight = 34;
inline constexpr int kCompactLocationBarHeight = 26;
inline constexpr int kCompactToolbarButtonSize = 26;
inline constexpr int kCompactToolbarIconSize = 16;
inline constexpr int kCompactLocationBarRadius = 13;

// The host registers while it owns the page. BrowserView calls these around
// Chromium's fullscreen work so the host never restores chrome mid-reparenting.
class ManagedFullscreenObserver {
 public:
  virtual ~ManagedFullscreenObserver() = default;
  virtual void WillChange(bool fullscreen) = 0;
  virtual void DidChange() = 0;
};
extern const ui::ClassProperty<ManagedFullscreenObserver*>* const kManagedFullscreenObserver;

// Browser UI consumes this interface without depending on the workspace bridge.
// The host owns the implementation and releases it with its managed presentation.
class ManagedPageMenu {
 public:
  // Keep bounded page actions below Chromium's interleaved bookmark, recent-tab,
  // and tab-group IDs. AppMenu routes that range before consulting our model.
  enum Command { kKeepActive = 56001, kSiteBlocking, kUBlockSettings, kPrivacySettings };
  static_assert(kPrivacySettings < COMMAND_ID_FIRST_UNBOUNDED);
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
DECLARE_UI_CLASS_PROPERTY_TYPE(winmux::ManagedFullscreenObserver*)

#endif
