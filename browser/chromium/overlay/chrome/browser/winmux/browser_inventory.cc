#include "chrome/browser/winmux/browser_inventory.h"

#include <deque>
#include <limits>
#include <map>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/hash/sha1.h"
#include "chrome/browser/winmux/host_layout.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "chrome/browser/winmux/tab_identity.h"
#include "chrome/browser/winmux/host_window.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/base_window.h"
#include "ui/gfx/geometry/rect.h"
#include "url/gurl.h"

namespace winmux {
namespace {
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

  void BeginEpoch(std::string epoch) {
    epoch_ = std::move(epoch);
    operations_.clear();
    operation_order_.clear();
    highest_focus_ = 0;
    highest_layout_ = 0;
    Update(true);
  }

  std::string Perform(const std::string& epoch, BrowserSurfaceAction request) {
    if (epoch.empty() || epoch != epoch_)
      return "stale_epoch";
    auto operation = base::Uuid::ParseCaseInsensitive(request.operation);
    if (!operation.is_valid() || request.surface.size() > 128)
      return "invalid_request";
    request.operation = operation.AsLowercaseString();
    auto previous = operations_.find(request.operation);
    if (previous != operations_.end()) {
      return previous->second.first == request ? previous->second.second
                                              : "operation_conflict";
    }
    if (request.action != "focus" && request.action != "close" && request.action != "cancel_focus")
      return "unsupported";
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
    // Cache before invoking the owner; lifecycle callbacks can run reentrantly.
    Remember(request);
    if (request.action == "focus") {
      strip->ActivateTabAt(index);
      browser->GetWindow()->Show();
      browser->GetWindow()->Activate();
    } else {
      strip->CloseWebContents(contents, TabCloseTypes::CLOSE_USER_GESTURE |
                                          TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
    }
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
  void OnBrowserClosed(BrowserWindowInterface* browser) override {
    Schedule();
  }
  void OnTabStripModelChanged(TabStripModel*, const TabStripModelChange&,
                              const TabStripSelectionChange&) override { Schedule(); }
  void OnTabChangedAt(tabs::TabInterface*, TabChangeType) override { Schedule(); }
  void OnTabStripModelDestroyed(TabStripModel* strip) override {
    Schedule();
  }

 private:
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
    std::map<std::string, base::DictValue> next;
    live_.clear();
    GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* browser) {
      if (browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
          browser->GetProfile()->IsOffTheRecord() || browser->IsDeleteScheduled())
        return true;
      auto* strip = browser->GetTabStripModel();
      for (int index = 0; index < strip->count(); ++index) {
        auto* contents = strip->GetWebContentsAt(index);
        auto id = PersistentSurfaceID(contents);
        if (id.empty())
          continue;
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
        record.Set("title", base::UTF16ToUTF8(contents->GetTitle().substr(0, 1024)));
        record.Set("selected", index == strip->active_index());
        record.Set("private", false);
        next.emplace(id, std::move(record));
        live_.emplace(id, contents);
      }
      return true;
    });
    base::ListValue changed, removed;
    for (const auto& [id, record] : next) {
      auto previous = records_.find(id);
      if (full || previous == records_.end() || previous->second != record)
        changed.Append(record.Clone());
    }
    if (!full) {
      for (const auto& [id, record] : records_) {
        if (!next.contains(id))
          removed.Append(id);
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
  std::map<std::string, raw_ptr<content::WebContents>> live_;
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
void StopBrowserInventory() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  delete std::exchange(inventory, nullptr);
}
void BeginBrowserInventoryEpoch(std::string epoch) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (inventory)
    inventory->BeginEpoch(std::move(epoch));
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
