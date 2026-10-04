#include "chrome/browser/winmux/host_layout.h"

#include <map>
#include <memory>
#include <set>
#include <vector>
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "base/uuid.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/winmux/host_window.h"
#include "chrome/browser/winmux/tab_identity.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/rect.h"

namespace winmux {
namespace {
using Host = base::WeakPtr<BrowserWindowInterface>;

BrowserWindowInterface* BrowserForContents(content::WebContents* contents) {
  // The live inventory below already admits only pages from the global browser
  // collection. Resolve their current owner directly: FindBrowserWithTab also
  // copies/scans that entire collection to check membership on every call.
  // Consult the tab again after earlier placements, since reconciliation can
  // detach a page into a different host during this same layout request.
  auto* tab = tabs::TabInterface::MaybeGetFromContents(contents);
  return tab ? tab->GetBrowserWindowInterface() : nullptr;
}

// Chromium may insert tabs through page links, extensions or keyboard commands.
// Do not leave those pages inside a managed window's hidden native tabstrip.
// Detach after the notification finishes; TabStripModel forbids reentrant edits.
class PageHostObserver : public TabStripModelObserver {
 public:
  PageHostObserver(Host browser, std::string surface)
      : browser_(browser), surface_(std::move(surface)) {
    browser_->GetTabStripModel()->AddObserver(this);
  }
  ~PageHostObserver() override = default;

  void Reconcile() { SeparateNewPages(); }

  void OnTabStripModelChanged(TabStripModel* strip,
                             const TabStripModelChange& change,
                             const TabStripSelectionChange& selection) override {
    if (change.type() != TabStripModelChange::kInserted || pending_) return;
    pending_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&PageHostObserver::SeparateNewPages,
                                 weak_factory_.GetWeakPtr()));
  }

 private:
  void SeparateNewPages() {
    pending_ = false;
    if (!browser_ || browser_->IsDeleteScheduled() ||
        !IsBrowserHostManaged(browser_.get())) return;
    auto* strip = browser_->GetTabStripModel();
    for (int index = strip->count() - 1; index >= 0; --index) {
      if (PersistentSurfaceID(strip->GetWebContentsAt(index)) == surface_) continue;
      // The new page starts as a conventional independent window. Winmux's next
      // inventory/layout adopts it with Swift controls; release remains usable.
      BrowserWindowCreateParams params(browser_->GetProfile(), true);
      params.initial_bounds = browser_->GetWindow()->GetBounds();
      params.should_trigger_session_restore = false;
      auto* created = CreateBrowserWindow(std::move(params));
      if (!created) {
        SetBrowserHostManaged(browser_.get(), false);
        browser_->GetWindow()->ShowInactive();
        return;
      }
      const bool pinned = strip->IsTabPinned(index);
      const bool foreground = strip->active_index() == index &&
                              browser_->GetWindow()->IsActive();
      auto tab = strip->DetachTabAtForInsertion(index);
      created->GetTabStripModel()->InsertDetachedTabAt(
          0, std::move(tab), AddTabTypes::ADD_ACTIVE |
              (pinned ? AddTabTypes::ADD_PINNED : AddTabTypes::ADD_NONE));
      if (foreground) created->GetWindow()->Show();
      else created->GetWindow()->ShowInactive();
      if (!browser_ || browser_->IsDeleteScheduled()) return;
    }
  }

  Host browser_;
  std::string surface_;
  bool pending_ = false;
  base::WeakPtrFactory<PageHostObserver> weak_factory_{this};
};

struct ManagedHost {
  Host browser;
  std::unique_ptr<PageHostObserver> observer;
};
std::map<std::string, ManagedHost>& Hosts() {
  static base::NoDestructor<std::map<std::string, ManagedHost>> hosts;
  return *hosts;
}
struct Placement {
  std::string surface;
  raw_ptr<Profile> profile = nullptr;
  base::WeakPtr<content::WebContents> contents;
  gfx::Rect bounds;
  bool visible = false;
  bool managed = false;
};

void Release(ManagedHost& host) {
  host.observer.reset();
  if (host.browser && !host.browser->IsDeleteScheduled()) {
    SetBrowserHostManaged(host.browser.get(), false);
    if (!IsBrowserHostSuspended(host.browser.get()))
      host.browser->GetWindow()->ShowInactive();
  }
}
}

std::string ApplyHostLayout(const std::string& json) {
  auto value = base::JSONReader::Read(json, base::JSON_PARSE_RFC);
  if (!value || !value->is_list() || value->GetList().size() > 512)
    return "invalid_request";
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
  std::set<std::string> surfaces;
  // Validate the whole request before moving any page. A container is solely a
  // Swift grouping identity; even legacy grouped requests get one host per page.
  for (const auto& item : value->GetList()) {
    if (!item.is_dict()) return "invalid_request";
    const auto& dict = item.GetDict();
    const auto* container = dict.FindString("container_id");
    const auto* tabs = dict.FindList("surfaces");
    const auto* selected = dict.FindString("selected");
    auto visible = dict.FindBool("visible");
    const auto* native_controls = dict.Find("native_controls");
    if (native_controls && !native_controls->is_bool()) return "invalid_request";
    // Older helpers cannot provide Swift navigation controls. Keep Chromium's
    // own controls until this placement explicitly opts into the native UI.
    const bool managed = dict.FindBool("native_controls").value_or(false);
    auto x = dict.FindInt("x"), y = dict.FindInt("y");
    auto width = dict.FindInt("width"), height = dict.FindInt("height");
    if (!container || !base::Uuid::ParseCaseInsensitive(*container).is_valid() ||
        !tabs || tabs->empty() || !visible || !x || !y || !width || !height ||
        *x < -100000 || *x > 100000 || *y < -100000 || *y > 100000 ||
        *width < 1 || *height < 1 || *width > 30000 || *height > 30000 ||
        (*visible && (!selected || selected->empty()))) return "invalid_request";
    bool selected_found = !selected || selected->empty();
    for (const auto& tab : *tabs) {
      if (!tab.is_string() || !surfaces.insert(tab.GetString()).second ||
          surfaces.size() > 512) return "invalid_request";
      auto found = live.find(tab.GetString());
      if (found == live.end() || !found->second) return "unavailable";
      auto* source = BrowserForContents(found->second.get());
      if (!source) return "unsupported";
      auto existing = Hosts().find(tab.GetString());
      const bool suspended_host = existing != Hosts().end() &&
          existing->second.browser.get() == source && IsBrowserHostSuspended(source);
      if (IsBrowserHostFullscreen(source) && !suspended_host) return "unsupported";
      Placement p;
      p.surface = tab.GetString();
      p.profile = Profile::FromBrowserContext(found->second->GetBrowserContext());
      p.contents = found->second;
      p.bounds = gfx::Rect(*x, *y, *width, *height);
      const bool is_selected = selected && *selected == p.surface;
      selected_found |= is_selected;
      p.visible = *visible && is_selected;
      p.managed = managed;
      const auto minimum = p.managed ? BrowserManagedHostMinimumSize()
                                     : BrowserHostMinimumSize(source->GetWindow());
      if (p.bounds.width() < minimum.width() || p.bounds.height() < minimum.height())
        return "unsupported";
      plan.push_back(std::move(p));
    }
    if (!selected_found) return "invalid_request";
  }

  std::set<BrowserWindowInterface*> claimed;
  std::vector<Host> hide_after_reveal;
  for (const auto& p : plan) {
    if (!p.contents) return "unavailable";
    auto* source = BrowserForContents(p.contents.get());
    if (!source || source->IsDeleteScheduled() || source->GetProfile() != p.profile)
      return "unavailable";
    // Reuse only the page's own singleton host. This is independent of container
    // and profile groupings, so regrouping never changes its native window ID.
    Host host;
    auto existing = Hosts().find(p.surface);
    if (existing != Hosts().end()) {
      host = existing->second.browser;
      // Native Dock minimize and fullscreen own the host's presentation. A
      // workspace replan must neither restore nor resize it during that time.
      if (host.get() == source && IsBrowserHostSuspended(source)) {
        SetBrowserHostManaged(source, p.managed);
        claimed.insert(source);
        continue;
      }
      // A layout can arrive before the posted insertion observer. Keep the
      // original page's window identity stable in that case as well.
      if (p.managed && host.get() == source && existing->second.observer &&
          source->GetTabStripModel()->count() > 1)
        existing->second.observer->Reconcile();
    }
    auto eligible = [&](BrowserWindowInterface* candidate) {
      return candidate && !candidate->IsDeleteScheduled() &&
             !candidate->GetWindow()->IsFullscreen() &&
             candidate->GetProfile() == p.profile && !claimed.contains(candidate) &&
             candidate->GetTabStripModel()->count() == 1 &&
             candidate->GetTabStripModel()->GetWebContentsAt(0) == p.contents.get();
    };
    if (!eligible(host.get())) host.reset();
    if (!host && eligible(source)) host = source->GetWeakPtr();
    if (!host) {
      BrowserWindowCreateParams params(p.profile.get(), true);
      params.initial_bounds = p.bounds;
      params.should_trigger_session_restore = false;
      auto* created = CreateBrowserWindow(std::move(params));
      if (!created) return "unavailable";
      host = created->GetWeakPtr();
    }
    if (source != host.get()) {
      auto* strip = source->GetTabStripModel();
      int index = strip->GetIndexOfWebContents(p.contents.get());
      if (index < 0) return "unavailable";
      const bool pinned = strip->IsTabPinned(index);
      auto tab = strip->DetachTabAtForInsertion(index);
      host->GetTabStripModel()->InsertDetachedTabAt(
          0, std::move(tab), AddTabTypes::ADD_ACTIVE |
              (pinned ? AddTabTypes::ADD_PINNED : AddTabTypes::ADD_NONE));
    }
    if (!host || host->IsDeleteScheduled() ||
        host->GetTabStripModel()->count() != 1) return "unavailable";
    if (!SetBrowserHostManaged(host.get(), p.managed)) return "unsupported";
    auto& managed = Hosts()[p.surface];
    if (managed.browser.get() != host.get()) {
      Release(managed);
      managed.browser = host;
    }
    // Mode changes commonly reuse the same native host, so observer lifetime
    // must follow the requested controls mode rather than host replacement.
    if (p.managed && !managed.observer)
      managed.observer = std::make_unique<PageHostObserver>(host, p.surface);
    else if (!p.managed)
      managed.observer.reset();
    claimed.insert(host.get());
    auto* window = host->GetWindow();
    // A visibility-only group switch must not resize the page or reorder an
    // already visible peer. Both operations can trigger Cocoa/renderer layout
    // and produce movement even though the workspace geometry is unchanged.
    if (window->GetBounds() != p.bounds) window->SetBounds(p.bounds);
    if (p.visible) {
      if (!window->IsVisible()) window->ShowInactive();
    } else if (window->IsVisible()) {
      hide_after_reveal.push_back(host);
    }
  }
  // Reveal the incoming group before withdrawing the old one, independently of
  // surface-ID ordering. Avoid a desktop flash between two complete layouts.
  for (const auto& host : hide_after_reveal) {
    if (host && !host->IsDeleteScheduled() &&
        !IsBrowserHostSuspended(host.get())) host->GetWindow()->Hide();
  }
  // A removed placement is released to conventional controls, never closed.
  for (auto it = Hosts().begin(); it != Hosts().end();) {
    // Suspended pages remain members of the durable workspace tree, although
    // Swift omits them from the live tile plan until Dock/fullscreen restoration.
    if (!surfaces.contains(it->first) && it->second.browser &&
        !it->second.browser->IsDeleteScheduled() &&
        IsBrowserHostSuspended(it->second.browser.get())) {
      ++it;
      continue;
    }
    if (!surfaces.contains(it->first) || !it->second.browser ||
        it->second.browser->IsDeleteScheduled()) {
      // A page can close while another is being inserted in the same native
      // host. Retire the stale observer without restoring a newly claimed host.
      if (it->second.browser && claimed.contains(it->second.browser.get()))
        it->second.observer.reset();
      else
        Release(it->second);
      it = Hosts().erase(it);
    } else ++it;
  }
  return "issued";
}

void ReleaseHostLayout() {
  for (auto& [surface, host] : Hosts()) Release(host);
  Hosts().clear();
}
}
