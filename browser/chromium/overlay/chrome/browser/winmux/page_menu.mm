#include "chrome/browser/winmux/page_menu.h"

#import <AppKit/AppKit.h>
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "chrome/browser/winmux/browser_inventory.h"
#include "chrome/browser/winmux/page_lifetime.h"
#include "chrome/browser/winmux/privacy_settings.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/base_window.h"
#include "ui/menus/simple_menu_model.h"

namespace winmux {
namespace {
bool IsIntegrated(base::WeakPtr<BrowserWindowInterface> browser) {
  auto* view = browser && !browser->IsDeleteScheduled()
      ? BrowserView::GetBrowserViewForBrowser(browser.get()) : nullptr;
  return view && view->GetProperty(kIntegratedToolbar);
}

void ShowPrivacySettings(base::WeakPtr<BrowserWindowInterface> browser) {
  if (!IsIntegrated(browser)) return;
  NSWindow* native = browser->GetWindow()->GetNativeWindow().GetNativeNSWindow();
  if (!native || native.attachedSheet) return;
  const auto saved = WorkspacePrivacyState(browser->GetProfile());
  NSAlert* alert = [[NSAlert alloc] init];
  alert.messageText = @"Privacy Settings";
  alert.informativeText = @"Search and cookie preferences apply to this browser profile. Background service changes take effect after restarting the browser.";
  [alert addButtonWithTitle:@"Save"];
  [alert addButtonWithTitle:@"Cancel"];
  NSButton* security = [NSButton checkboxWithTitle:@"Allow security component updates" target:nil action:nil];
  NSButton* extensions = [NSButton checkboxWithTitle:@"Allow extension updates" target:nil action:nil];
  NSButton* filters = [NSButton checkboxWithTitle:@"Allow daily ad and tracker filter updates" target:nil action:nil];
  NSButton* cookies = [NSButton checkboxWithTitle:@"Block third-party cookies" target:nil action:nil];
  security.state = saved.FindBool("security_updates").value_or(false) ? NSControlStateValueOn : NSControlStateValueOff;
  extensions.state = saved.FindBool("extension_updates").value_or(false) ? NSControlStateValueOn : NSControlStateValueOff;
  filters.state = saved.FindBool("filter_updates").value_or(false) ? NSControlStateValueOn : NSControlStateValueOff;
  cookies.state = saved.FindBool("third_party_cookies_blocked").value_or(false) ? NSControlStateValueOn : NSControlStateValueOff;
  const auto* pattern = saved.FindString("search_template");
  NSTextField* search = [NSTextField textFieldWithString:pattern ? base::SysUTF8ToNSString(*pattern) : @""];
  search.accessibilityLabel = @"Search URL template";
  NSTextField* label = [NSTextField wrappingLabelWithString:@"Search URL — use {searchTerms} for your query"];
  NSTextField* exceptions = [NSTextField wrappingLabelWithString:@"Manage cookie exceptions in browser Settings → Privacy and security → Third-party cookies."];
  NSStackView* stack = [NSStackView stackViewWithViews:@[security, extensions, filters, cookies, label, search, exceptions]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 10;
  stack.frame = NSMakeRect(0, 0, 420, 240);
  [search.widthAnchor constraintEqualToConstant:420].active = YES;
  [exceptions.widthAnchor constraintEqualToConstant:420].active = YES;
  alert.accessoryView = stack;
  [alert beginSheetModalForWindow:native completionHandler:^(NSModalResponse response) {
    if (response != NSAlertFirstButtonReturn || !IsIntegrated(browser)) return;
    base::DictValue settings;
    settings.Set("security_updates", security.state == NSControlStateValueOn);
    settings.Set("extension_updates", extensions.state == NSControlStateValueOn);
    settings.Set("filter_updates", filters.state == NSControlStateValueOn);
    settings.Set("third_party_cookies_blocked", cookies.state == NSControlStateValueOn);
    settings.Set("search_template", base::SysNSStringToUTF8(search.stringValue));
    auto json = base::WriteJson(settings);
    if (!json) return;
    UpdateWorkspacePrivacy(browser->GetProfile(), *json, base::BindOnce(
        [](base::WeakPtr<BrowserWindowInterface> browser, std::string result) {
          RefreshBrowserInventory();
          if (result == "issued" || !IsIntegrated(browser)) return;
          NSWindow* window = browser->GetWindow()->GetNativeWindow().GetNativeNSWindow();
          if (!window || window.attachedSheet) return;
          NSAlert* failure = [[NSAlert alloc] init];
          failure.messageText = @"Settings could not be saved";
          failure.informativeText = @"Check the search URL and try again.";
          [failure beginSheetModalForWindow:window completionHandler:nil];
        }, browser));
  }];
}

class PageMenu final : public ManagedPageMenu {
 public:
  explicit PageMenu(BrowserWindowInterface* browser) : browser_(browser->GetWeakPtr()) {}
  void Build(ui::SimpleMenuModel* menu) const override {
    menu->AddCheckItem(kKeepActive, u"Keep Active");
    std::u16string label = u"Block Ads and Trackers on This Site";
    if (auto* contents = Contents(); contents && contents->GetLastCommittedURL().SchemeIsHTTPOrHTTPS()) {
      label += u" (" + base::NumberToString16(WorkspaceBlockedCount(contents)) + u" blocked)";
    }
    menu->AddCheckItem(kSiteBlocking, label);
    menu->AddItem(kPrivacySettings, u"Privacy Settings…");
    menu->AddSeparator(ui::NORMAL_SEPARATOR);
  }
  bool IsChecked(int command) const override {
    auto* contents = Contents();
    if (!contents) return false;
    if (command == kKeepActive) return WorkspacePageKeepActive(contents);
    return command == kSiteBlocking && contents->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() &&
        WorkspaceSiteBlockingEnabled(browser_->GetProfile(), contents->GetLastCommittedURL());
  }
  bool IsEnabled(int command) const override {
    auto* contents = Contents();
    return contents && (command != kSiteBlocking || contents->GetLastCommittedURL().SchemeIsHTTPOrHTTPS());
  }
  void Execute(int command) override {
    if (!IsEnabled(command)) return;
    auto* contents = Contents();
    if (command == kKeepActive) SetWorkspacePageKeepActive(contents, !IsChecked(command));
    else if (command == kSiteBlocking) SetWorkspaceSiteBlocking(contents, !IsChecked(command));
    else if (command == kPrivacySettings) ShowPrivacySettings(browser_);
    RefreshBrowserInventory();
  }
 private:
  content::WebContents* Contents() const {
    return IsIntegrated(browser_) ? browser_->GetTabStripModel()->GetActiveWebContents() : nullptr;
  }
  base::WeakPtr<BrowserWindowInterface> browser_;
};
}  // namespace

std::unique_ptr<ManagedPageMenu> CreateManagedPageMenu(BrowserWindowInterface* browser) {
  return std::make_unique<PageMenu>(browser);
}
}  // namespace winmux
