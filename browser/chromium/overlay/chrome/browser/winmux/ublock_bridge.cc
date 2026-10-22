#include "chrome/browser/winmux/ublock_bridge.h"

#include <map>
#include "base/supports_user_data.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/winmux/browser_inventory.h"
#include "chrome/browser/winmux/privacy_settings.h"
#include "components/prefs/pref_service.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_function.h"
#include "extensions/browser/extension_function_registry.h"
#include "extensions/common/extension.h"

namespace winmux {
namespace {
const char kStateKey = 0;
struct PageState {
  GURL url;
  bool enabled = true;
  int blocked = 0;
};
struct State : base::SupportsUserData::Data {
  std::map<int, PageState> pages;
  std::map<int, base::DictValue> commands;
  int next_command = 0;
  base::TimeTicks updated;
};
State& GetState(Profile* profile) {
  auto* state = static_cast<State*>(profile->GetUserData(&kStateKey));
  if (!state) {
    auto owned = std::make_unique<State>();
    state = owned.get();
    profile->SetUserData(&kStateKey, std::move(owned));
  }
  return *state;
}

class ExchangeFunction final : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("winmuxBlocking.exchange", UNKNOWN)
 protected:
  ~ExchangeFunction() override = default;
  ResponseAction Run() override {
    // Feature metadata is supplemented with a native identity/location check.
    if (!extension() || extension()->id() != kUBlockId ||
        !extensions::Manifest::IsComponentLocation(extension()->location()))
      return RespondNow(Error("Unavailable"));
    if (args().size() != 1 || !args()[0].is_dict())
      return RespondNow(Error("Invalid state"));
    const auto& input = args()[0].GetDict();
    const auto* pages = input.FindList("pages");
    const auto* acknowledged = input.FindList("acknowledged");
    if (!pages || pages->size() > 1024 || !acknowledged || acknowledged->size() > 128)
      return RespondNow(Error("State exceeds bounds"));
    std::map<int, PageState> next;
    for (const auto& value : *pages) {
      if (!value.is_dict()) return RespondNow(Error("Invalid page"));
      const auto& page = value.GetDict();
      auto tab = page.FindInt("tabId");
      auto enabled = page.FindBool("enabled");
      auto blocked = page.FindInt("blocked");
      const auto* url = page.FindString("url");
      if (!tab || *tab < 0 || !enabled || !blocked || *blocked < 0 ||
          !url || url->size() > 65536 || !GURL(*url).SchemeIsHTTPOrHTTPS())
        return RespondNow(Error("Invalid page"));
      next.emplace(*tab, PageState{GURL(*url), *enabled, *blocked});
    }
    auto* profile = Profile::FromBrowserContext(browser_context());
    auto& state = GetState(profile);
    for (const auto& id : *acknowledged) {
      if (!id.is_int()) return RespondNow(Error("Invalid acknowledgement"));
    }
    for (const auto& id : *acknowledged) state.commands.erase(id.GetInt());
    // A changed blocked count is read live by the page menu and never
    // republishes inventory: that would rebuild every tab's record and cross
    // three processes for each batch of blocked requests on a busy page.
    bool changed = state.pages.size() != next.size();
    if (!changed) {
      for (const auto& [id, page] : next) {
        auto old = state.pages.find(id);
        if (old == state.pages.end() || old->second.url != page.url ||
            old->second.enabled != page.enabled) {
          changed = true;
          break;
        }
      }
    }
    state.pages = std::move(next);
    state.updated = base::TimeTicks::Now();
    base::DictValue reply;
    reply.Set("filterUpdates", WorkspacePrivacyState(profile).FindBool("filter_updates").value_or(false));
    reply.Set("legacyDisabledSites", profile->GetPrefs()->GetList("winmux.blocking_disabled_sites").Clone());
    base::ListValue commands;
    for (const auto& [id, command] : state.commands) commands.Append(command.Clone());
    reply.Set("commands", std::move(commands));
    if (changed) RefreshBrowserInventory();
    return RespondNow(WithArguments(std::move(reply)));
  }
};
}

void RegisterUBlockAPI() {
  static const bool registered = [] {
    ExtensionFunctionRegistry::GetInstance().RegisterFunction<ExchangeFunction>();
    return true;
  }();
  (void)registered;
}

bool UBlockSiteEnabled(Profile* profile, const GURL& site) {
  auto& state = GetState(profile);
  for (const auto& [id, page] : state.pages) {
    if (page.url == site) return page.enabled;
  }
  return true;
}

bool UBlockSiteEnabledForTab(content::WebContents* contents) {
  auto& state = GetState(Profile::FromBrowserContext(contents->GetBrowserContext()));
  const int tab = sessions::SessionTabHelper::IdForTab(contents).id();
  const auto found = state.pages.find(tab);
  if (found != state.pages.end() && found->second.url == contents->GetLastCommittedURL())
    return found->second.enabled;
  return UBlockSiteEnabled(Profile::FromBrowserContext(contents->GetBrowserContext()),
                           contents->GetLastCommittedURL());
}

void NotifyUBlockConfigurationChanged() {
  auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  if (!manager) return;
  for (Profile* profile : manager->GetLoadedProfiles()) {
    if (!profile || !profile->IsRegularProfile()) continue;
    auto* router = extensions::EventRouter::Get(profile);
    if (!router || !router->ExtensionHasEventListener(kUBlockId, "winmuxBlocking.onCommand")) continue;
    router->DispatchEventToExtension(kUBlockId, std::make_unique<extensions::Event>(
        extensions::events::UNKNOWN, "winmuxBlocking.onCommand", base::ListValue(), profile));
  }
}

int UBlockBlockedCount(content::WebContents* contents) {
  auto& state = GetState(Profile::FromBrowserContext(contents->GetBrowserContext()));
  const int tab = sessions::SessionTabHelper::IdForTab(contents).id();
  const auto found = state.pages.find(tab);
  return found != state.pages.end() && found->second.url == contents->GetLastCommittedURL()
      ? found->second.blocked : 0;
}

void SetUBlockSiteEnabled(content::WebContents* contents, bool enabled) {
  const GURL url = contents->GetLastCommittedURL();
  if (!url.SchemeIsHTTPOrHTTPS()) return;
  auto* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  auto& state = GetState(profile);
  // Bound outstanding user actions while the extension is starting/reloading.
  if (state.commands.size() >= 128) return;
  const int id = ++state.next_command;
  base::DictValue command;
  command.Set("id", id);
  command.Set("tabId", sessions::SessionTabHelper::IdForTab(contents).id());
  command.Set("url", url.spec());
  command.Set("enabled", enabled);
  state.commands.emplace(id, std::move(command));
  auto event = std::make_unique<extensions::Event>(extensions::events::UNKNOWN,
      "winmuxBlocking.onCommand", base::ListValue(), profile);
  extensions::EventRouter::Get(profile)->DispatchEventToExtension(kUBlockId, std::move(event));
}
}
