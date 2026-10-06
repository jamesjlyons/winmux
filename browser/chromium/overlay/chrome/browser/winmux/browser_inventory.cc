#include "chrome/browser/winmux/browser_inventory.h"
#include "chrome/browser/winmux/page_lifetime.h"
#include "chrome/browser/winmux/privacy_settings.h"

#include <deque>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/base64.h"
#include "base/json/json_writer.h"
#include "base/hash/sha1.h"
#include "chrome/browser/winmux/host_layout.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/extensions/extensions_container.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/winmux/tab_identity.h"
#include "chrome/browser/winmux/profile_identity_lookup.h"
#include "chrome/browser/winmux/host_window.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents_observer.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "ui/gfx/image/image.h"
#include "content/public/common/referrer.h"
#include "content/public/browser/reload_type.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/rect.h"
#include "url/gurl.h"

namespace winmux {
namespace {
// A same-document navigation can change URL/history without changing the tab's
// title or loading flag, so observe contents as well as the tab strip.
class TabNavigationObserver final : public content::WebContentsObserver {
 public:
  TabNavigationObserver(content::WebContents* contents, base::RepeatingClosure changed)
      : content::WebContentsObserver(contents), changed_(std::move(changed)) {}
  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame()) changed_.Run();
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame()) changed_.Run();
  }
  void DidStartLoading() override { changed_.Run(); }
  void DidStopLoading() override { changed_.Run(); }
  void NavigationEntryCommitted(const content::LoadCommittedDetails&) override { changed_.Run(); }
  void NavigationListPruned(const content::PrunedDetails&) override { changed_.Run(); }
  void NavigationEntriesDeleted() override { changed_.Run(); }
  void WebContentsDestroyed() override { changed_.Run(); }
 private:
  base::RepeatingClosure changed_;
};

class BrowserInventory final : public BrowserCollectionObserver,
                               public TabStripModelObserver {
 public:
  BrowserInventory(base::RepeatingCallback<void(std::string, std::string)> publisher,
                   bool seed_test)
      : publisher_(std::move(publisher)), seed_test_(seed_test) {
    collection_.Observe(GlobalBrowserCollection::GetInstance());
    GlobalBrowserCollection::GetInstance()->ForEach([this](BrowserWindowInterface* browser) {
      OnBrowserCreated(browser);
      return true;
    });
  }

  void Refresh() { Schedule(); }

  void BeginEpoch(std::string epoch) {
    for (auto& [operation, creation] : pending_creations_) {
      for (auto& callback : creation.callbacks) std::move(callback).Run("stale_epoch", "");
    }
    pending_creations_.clear();
    for (auto& [operation, pending] : pending_privacy_) for (auto& callback : pending.callbacks) std::move(callback).Run("stale_epoch");
    pending_privacy_.clear();
    epoch_ = std::move(epoch);
    operations_.clear();
    operation_order_.clear();
    highest_focus_ = 0;
    highest_layout_ = 0;
    Update(true);
  }

  void OpenTab(const std::string& epoch, BrowserSurfaceAction request,
               BrowserTabCreationCallback completion) {
    if (epoch.empty() || epoch != epoch_) { std::move(completion).Run("stale_epoch", ""); return; }
    auto operation = base::Uuid::ParseCaseInsensitive(request.operation);
    if (!operation.is_valid() || request.action != "open_tab" || request.surface.size() > 128 ||
        request.generation != 0) { std::move(completion).Run("invalid_request", ""); return; }
    request.operation = operation.AsLowercaseString();
    auto pending = pending_creations_.find(request.operation);
    if (pending != pending_creations_.end()) {
      if (pending->second.request != request) { std::move(completion).Run("operation_conflict", ""); return; }
      if (pending->second.callbacks.size() >= 16) { std::move(completion).Run("unavailable", ""); return; }
      pending->second.callbacks.push_back(std::move(completion));
      return;
    }
    auto previous = operations_.find(request.operation);
    if (previous != operations_.end()) {
      if (previous->second.first != request) { std::move(completion).Run("operation_conflict", ""); return; }
      const auto& result = previous->second.second;
      if (result.starts_with("created:")) std::move(completion).Run("issued", result.substr(8));
      else std::move(completion).Run(result, "");
      return;
    }
    if (request.url) {
      GURL url(*request.url);
      if (request.url->empty() || request.url->size() > 16384 || !url.is_valid() ||
          !(url.SchemeIsHTTPOrHTTPS() || url.SchemeIsFile() || url.SchemeIs("about") ||
            url.SchemeIs("chrome") || url.SchemeIs("chrome-extension"))) {
        std::move(completion).Run("invalid_request", ""); return;
      }
    }
    if (pending_) Update(false);
    if (request.revision != static_cast<uint64_t>(revision_)) {
      std::move(completion).Run("stale_revision", ""); return;
    }
    if (pending_creations_.size() >= 16 || (browser_shutdown::HasShutdownStarted() || browser_shutdown::IsTryingToQuit())) {
      std::move(completion).Run("unavailable", ""); return;
    }
    auto* manager = g_browser_process->profile_manager();
    if (!manager) { std::move(completion).Run("unavailable", ""); return; }
    base::FilePath profile_path;
    std::string lookup_uuid;
    std::vector<base::FilePath> registered_paths;
    if (request.surface.empty()) {
      profile_path = manager->GetLastUsedProfileDir();
    } else if (request.surface.starts_with("profile:")) {
      auto profile_id = base::Uuid::ParseCaseInsensitive(request.surface.substr(8));
      if (!profile_id.is_valid()) { std::move(completion).Run("invalid_request", ""); return; }
      const auto uuid = profile_id.AsLowercaseString();
      auto entries = manager->GetProfileAttributesStorage().GetAllProfilesAttributes();
      if (entries.size() > kMaximumProfileIdentityCandidates) {
        std::move(completion).Run("unavailable", ""); return;
      }
      // Loaded registered profiles have authoritative in-memory preferences.
      // An unloaded registered profile can still contain a copied UUID, so a
      // loaded match alone must not bypass checking the remaining accounts.
      for (auto* entry : entries) {
        auto path = entry->GetPath();
        if (auto* loaded = manager->GetProfileByPath(path)) {
          if (ExistingProfileID(loaded) != uuid) continue;
          if (!profile_path.empty() && profile_path != path) {
            std::move(completion).Run("unavailable", ""); return;
          }
          profile_path = std::move(path);
        } else {
          registered_paths.push_back(std::move(path));
        }
      }
      // A single loaded primary account remains immediate. Other unloaded
      // accounts are read on a worker, with any loaded match as its seed.
      if (!registered_paths.empty()) lookup_uuid = uuid;
    } else {
      auto found = live_.find(request.surface);
      if (found == live_.end()) { std::move(completion).Run("unavailable", ""); return; }
      profile_path = Profile::FromBrowserContext(found->second->GetBrowserContext())->GetPath();
    }
    PendingCreation creation{request, {}};
    creation.callbacks.push_back(std::move(completion));
    pending_creations_.emplace(request.operation, std::move(creation));
    // Reserve operation identity before profile loading or window callbacks.
    Remember(request, "pending");
    if (!lookup_uuid.empty()) {
      if (!base::ThreadPool::PostTaskAndReplyWithResult(
              FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
              base::BindOnce(&FindRegisteredProfileIdentity,
                             std::move(registered_paths), std::move(lookup_uuid),
                             std::move(profile_path)),
              base::BindOnce(&BrowserInventory::LoadProfileForCreation,
                             weak_factory_.GetWeakPtr(), epoch, request.operation))) {
        FinishOpenTab(epoch, request.operation, nullptr);
      }
    } else {
      LoadProfileForCreation(epoch, request.operation, std::move(profile_path));
    }
  }

  std::string Perform(const std::string& epoch, BrowserSurfaceAction request, BrowserActionCallback completion = {}) {
    if (epoch.empty() || epoch != epoch_)
      return "stale_epoch";
    auto operation = base::Uuid::ParseCaseInsensitive(request.operation);
    if (!operation.is_valid() || request.surface.size() > 128)
      return "invalid_request";
    request.operation = operation.AsLowercaseString();
    if (auto pending = pending_privacy_.find(request.operation); pending != pending_privacy_.end()) {
      if (pending->second.request != request) return "operation_conflict";
      if (!completion || pending->second.callbacks.size() >= 16) return "unavailable";
      pending->second.callbacks.push_back(std::move(completion));
      return "pending_privacy";
    }
    auto previous = operations_.find(request.operation);
    if (previous != operations_.end()) {
      if (previous->second.first != request) return "operation_conflict";
      return previous->second.second;
    }
    if (request.action != "focus" && request.action != "close" && request.action != "cancel_focus" &&
        request.action != "back" && request.action != "forward" && request.action != "reload" &&
        request.action != "stop" && request.action != "navigate" && request.action != "new_tab" &&
        request.action != "extensions" && request.action != "manage_extensions" &&
        request.action != "minimize" && request.action != "fullscreen" && request.action != "zoom" &&
        request.action != "search" && request.action != "privacy" && request.action != "keep_active" && request.action != "site_blocking")
      return "unsupported";
    if ((request.url && (request.url->size() > 16384 ||
                         (request.action != "navigate" && request.action != "new_tab" && request.action != "search" && request.action != "privacy" && request.action != "keep_active" && request.action != "site_blocking"))) ||
        (request.action == "navigate" && (!request.url || request.url->empty())))
      return "invalid_request";
    GURL target;
    if (request.url && (request.action == "navigate" || request.action == "new_tab")) {
      target = GURL(*request.url);
      // The address field opens documents, never javascript/data execution
      // payloads. Chromium retains its normal policy and permission checks.
      if (!target.is_valid() || !(target.SchemeIsHTTPOrHTTPS() || target.SchemeIsFile() ||
          target.SchemeIs("about") || target.SchemeIs("chrome") || target.SchemeIs("chrome-extension")))
        return "invalid_request";
    }
    if (request.action == "focus" || request.action == "cancel_focus") {
      if (!request.generation || request.generation <= highest_focus_)
        return "stale_focus";
      highest_focus_ = request.generation;
    }
    // A fence deliberately needs neither a live tab nor a matching inventory
    // revision: closing/reconciling a tab must not prevent retiring old focus.
    if (request.action == "cancel_focus") {
      Remember(request);
      return "issued";
    }
    // Refresh invalidated bindings before dereferencing a removed/replaced tab.
    if (pending_)
      Update(false);
    if (request.revision != static_cast<uint64_t>(revision_))
      return "stale_revision";
    auto found = live_.find(request.surface);
    if (found == live_.end())
      return "unavailable";
    auto* contents = found->second.get();
    auto* browser = GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
    if (!browser || browser->IsDeleteScheduled())
      return "unavailable";
    auto* strip = browser->GetTabStripModel();
    int index = strip->GetIndexOfWebContents(contents);
    if (index < 0)
      return "unavailable";
    auto& navigation = contents->GetController();
    if ((request.action == "back" && !navigation.CanGoBack()) ||
        (request.action == "forward" && !navigation.CanGoForward()))
      return "unavailable";
    if (request.action == "minimize" || request.action == "fullscreen" || request.action == "zoom") {
      if (!BrowserHostWindowID(browser->GetWindow())) return "unavailable";
      if (request.action != "fullscreen" && IsBrowserHostFullscreen(browser)) return "unsupported";
      if (request.action != "minimize" && IsBrowserHostMinimized(browser)) return "unavailable";
    }
    if (request.action == "search") {
      if (!request.url || request.url->empty()) return "invalid_request";
      target = WorkspaceSearch(browser->GetProfile(), *request.url);
      if (!target.is_valid()) return "invalid_request";
    }
    if ((request.action == "keep_active" || request.action == "site_blocking") &&
        (!request.url || (*request.url != "true" && *request.url != "false"))) return "invalid_request";
    if (request.action == "privacy") {
      if (!request.url || !completion) return "invalid_request";
      if (pending_privacy_.size() >= 16) return "unavailable";
      Remember(request, "pending_privacy");
      PendingPrivacy pending{request, {}};
      pending.callbacks.push_back(std::move(completion));
      pending_privacy_.emplace(request.operation, std::move(pending));
      UpdateWorkspacePrivacy(browser->GetProfile(), *request.url,
          base::BindOnce(&BrowserInventory::FinishPrivacy, weak_factory_.GetWeakPtr(), epoch, request.operation));
      return "pending_privacy";
    }
    // Cache before invoking the owner; lifecycle callbacks can run reentrantly.
    Remember(request);
    if (request.action == "focus") {
      strip->ActivateTabAt(index);
      if (IsBrowserHostMinimized(browser)) RestoreMinimizedBrowserHost(browser);
      // BrowserView::Show activates an already visible window and shows hidden
      // windows actively. A second Activate repeats Cocoa window ordering and
      // transaction synchronization for the same focus request.
      browser->GetWindow()->Show();
      // A detached one-page host may retain focus in Chromium's now-hidden
      // toolbar. Managed surfaces own their controls in Swift; selecting the
      // page must explicitly give its renderer keyboard focus.
      if (IsBrowserHostManaged(browser)) contents->Focus();
    } else if (request.action == "close") {
      strip->CloseWebContents(contents, TabCloseTypes::CLOSE_USER_GESTURE |
                                          TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
    } else if (request.action == "minimize") {
      if (!IsBrowserHostMinimized(browser)) MinimizeBrowserHost(browser);
    } else if (request.action == "fullscreen") {
      ToggleBrowserHostFullscreen(browser);
    } else if (request.action == "zoom") {
      ZoomBrowserHost(browser);
    } else if (request.action == "back") {
      navigation.GoBack();
    } else if (request.action == "forward") {
      navigation.GoForward();
    } else if (request.action == "reload") {
      navigation.Reload(content::ReloadType::NORMAL, /*check_for_repost=*/true);
    } else if (request.action == "stop") {
      contents->Stop();
    } else if (request.action == "keep_active") {
      SetWorkspacePageKeepActive(contents, *request.url == "true");
    } else if (request.action == "site_blocking") {
      SetWorkspaceSiteBlocking(contents, *request.url == "true");
      navigation.Reload(content::ReloadType::NORMAL, true);
    } else if (request.action == "navigate" || request.action == "search") {
      navigation.LoadURL(target, content::Referrer(), ui::PAGE_TRANSITION_TYPED, std::string());
    } else if (request.action == "new_tab") {
      browser->OpenGURL(request.url ? target : GURL("about:blank"),
                        WindowOpenDisposition::NEW_FOREGROUND_TAB);
    } else if (request.action == "extensions") {
      strip->ActivateTabAt(index);
      browser->GetWindow()->Show();
      auto* extensions = ExtensionsContainer::From(*browser);
      if (extensions && extensions->HasAnyExtensions()) {
        extensions->ToggleExtensionsMenu();
      } else {
        browser->OpenGURL(GURL("chrome://extensions/"), WindowOpenDisposition::NEW_FOREGROUND_TAB);
      }
    } else if (request.action == "manage_extensions") {
      browser->OpenGURL(GURL("chrome://extensions/"), WindowOpenDisposition::NEW_FOREGROUND_TAB);
    }
    Schedule();
    // This is dispatch acknowledgement, never presentation/input confirmation.
    return "issued";
  }

  std::string Layout(const std::string& epoch, const std::string& operation,
                     uint64_t revision, uint64_t generation, const std::string& json) {
    if (epoch.empty() || epoch != epoch_) return "stale_epoch";
    auto op = base::Uuid::ParseCaseInsensitive(operation);
    if (!op.is_valid() || json.size() > 262144) return "invalid_request";
    BrowserSurfaceAction request{"layout", base::SHA1HashString(json), op.AsLowercaseString(), revision, generation};
    auto previous = operations_.find(request.operation);
    if (previous != operations_.end())
      return previous->second.first == request ? previous->second.second : "operation_conflict";
    if (!generation || generation <= highest_layout_) return "stale_layout";
    highest_layout_ = generation;
    if (pending_) Update(false);
    if (revision != static_cast<uint64_t>(revision_)) return "stale_revision";
    auto outcome = ApplyHostLayout(json);
    Remember(request, outcome);
    Schedule();
    return outcome;
  }

  void OnBrowserCreated(BrowserWindowInterface* browser) override {
    if (browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
        browser->GetProfile()->IsOffTheRecord())
      return;
    RetainWorkspaceProfile(browser->GetProfile());
    // TabStripModelObserver removes itself automatically when the source dies.
    browser->GetTabStripModel()->AddObserver(this);
    Schedule();
    if (seed_test_) {
      seed_test_ = false;
      base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
          FROM_HERE, base::BindOnce([](base::WeakPtr<BrowserWindowInterface> host) {
            if (host && !host->IsDeleteScheduled())
              host->OpenGURL(GURL("about:blank#winmux-inventory-test"),
                             WindowOpenDisposition::NEW_BACKGROUND_TAB);
          }, browser->GetWeakPtr()), base::Milliseconds(500));
    }
  }
  void OnBrowserClosed(BrowserWindowInterface* browser) override { Schedule(); }
  void OnBrowserActivated(BrowserWindowInterface* browser) override { Schedule(); }
  void OnBrowserDeactivated(BrowserWindowInterface* browser) override { Schedule(); }
  void OnTabStripModelChanged(TabStripModel*, const TabStripModelChange&,
                              const TabStripSelectionChange&) override { Schedule(); }
  void OnTabChangedAt(tabs::TabInterface*, TabChangeType) override { Schedule(); }
  void OnTabStripModelDestroyed(TabStripModel* strip) override {
    Schedule();
  }

 private:
  struct PendingCreation {
    BrowserSurfaceAction request;
    std::vector<BrowserTabCreationCallback> callbacks;
  };

  void LoadProfileForCreation(const std::string& epoch, const std::string& operation,
                              base::FilePath path) {
    if (epoch != epoch_ || !pending_creations_.contains(operation)) return;
    auto* manager = g_browser_process->profile_manager();
    // Profiles can be deleted while the worker is reading their Preferences.
    // Registered existing paths are the only permitted loading targets.
    if (path.empty() || !manager || browser_shutdown::HasShutdownStarted() ||
        browser_shutdown::IsTryingToQuit() ||
        !manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(path)) {
      FinishOpenTab(epoch, operation, nullptr);
      return;
    }
    if (auto* profile = manager->GetProfileByPath(path)) {
      FinishOpenTab(epoch, operation, profile);
    } else if (!manager->LoadProfileByPath(path, false,
        base::BindOnce(&BrowserInventory::FinishOpenTab,
                       weak_factory_.GetWeakPtr(), epoch, operation))) {
      FinishOpenTab(epoch, operation, nullptr);
    }
  }

  void FinishOpenTab(const std::string& epoch, const std::string& operation, Profile* profile) {
    // A profile load from an old connection must never open a page later.
    if (epoch != epoch_) return;
    auto found = pending_creations_.find(operation);
    if (found == pending_creations_.end()) return;
    auto creation = std::move(found->second);
    pending_creations_.erase(found);
    std::string outcome = "unavailable", surface;
    std::string expected_profile;
    if (creation.request.surface.starts_with("profile:")) {
      expected_profile = base::Uuid::ParseCaseInsensitive(
          creation.request.surface.substr(8)).AsLowercaseString();
    } else if (creation.request.surface.starts_with("browser:")) {
      expected_profile = base::Uuid::ParseCaseInsensitive(
          creation.request.surface.substr(8, 36)).AsLowercaseString();
    }
    // Revalidate the loaded preference: a deleted/replaced directory or a
    // changed UUID must never silently open a pin in another account.
    auto* manager = g_browser_process->profile_manager();
    if (profile && (!manager ||
        !manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(profile->GetPath()) ||
        (!expected_profile.empty() && ExistingProfileID(profile) != expected_profile))) {
      profile = nullptr;
    }
    profile = ProfileManager::MaybeForceOffTheRecordMode(profile);
    if (profile && !profile->IsOffTheRecord() && !profile->IsGuestSession() &&
        !profile->IsSystemProfile() && !(browser_shutdown::HasShutdownStarted() || browser_shutdown::IsTryingToQuit())) {
      RetainWorkspaceProfile(profile);
      BrowserWindowCreateParams params(profile, true);
      params.should_trigger_session_restore = false;
      auto* browser = CreateBrowserWindow(std::move(params));
      if (browser) {
        browser->OpenGURL(GURL(creation.request.url.value_or("chrome://newtab/")),
                          WindowOpenDisposition::NEW_FOREGROUND_TAB);
        auto* contents = browser->GetTabStripModel()->GetActiveWebContents();
        if (contents) surface = PersistentSurfaceID(contents);
        if (!surface.empty()) {
          browser->GetWindow()->Show();
          outcome = "issued";
        }
      }
    }
    // Keep the exact created ID in the bounded shared operation cache, including
    // when a repeat arrives after that page has already been closed.
    const auto cached = outcome == "issued" ? "created:" + surface : outcome;
    if (auto previous = operations_.find(operation); previous != operations_.end()) previous->second.second = cached;
    else Remember(creation.request, cached);
    Schedule();
    for (auto& callback : creation.callbacks) std::move(callback).Run(outcome, surface);
  }

  void FinishPrivacy(const std::string& epoch, const std::string& operation, std::string outcome) {
    if (epoch_ != epoch) return;
    auto found = pending_privacy_.find(operation);
    if (found == pending_privacy_.end()) return;
    auto callbacks = std::move(found->second.callbacks); pending_privacy_.erase(found);
    if (auto cached = operations_.find(operation); cached != operations_.end()) cached->second.second = outcome;
    Schedule();
    for (auto& callback : callbacks) std::move(callback).Run(outcome);
  }

  void RetainWorkspaceProfile(Profile* profile) {
    if (epoch_.empty() || !profile || !profile->IsRegularProfile()) return;
    auto& retained = profile_keep_alives_[profile->GetPath()];
    if (!retained || retained->profile() != profile) {
      // The authenticated workspace is a background owner of its profiles.
      // Closing its last page must not tear down keyed services and immediately
      // recreate them: services such as Shortcuts release SQLite asynchronously.
      // This profile-only keepalive does not prevent an explicit browser Quit.
      retained = ScopedProfileKeepAlive::TryAcquire(profile, ProfileKeepAliveOrigin::kBackgroundMode);
    }
  }

  void Remember(const BrowserSurfaceAction& request, const std::string& outcome = "issued") {
    operations_.emplace(request.operation, std::make_pair(request, outcome));
    operation_order_.push_back(request.operation);
    if (operation_order_.size() > 128) {
      operations_.erase(operation_order_.front());
      operation_order_.pop_front();
    }
  }
  void Schedule() {
    // A coalesced metadata update must not leave a dangling action target.
    live_.clear();
    if (pending_)
      return;
    pending_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&BrowserInventory::Update,
                                 weak_factory_.GetWeakPtr(), false));
  }
  void Update(bool full) {
    pending_ = false;
    // Browser quit closes WebContents as part of session shutdown. Those are
    // not user tab-close tombstones: retain the last authoritative placement.
    if (browser_shutdown::IsTryingToQuit() || browser_shutdown::HasShutdownStarted()) return;
    std::map<std::string, base::DictValue> next;
    std::set<std::string> observed;
    std::set<int> observed_hosts;
    live_.clear();
    GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* browser) {
      if (browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
          browser->GetProfile()->IsOffTheRecord() || browser->IsDeleteScheduled())
        return true;
      RetainWorkspaceProfile(browser->GetProfile());
      const int host_id = browser->GetSessionID().id();
      observed_hosts.insert(host_id);
      auto& host_observer = host_observers_[host_id];
      if (!host_observer) {
        host_observer = ObserveBrowserHostWindow(browser,
            base::BindRepeating(&BrowserInventory::Schedule, weak_factory_.GetWeakPtr()));
      }
      auto* strip = browser->GetTabStripModel();
      for (int index = 0; index < strip->count(); ++index) {
        auto* contents = strip->GetWebContentsAt(index);
        auto id = PersistentSurfaceID(contents);
        if (id.empty())
          continue;
        observed.insert(id);
        auto& observer = navigation_observers_[id];
        if (!observer || observer->web_contents() != contents) {
          observer = std::make_unique<TabNavigationObserver>(contents,
              base::BindRepeating(&BrowserInventory::Schedule, weak_factory_.GetWeakPtr()));
        }
        base::DictValue record;
        record.Set("surface_id", id);
        record.Set("host_id", "host:" + base::NumberToString(browser->GetSessionID().id()));
        uint32_t host_window = BrowserHostWindowID(browser->GetWindow());
        if (host_window)
          record.Set("host_window_id", static_cast<double>(host_window));
        auto bounds = browser->GetWindow()->GetBounds();
        base::DictValue frame;
        frame.Set("x", bounds.x()); frame.Set("y", bounds.y());
        frame.Set("width", bounds.width()); frame.Set("height", bounds.height());
        record.Set("host_frame", std::move(frame));
        record.Set("host_visible", browser->GetWindow()->IsVisible());
        record.Set("host_minimized", IsBrowserHostMinimized(browser));
        record.Set("host_fullscreen", IsBrowserHostFullscreen(browser));
        record.Set("host_zoomed", IsBrowserHostZoomed(browser));
        auto minimum = BrowserHostMinimumSize(browser->GetWindow());
        base::DictValue minimum_size;
        minimum_size.Set("width", minimum.width());
        minimum_size.Set("height", minimum.height());
        record.Set("host_minimum_size", std::move(minimum_size));
        record.Set("title", base::UTF16ToUTF8(contents->GetTitle().substr(0, 1024)));
        record.Set("selected", index == strip->active_index());
        record.Set("focused", index == strip->active_index() && browser->GetWindow()->IsActive());
        record.Set("host_managed", IsBrowserHostManaged(browser));
        record.Set("url", contents->GetVisibleURL().spec().substr(0, 16384));
        if (auto* favicon = favicon::ContentFaviconDriver::FromWebContents(contents);
            favicon && favicon->FaviconIsValid()) {
          // The driver's regular favicon is a small 16-DIP image. Send a
          // bounded thumbnail so a closed pin can keep its site identity.
          auto png = favicon->GetFavicon().As1xPNGBytes();
          if (png && png->size() > 0 && png->size() <= 98304) {
            record.Set("icon_png_base64", base::Base64Encode(base::span(*png)));
          }
        }
        record.Set("can_go_back", contents->GetController().CanGoBack());
        record.Set("can_go_forward", contents->GetController().CanGoForward());
        record.Set("is_loading", contents->IsLoading());
        record.Set("private", false);
        record.Set("lifecycle", WorkspacePageLifecycle(contents));
        record.Set("keep_active", WorkspacePageKeepActive(contents));
        record.Set("blocked_requests", WorkspaceBlockedCount(contents));
        record.Set("blocking_enabled", WorkspaceSiteBlockingEnabled(browser->GetProfile(), contents->GetLastCommittedURL()));
        record.Set("privacy", WorkspacePrivacyState(browser->GetProfile()));
        next.emplace(id, std::move(record));
        live_.emplace(id, contents);
      }
      return true;
    });
    std::erase_if(navigation_observers_, [&](const auto& item) { return !observed.contains(item.first); });
    std::erase_if(host_observers_, [&](const auto& item) { return !observed_hosts.contains(item.first); });
    base::ListValue changed, removed;
    for (const auto& [id, record] : next) {
      auto previous = records_.find(id);
      if (full || previous == records_.end() || previous->second != record)
        changed.Append(record.Clone());
    }
    if (!full) {
      for (const auto& [id, record] : records_) {
        if (!next.contains(id)) {
          ForgetWorkspacePage(id);
          removed.Append(id);
        }
      }
    }
    records_ = std::move(next);
    if (epoch_.empty() || (!full && changed.empty() && removed.empty()))
      return;
    CHECK_LT(revision_, std::numeric_limits<int>::max());
    base::DictValue message;
    message.Set("revision", ++revision_);
    message.Set("full", full);
    message.Set("tabs", std::move(changed));
    message.Set("removed", std::move(removed));
    auto json = base::WriteJson(message);
    if (json)
      publisher_.Run(epoch_, std::move(*json));
  }

  base::RepeatingCallback<void(std::string, std::string)> publisher_;
  bool seed_test_;
  bool pending_ = false;
  int revision_ = 0;
  uint64_t highest_focus_ = 0;
  uint64_t highest_layout_ = 0;
  std::string epoch_;
  std::map<std::string, base::DictValue> records_;
  std::map<std::string, std::unique_ptr<TabNavigationObserver>> navigation_observers_;
  std::map<int, std::unique_ptr<BrowserHostWindowObserver>> host_observers_;
  std::map<std::string, raw_ptr<content::WebContents>> live_;
  std::map<base::FilePath, std::unique_ptr<ScopedProfileKeepAlive>> profile_keep_alives_;
  std::map<std::string, PendingCreation> pending_creations_;
  struct PendingPrivacy { BrowserSurfaceAction request; std::vector<BrowserActionCallback> callbacks; };
  std::map<std::string, PendingPrivacy> pending_privacy_;
  std::map<std::string, std::pair<BrowserSurfaceAction, std::string>> operations_;
  std::deque<std::string> operation_order_;
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver> collection_{this};
  base::WeakPtrFactory<BrowserInventory> weak_factory_{this};
};

BrowserInventory* inventory = nullptr;  // Browser process lifetime; UI-thread only.
}  // namespace

void StartBrowserInventory(base::RepeatingCallback<void(std::string, std::string)> publisher,
                           bool seed_isolated_test) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!inventory) {
    inventory = new BrowserInventory(std::move(publisher), seed_isolated_test);
  }
}
void RefreshBrowserInventory() { if (inventory) inventory->Refresh(); }
void StopBrowserInventory() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  delete std::exchange(inventory, nullptr);
}
void BeginBrowserInventoryEpoch(std::string epoch) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (inventory)
    inventory->BeginEpoch(std::move(epoch));
}
void OpenBrowserTab(const std::string& epoch, BrowserSurfaceAction request,
                    BrowserTabCreationCallback completion) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (inventory) inventory->OpenTab(epoch, std::move(request), std::move(completion));
  else std::move(completion).Run("unavailable", "");
}
void PerformBrowserSurfaceActionAsync(const std::string& epoch, BrowserSurfaceAction request, BrowserActionCallback completion) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!inventory) { std::move(completion).Run("unavailable"); return; }
  auto split = base::SplitOnceCallback(std::move(completion));
  const auto result = inventory->Perform(epoch, std::move(request), std::move(split.first));
  if (result != "pending_privacy") std::move(split.second).Run(result);
}
std::string PerformBrowserSurfaceAction(const std::string& epoch, BrowserSurfaceAction request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return inventory ? inventory->Perform(epoch, std::move(request)) : "unavailable";
}
std::string PerformBrowserLayout(const std::string& epoch, const std::string& operation,
                                 uint64_t revision, uint64_t generation, const std::string& json) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return inventory ? inventory->Layout(epoch, operation, revision, generation, json) : "unavailable";
}
void ReleaseBrowserLayout() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  ReleaseHostLayout();
}
}  // namespace winmux
