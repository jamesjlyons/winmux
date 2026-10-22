#include "chrome/browser/winmux/host_layout.h"
#include "chrome/browser/winmux/page_lifetime.h"
#include "chrome/browser/winmux/tab_creation_trace.h"

#include <algorithm>
#include <array>
#include <cmath>
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
#include "base/time/time.h"
#include "base/timer/timer.h"
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
    // Fullscreen owns the active WebContents and toolbar hierarchy. The
    // completion hook replays reconciliation once Chromium has released them.
    if (IsBrowserHostFullscreen(browser_.get())) return;
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
// Glides an already visible host to its new tile with the critically damped
// spring native tiles use (WindowFrameAnimation.swift), so a view that mixes
// pages and apps moves as one. The position moves on every display frame.
// Resizing a browser window relayouts and rasters the page, so the size
// advances in a few steps instead; arrival applies the exact destination.
struct HostMotion {
  Host browser;
  gfx::Rect target;
  gfx::Size minimum;
  gfx::Size start_size;
  gfx::Size applied_size;
  std::array<double, 4> value{};
  std::array<double, 4> velocity{};
  double elapsed = 0;
  double duration = 0;
};
constexpr int kResizeSteps = 6;
constexpr int kMinimumResizeStep = 24;

std::map<std::string, HostMotion>& Motions() {
  static base::NoDestructor<std::map<std::string, HostMotion>> motions;
  return *motions;
}

base::TimeTicks& LastMotionTick() {
  static base::TimeTicks tick;
  return tick;
}

std::array<double, 4> Components(const gfx::Rect& rect) {
  return {static_cast<double>(rect.x()), static_cast<double>(rect.y()),
          static_cast<double>(rect.width()), static_cast<double>(rect.height())};
}

// Returns true on arrival. Mirrors WindowFrameAnimation.advance.
bool Advance(HostMotion& motion, double dt) {
  motion.elapsed += dt;
  if (motion.elapsed >= std::max(0.25, motion.duration * 3)) return true;
  const auto goal = Components(motion.target);
  const double omega = 8 / motion.duration, decay = std::exp(-omega * dt);
  bool arrived = true;
  for (size_t i = 0; i < 4; ++i) {
    const double displacement = motion.value[i] - goal[i];
    const double coefficient = motion.velocity[i] + displacement * omega;
    motion.value[i] = goal[i] + (displacement + coefficient * dt) * decay;
    motion.velocity[i] = (motion.velocity[i] - coefficient * (omega * dt)) * decay;
    arrived &= std::abs(motion.value[i] - goal[i]) < 0.5 && std::abs(motion.velocity[i]) < 8;
  }
  return arrived;
}

void FinishMotion(std::map<std::string, HostMotion>::iterator it, bool apply) {
  auto& motion = it->second;
  if (motion.browser && !motion.browser->IsDeleteScheduled()) {
    auto* window = motion.browser->GetWindow();
    if (apply && window->GetBounds() != motion.target) window->SetBounds(motion.target);
    SetBrowserHostGliding(motion.browser.get(), false);
  }
  Motions().erase(it);
}

void StopMotion(const std::string& surface, bool apply) {
  auto it = Motions().find(surface);
  if (it != Motions().end()) FinishMotion(it, apply);
  if (Motions().empty()) StopHostDisplayLink();
}

void TickMotions() {
  const auto now = base::TimeTicks::Now();
  const double dt = std::max(0.0, (now - LastMotionTick()).InSecondsF());
  LastMotionTick() = now;
  // A held pointer may be dragging a page; never fight it for the frame.
  const bool finish = IsPointerButtonHeld();
  for (auto it = Motions().begin(); it != Motions().end();) {
    auto current = it++;
    auto& motion = current->second;
    if (!motion.browser || motion.browser->IsDeleteScheduled() ||
        IsBrowserHostSuspended(motion.browser.get()) ||
        !motion.browser->GetWindow()->IsVisible()) {
      FinishMotion(current, false);
      continue;
    }
    if (finish || Advance(motion, dt)) {
      FinishMotion(current, true);
      continue;
    }
    gfx::Rect frame(static_cast<int>(std::lround(motion.value[0])),
                    static_cast<int>(std::lround(motion.value[1])),
                    std::max(motion.minimum.width(), static_cast<int>(std::lround(motion.value[2]))),
                    std::max(motion.minimum.height(), static_cast<int>(std::lround(motion.value[3]))));
    const gfx::Size goal = motion.target.size();
    const int step_width = std::max(kMinimumResizeStep,
        std::abs(goal.width() - motion.start_size.width()) / kResizeSteps);
    const int step_height = std::max(kMinimumResizeStep,
        std::abs(goal.height() - motion.start_size.height()) / kResizeSteps);
    if (std::abs(frame.width() - motion.applied_size.width()) >= step_width ||
        std::abs(frame.height() - motion.applied_size.height()) >= step_height) {
      motion.applied_size = frame.size();
    } else {
      frame.set_size(motion.applied_size);
    }
    auto* window = motion.browser->GetWindow();
    if (window->GetBounds() != frame) window->SetBounds(frame);
  }
  if (Motions().empty()) StopHostDisplayLink();
}

// A new destination keeps the current presentation and velocity.
void GlideHost(const std::string& surface, const Host& browser, const gfx::Rect& target,
               int duration_ms, const gfx::Size& minimum) {
  auto it = Motions().find(surface);
  if (it != Motions().end() && it->second.browser.get() != browser.get()) {
    FinishMotion(it, false);
    it = Motions().end();
  }
  if (it == Motions().end()) {
    const auto start = browser->GetWindow()->GetBounds();
    if (start == target) return;
    HostMotion motion;
    motion.browser = browser;
    motion.value = Components(start);
    motion.start_size = start.size();
    motion.applied_size = start.size();
    it = Motions().emplace(surface, std::move(motion)).first;
  } else if (it->second.target == target) {
    return;
  } else {
    // A new destination measures its resize steps from the size on screen.
    it->second.start_size = it->second.applied_size;
  }
  it->second.target = target;
  it->second.minimum = minimum;
  it->second.elapsed = 0;
  it->second.duration = duration_ms / 1000.0;
  SetBrowserHostGliding(browser.get(), true);
  if (!IsHostDisplayLinkRunning()) {
    LastMotionTick() = base::TimeTicks::Now();
    StartHostDisplayLink(base::BindRepeating(&TickMotions));
  }
}

struct Placement {
  std::string surface;
  raw_ptr<Profile> profile = nullptr;
  base::WeakPtr<content::WebContents> contents;
  gfx::Rect bounds;
  bool visible = false;
  bool managed = false;
  bool integrated_toolbar = false;
  int animation_ms = 0;
  gfx::Size minimum;
};

void Release(ManagedHost& host) {
  host.observer.reset();
  if (host.browser && !host.browser->IsDeleteScheduled()) {
    auto* strip = host.browser->GetTabStripModel();
    for (int i = 0; i < strip->count(); ++i) SetWorkspacePageVisibility(strip->GetWebContentsAt(i), false, true);
    SetBrowserHostManaged(host.browser.get(), false);
    if (!IsBrowserHostSuspended(host.browser.get()))
      host.browser->GetWindow()->ShowInactive();
  }
}
}

std::string ApplyHostLayout(const std::string& json) {
  auto value = base::JSONReader::Read(json, base::JSON_PARSE_RFC);
  if (!value || !value->is_list() || value->GetList().size() > kMaximumHostLayoutPages)
    return "invalid_request";
  std::map<std::string, base::WeakPtr<content::WebContents>> live;
  GlobalBrowserCollection::GetInstance()->ForEach([&](BrowserWindowInterface* host) {
    if (host->GetType() != BrowserWindowInterface::TYPE_NORMAL || host->IsDeleteScheduled() ||
        host->GetProfile()->IsGuestSession() || host->GetProfile()->IsSystemProfile()) return true;
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
    const auto* integrated_value = dict.Find("integrated_toolbar");
    if (integrated_value && !integrated_value->is_bool()) return "invalid_request";
    const bool integrated = dict.FindBool("integrated_toolbar").value_or(false);
    if (integrated && !managed) return "invalid_request";
    const auto* animation_value = dict.Find("animation_ms");
    if (animation_value && !animation_value->is_int()) return "invalid_request";
    const int animation_ms = dict.FindInt("animation_ms").value_or(0);
    if (animation_ms < 0 || animation_ms > 1000) return "invalid_request";
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
          surfaces.size() > kMaximumHostLayoutPages) return "invalid_request";
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
      p.integrated_toolbar = integrated;
      p.animation_ms = animation_ms;
      const auto minimum = p.managed && !p.integrated_toolbar
          ? BrowserManagedHostMinimumSize() : BrowserHostMinimumSize(source->GetWindow());
      if (p.bounds.width() < minimum.width() || p.bounds.height() < minimum.height())
        return "unsupported";
      p.minimum = minimum;
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
    BrowserWindowInterface* previous_host = nullptr;
    if (existing != Hosts().end()) {
      host = existing->second.browser;
      previous_host = host.get();
      // Native Dock minimize and fullscreen own the host's presentation. A
      // workspace replan must neither restore nor resize it during that time.
      if (host.get() == source && IsBrowserHostSuspended(source)) {
        SetBrowserHostManaged(source, p.managed, p.integrated_toolbar);
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
    if (!SetBrowserHostManaged(host.get(), p.managed, p.integrated_toolbar)) return "unsupported";
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
    // Only the page's own, already visible host glides. Reveals, adoption,
    // new hosts and moves between displays take their frame immediately.
    if (p.animation_ms > 0 && p.visible && host.get() == previous_host &&
        host.get() == source && window->IsVisible() && !IsPointerButtonHeld() &&
        BrowserHostFramesShareDisplay(window->GetBounds(), p.bounds)) {
      GlideHost(p.surface, host, p.bounds, p.animation_ms, p.minimum);
    } else {
      StopMotion(p.surface, false);
      if (window->GetBounds() != p.bounds) window->SetBounds(p.bounds);
    }
    SetWorkspacePageVisibility(host->GetTabStripModel()->GetWebContentsAt(0), p.managed, p.visible);
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
  for (const auto& p : plan) {
    if (!p.visible || !p.contents) continue;
    if (auto* browser = BrowserForContents(p.contents.get())) {
      TraceTabSurface(p.surface, "layout_applied");
      TraceTabPresentation(browser, p.surface);
    }
  }
  for (auto it = Motions().begin(); it != Motions().end();) {
    auto current = it++;
    if (!surfaces.contains(current->first)) FinishMotion(current, false);
  }
  if (Motions().empty()) StopHostDisplayLink();
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
  while (!Motions().empty()) FinishMotion(Motions().begin(), false);
  StopHostDisplayLink();
  for (auto& [surface, host] : Hosts()) Release(host);
  Hosts().clear();
}

void ReconcileBrowserHostPages(BrowserWindowInterface* browser) {
  for (auto& [surface, host] : Hosts()) {
    if (host.browser.get() == browser && host.observer) {
      host.observer->Reconcile();
      return;
    }
  }
}
}
