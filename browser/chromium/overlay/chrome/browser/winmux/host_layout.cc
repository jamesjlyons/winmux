#include "chrome/browser/winmux/host_layout.h"

#include <map>
#include <set>
#include <vector>
#include "base/json/json_reader.h"
#include "base/memory/weak_ptr.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/uuid.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/winmux/tab_identity.h"
#include "chrome/browser/winmux/host_window.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/rect.h"

namespace winmux {
namespace {
using Host = base::WeakPtr<BrowserWindowInterface>;
std::map<std::string, Host>& Hosts() {
  static base::NoDestructor<std::map<std::string, Host>> hosts;
  return *hosts;
}
struct Placement {
  std::string key;
  raw_ptr<Profile> profile = nullptr;
  std::vector<base::WeakPtr<content::WebContents>> tabs;
  std::string selected;
  gfx::Rect bounds;
  bool visible = false;
};
}

std::string ApplyHostLayout(const std::string& json) {
  auto value = base::JSONReader::Read(json, base::JSON_PARSE_RFC);
  if (!value || !value->is_list() || value->GetList().size() > 64) return "invalid_request";
  std::map<std::string, base::WeakPtr<content::WebContents>> live;
  GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* host) {
    if (host->GetType() != BrowserWindowInterface::TYPE_NORMAL || host->IsDeleteScheduled() ||
        host->GetProfile()->IsOffTheRecord()) return true;
    auto* strip = host->GetTabStripModel();
    for (int i = 0; i < strip->count(); ++i) {
      auto* contents = strip->GetWebContentsAt(i);
      live[PersistentSurfaceID(contents)] = contents->GetWeakPtr();
    }
    return true;
  });
  std::vector<Placement> plan;
  std::set<std::string> surfaces, keys;
  // Validate every identity, profile, frame and selection before any mutation.
  for (const auto& item : value->GetList()) {
    if (!item.is_dict()) return "invalid_request";
    const auto& dict = item.GetDict();
    const auto* container = dict.FindString("container_id");
    const auto* tabs = dict.FindList("surfaces");
    auto visible = dict.FindBool("visible");
    auto x = dict.FindInt("x"), y = dict.FindInt("y");
    auto width = dict.FindInt("width"), height = dict.FindInt("height");
    if (!container || !base::Uuid::ParseCaseInsensitive(*container).is_valid() || !tabs || tabs->empty() ||
        !visible || !x || !y || !width || !height || *x < -100000 || *x > 100000 ||
        *y < -100000 || *y > 100000 || *width < 1 || *height < 1 || *width > 30000 || *height > 30000)
      return "invalid_request";
    Placement p;
    p.bounds = gfx::Rect(*x, *y, *width, *height);
    p.visible = *visible;
    if (const auto* selected = dict.FindString("selected")) p.selected = *selected;
    bool selected_found = p.selected.empty();
    for (const auto& tab : *tabs) {
      if (!tab.is_string() || !surfaces.insert(tab.GetString()).second || surfaces.size() > 512)
        return "invalid_request";
      auto found = live.find(tab.GetString());
      if (found == live.end() || !found->second) return "unavailable";
      auto* profile = Profile::FromBrowserContext(found->second->GetBrowserContext());
      if (p.profile && p.profile != profile) return "invalid_request";
      auto* source = GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(found->second.get());
      if (!source || source->GetWindow()->IsFullscreen()) return "unsupported";
      const auto minimum = BrowserHostMinimumSize(source->GetWindow());
      if (p.visible && (p.bounds.width() < minimum.width() || p.bounds.height() < minimum.height()))
        return "unsupported";
      p.profile = profile;
      p.tabs.push_back(found->second);
      selected_found |= tab.GetString() == p.selected;
    }
    if (!selected_found || (p.visible && p.selected.empty())) return "invalid_request";
    // Durable container + durable profile namespace. Never transfer across profiles.
    p.key = base::Uuid::ParseCaseInsensitive(*container).AsLowercaseString() + ":" +
            PersistentSurfaceID(p.tabs.front().get()).substr(8, 36);
    if (!keys.insert(p.key).second) return "invalid_request";
    plan.push_back(std::move(p));
  }
  std::set<BrowserWindowInterface*> claimed;
  for (const auto& p : plan) {
    auto host = Hosts()[p.key];
    if (host && (host->IsDeleteScheduled() || host->GetProfile() != p.profile || claimed.contains(host.get()))) host.reset();
    auto eligible = [&](BrowserWindowInterface* candidate) {
      if (!candidate || candidate->IsDeleteScheduled() || candidate->GetWindow()->IsFullscreen() ||
          candidate->GetProfile() != p.profile || claimed.contains(candidate)) return false;
      auto* strip = candidate->GetTabStripModel();
      for (int i = 0; i < strip->count(); ++i)
        if (!surfaces.contains(PersistentSurfaceID(strip->GetWebContentsAt(i)))) return false;
      return true;
    };
    if (host && !eligible(host.get())) host.reset();
    if (!host) {
      if (!p.tabs.front()) return "unavailable";
      auto* candidate = GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(p.tabs.front().get());
      if (eligible(candidate)) host = candidate->GetWeakPtr();
    }
    if (!host) {
      BrowserWindowCreateParams params(p.profile.get(), true);
      params.initial_bounds = p.bounds;
      params.should_trigger_session_restore = false;
      auto* created = CreateBrowserWindow(std::move(params));
      if (!created) return "unavailable";
      host = created->GetWeakPtr();
    }
    claimed.insert(host.get());
    Hosts()[p.key] = host;
    for (const auto& contents : p.tabs) {
      if (!contents || !host || host->IsDeleteScheduled()) return "unavailable";
      auto* source = GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents.get());
      if (!source || source->IsDeleteScheduled() || source->GetProfile() != p.profile) return "unavailable";
      if (source != host.get()) {
        auto* strip = source->GetTabStripModel();
        int index = strip->GetIndexOfWebContents(contents.get());
        if (index < 0) return "unavailable";
        const bool pinned = strip->IsTabPinned(index);
        auto tab = strip->DetachTabAtForInsertion(index);
        host->GetTabStripModel()->InsertDetachedTabAt(host->GetTabStripModel()->count(), std::move(tab),
            pinned ? AddTabTypes::ADD_PINNED : AddTabTypes::ADD_NONE);
      }
    }
    if (!host || host->IsDeleteScheduled()) return "unavailable";
    auto* strip = host->GetTabStripModel();
    if (!p.selected.empty()) {
      for (int i = 0; i < strip->count(); ++i)
        if (PersistentSurfaceID(strip->GetWebContentsAt(i)) == p.selected) { strip->ActivateTabAt(i); break; }
    }
    host->GetWindow()->SetBounds(p.bounds);
    if (p.visible) host->GetWindow()->ShowInactive();
    else host->GetWindow()->Hide();
  }
  // A removed placement is released to conventional browser controls, never closed.
  for (auto it = Hosts().begin(); it != Hosts().end();) {
    if (!keys.contains(it->first) || !it->second || it->second->IsDeleteScheduled()) {
      if (it->second && !it->second->IsDeleteScheduled() && !claimed.contains(it->second.get()))
        it->second->GetWindow()->ShowInactive();
      it = Hosts().erase(it);
    } else ++it;
  }
  return "issued";
}

void ReleaseHostLayout() {
  for (auto& [key, host] : Hosts())
    if (host && !host->IsDeleteScheduled()) host->GetWindow()->ShowInactive();
  Hosts().clear();
}
}
