#include "chrome/browser/winmux/page_lifetime.h"
#include "chrome/browser/winmux/page_lifetime_policy.h"

#include <algorithm>
#include <map>
#include <memory>
#include <vector>
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/memory_coordinator/memory_consumer.h"
#include "chrome/browser/winmux/browser_inventory.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/performance_manager/policies/discard_eligibility_policy.h"
#include "chrome/browser/performance_manager/policies/page_discarding_helper.h"
#include "chrome/browser/winmux/tab_identity.h"
#include "components/performance_manager/public/decorators/page_live_state_decorator.h"
#include "components/performance_manager/public/freezing/freezing.h"
#include "components/performance_manager/public/graph/graph.h"
#include "components/performance_manager/public/graph/page_node.h"
#include "components/performance_manager/public/graph/process_node.h"
#include "components/performance_manager/public/graph/system_node.h"
#include "components/performance_manager/public/performance_manager.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"

namespace winmux {
namespace {
namespace pm = performance_manager;
constexpr char kKeepActive[] = "winmux.keep_active_pages";

struct Page {
  base::WeakPtr<content::WebContents> contents;
  base::TimeTicks last_used = base::TimeTicks::Now();
  base::TimeTicks hidden_since = base::TimeTicks::Now();
  bool visible = true;
  bool original_active = true;
  bool original_pinned = false;
  std::unique_ptr<pm::freezing::FreezingVote> freeze;
};

// Own deadlines, eligibility and resource decisions on the Performance Manager
// graph sequence. There is no helper polling or renderer-owned timer policy.
class Lifetime final : public pm::PageNodeObserver, public pm::SystemNodeObserver, public base::MemoryConsumer {
 public:
  void OnReleaseMemory() override { os_pressure_ = true; Schedule(); }
  void OnUpdateMemoryLimit() override { os_pressure_ = memory_limit() < 100; Schedule(); }
  void Set(content::WebContents* contents, bool managed, bool visible) {
    if (!pm::PerformanceManager::IsAvailable()) return;
    const auto id = PersistentSurfaceID(contents);
    if (id.empty()) return;
    if (!managed) { Forget(id); return; }
    if (!graph_) {
      graph_ = pm::PerformanceManager::GetGraph();
      graph_->AddPageNodeObserver(this);
      graph_->AddSystemNodeObserver(this);
      using T = base::MemoryConsumerTraits;
      memory_registration_ = std::make_unique<base::MemoryConsumerRegistration>("WinMuxPages",
          T(T::EstimatedMemoryUsage::kLarge, T::ReleaseMemoryCost::kRequiresTraversal,
            T::InformationRetention::kLossy, T::ExecutionType::kAsynchronous, T::InProcess::kNo), this);
    }
    auto [it, inserted] = pages_.try_emplace(id);
    auto& page = it->second;
    if (inserted) {
      page.original_active = pm::PageLiveStateDecorator::IsActiveTab(contents);
      page.original_pinned = pm::PageLiveStateDecorator::IsPinnedTab(contents);
    }
    if (page.contents.get() != contents) {
      page.freeze.reset();
      page.contents = contents->GetWeakPtr();
    }
    if (visible) {
      page.freeze.reset();
      if (inserted || !page.visible) page.last_used = base::TimeTicks::Now();
      // ShowInactive does not focus/reload the selected tab of a hidden host.
      // Every visible pane must load, without stealing another pane's focus.
      if (pm::PageLiveStateDecorator::IsDiscarded(contents)) {
        contents->GetController().SetNeedsReload();
        contents->GetController().LoadIfNecessary();
      }
    } else if (page.visible) {
      page.hidden_since = base::TimeTicks::Now();
    }
    page.visible = visible;
    // Managed window visibility is the actual workspace selection. Chromium's
    // single selected tab per hidden host must not grant a permanent exemption.
    pm::PageLiveStateDecorator::SetIsActiveTab(contents, visible);
    pm::PageLiveStateDecorator::SetIsPinnedTab(contents, (visible && page.original_pinned) || WorkspacePageKeepActive(contents));
    Schedule();
  }

  void KeepActiveChanged(content::WebContents* contents) {
    auto found = pages_.find(PersistentSurfaceID(contents));
    if (found != pages_.end()) {
      const auto& page = found->second;
      pm::PageLiveStateDecorator::SetIsPinnedTab(contents, WorkspacePageKeepActive(contents) || (page.visible && page.original_pinned));
    }
    Schedule();
  }

  void Forget(const std::string& id) {
    auto found = pages_.find(id);
    if (found == pages_.end()) return;
    auto& page = found->second;
    page.freeze.reset();
    if (page.contents && pm::PerformanceManager::IsAvailable()) {
      pm::PageLiveStateDecorator::SetIsActiveTab(page.contents.get(), page.original_active);
      pm::PageLiveStateDecorator::SetIsPinnedTab(page.contents.get(), page.original_pinned);
    }
    pages_.erase(found);
    if (pages_.empty()) timer_.Stop();
  }

  void Stop() {
    timer_.Stop();
    while (!pages_.empty()) Forget(pages_.begin()->first);
    if (graph_ && pm::PerformanceManager::IsAvailable()) {
      graph_->RemovePageNodeObserver(this);
      graph_->RemoveSystemNodeObserver(this);
    }
    graph_ = nullptr;
    memory_registration_.reset();
  }

  void Schedule() {
    // Coalesce graph notifications. Eligibility is rechecked at dispatch, never
    // acted on from a stale visibility/renderer pointer captured by a timer.
    if (!pages_.empty())
      timer_.Start(FROM_HERE, base::Milliseconds(1), this, &Lifetime::Evaluate);
  }

  void OnIsVisibleChanged(const pm::PageNode*) override { Schedule(); }
  void OnIsFocusedChanged(const pm::PageNode* node) override {
    if (node->IsFocused()) {
      for (auto& [id, page] : pages_) if (page.contents.get() == node->GetWebContents().get()) page.last_used = base::TimeTicks::Now();
    }
    Schedule();
  }
  void OnPageLifecycleStateChanged(const pm::PageNode*) override { RefreshBrowserInventory(); }
  void OnPageUsesWebRTCChanged(const pm::PageNode*) override { Schedule(); }
  void OnIsAudibleChanged(const pm::PageNode*) override { Schedule(); }
  void OnHadFormInteractionChanged(const pm::PageNode*) override { Schedule(); }
  void OnHadUserEditsChanged(const pm::PageNode*) override { Schedule(); }
  void OnProcessMemoryMetricsAvailable(const pm::SystemNode*) override { Schedule(); }

  void Evaluate() {
    if (!pm::PerformanceManager::IsAvailable()) { Stop(); return; }
    auto* eligibility = pm::policies::DiscardEligibilityPolicy::GetFromGraph(graph_);
    auto* discarder = pm::policies::PageDiscardingHelper::GetFromGraph(graph_);
    if (!eligibility || !discarder) return;
    uint64_t footprint = 0;
    for (auto* process : graph_->GetAllProcessNodes()) footprint += process->GetPrivateFootprint().InBytes();
    const bool pressure = os_pressure_ || footprint > uint64_t{8} * 1024 * 1024 * 1024;
    const auto now = base::TimeTicks::Now();
    std::vector<Page*> candidates;
    for (auto& [id, page] : pages_) {
      auto* contents = page.contents.get();
      if (!contents) { page.freeze.reset(); continue; }
      auto node = pm::PerformanceManager::GetPrimaryPageNodeForWebContents(contents);
      if (!node) { page.freeze.reset(); continue; }
      const bool protected_page = page.visible || node->IsVisible() || node->IsFocused() ||
          WorkspacePageKeepActive(contents) || node->UsesWebRTC() || contents->IsLoading() || node->HadFormInteraction() || node->HadUserEdits() ||
          contents->GetUploadPosition() < contents->GetUploadSize() ||
          contents->NeedToFireBeforeUnloadOrUnloadEvents() ||
          pm::PageLiveStateDecorator::IsDevToolsOpen(contents) ||
          (!pm::PageLiveStateDecorator::IsDiscarded(contents) &&
           eligibility->CanDiscard(node.get(), pm::policies::DiscardEligibilityPolicy::DiscardReason::PROACTIVE,
                                   /*ignore_recent_visibility=*/true) !=
               pm::policies::CanDiscardResult::kEligible);
      if (protected_page) {
        page.freeze.reset();
        page.hidden_since = now;
      } else if (!pm::PageLiveStateDecorator::IsDiscarded(contents)) {
        candidates.push_back(&page);
      }
    }
    std::sort(candidates.begin(), candidates.end(), [](const Page* a, const Page* b) { return a->last_used > b->last_used; });
    std::vector<int64_t> hidden_milliseconds;
    for (const auto* page : candidates) hidden_milliseconds.push_back((now - page->hidden_since).InMilliseconds());
    const auto actions = PlanBackgroundPages(hidden_milliseconds, pressure);
    std::vector<const pm::PageNode*> discard;
    base::TimeDelta next = base::Minutes(1);
    for (size_t rank = 0; rank < candidates.size(); ++rank) {
      auto& page = *candidates[rank];
      auto* contents = page.contents.get();
      if (!contents) continue;
      if (actions[rank] == BackgroundPageAction::kWarm && rank < 12) { page.freeze.reset(); continue; }
      const auto age = now - page.hidden_since;
      if (actions[rank] == BackgroundPageAction::kDiscard) {
        page.freeze.reset();
        if (auto node = pm::PerformanceManager::GetPrimaryPageNodeForWebContents(contents)) discard.push_back(node.get());
      } else if (actions[rank] == BackgroundPageAction::kFreeze) {
        if (!page.freeze) page.freeze = std::make_unique<pm::freezing::FreezingVote>(
            contents, /*ignore_recent_visibility=*/true);
        next = std::min(next, base::Minutes(15) - age);
      } else {
        next = std::min(next, base::Minutes(2) - age);
      }
    }
    // Under pressure release one least-recent page, then measure again. Shared
    // renderer processes make per-page memory estimates unsuitable for a burst.
    if (pressure) next = base::Seconds(5);
    // Use our own visibility deadlines, retaining all other PROACTIVE checks.
    if (!discard.empty()) discarder->ImmediatelyDiscardMultiplePages(discard,
        pm::policies::DiscardEligibilityPolicy::DiscardReason::PROACTIVE, /*ignore_recent_visibility=*/true);
    if (!pages_.empty()) timer_.Start(FROM_HERE, std::max(base::Seconds(1), next), this, &Lifetime::Evaluate);
  }

 private:
  bool os_pressure_ = false;
  std::unique_ptr<base::MemoryConsumerRegistration> memory_registration_;
  raw_ptr<pm::Graph> graph_ = nullptr;
  std::map<std::string, Page> pages_;
  base::OneShotTimer timer_;
};
Lifetime& Policy() { static base::NoDestructor<Lifetime> policy; return *policy; }
}

bool WorkspacePageKeepActive(content::WebContents* contents) {
  return Profile::FromBrowserContext(contents->GetBrowserContext())->GetPrefs()->GetList(kKeepActive).contains(PersistentSurfaceID(contents));
}
void SetWorkspacePageKeepActive(content::WebContents* contents, bool enabled) {
  ScopedListPrefUpdate update(Profile::FromBrowserContext(contents->GetBrowserContext())->GetPrefs(), kKeepActive);
  const auto id = PersistentSurfaceID(contents);
  update->EraseValue(base::Value(id));
  if (enabled) update->Append(id);
  // Pinned-tab protection is also respected by Chromium's urgent discard
  // policy. Never overwrite an extension's independent autoDiscardable vote.
  Policy().KeepActiveChanged(contents);
}
void SetWorkspacePageVisibility(content::WebContents* contents, bool managed, bool visible) { Policy().Set(contents, managed, visible); }
void ForgetWorkspacePage(const std::string& surface) { Policy().Forget(surface); }
void StopWorkspacePageLifetime() { Policy().Stop(); }
std::string WorkspacePageLifecycle(content::WebContents* contents) {
  if (!pm::PerformanceManager::IsAvailable()) return "active";
  if (pm::PageLiveStateDecorator::IsDiscarded(contents)) return "discarded";
  if (auto node = pm::PerformanceManager::GetPrimaryPageNodeForWebContents(contents)) {
    if (node->GetLifecycleState() == pm::PageNode::LifecycleState::kFrozen) return "frozen";
  }
  return contents->GetVisibility() == content::Visibility::VISIBLE ? "active" : "background";
}
}
