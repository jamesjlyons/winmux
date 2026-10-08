#include "chrome/browser/winmux/prepared_browser_window.h"

#include "base/functional/bind.h"
#include "base/command_line.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/sessions/session_service.h"
#include "chrome/browser/sessions/session_service_factory.h"
#include "chrome/browser/ui/browser_init_state.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/sessions/content/session_tab_helper.h"
#include "ui/base/base_window.h"
#include "url/gurl.h"

namespace winmux {
namespace {
bool Pristine(BrowserWindowInterface* browser) {
  auto* strip = browser->GetTabStripModel();
  if (strip->count() > 1) return false;
  auto* contents = strip->GetActiveWebContents();
  return !contents || contents->GetVisibleURL().is_empty() ||
      contents->GetVisibleURL() == GURL("about:blank");
}
void Promote(BrowserWindowInterface* browser) {
  BrowserInitState::From(browser)->PromotePreparedWindowForSessionRestore();
  if (auto* session = SessionServiceFactory::GetForProfile(browser->GetProfile())) {
    session->WindowOpened(browser);
    auto* strip = browser->GetTabStripModel();
    for (int index = 0; index < strip->count(); ++index) {
      auto* contents = strip->GetWebContentsAt(index);
      auto id = sessions::SessionTabHelper::FromWebContents(contents)->session_id();
      session->SetTabWindow(browser->GetSessionID(), id);
      session->SetTabIndexInWindow(browser->GetSessionID(), id, index);
      session->TabRestored(contents, strip->IsTabPinned(index));
    }
    session->SetSelectedTabInWindow(browser->GetSessionID(), strip->active_index());
  }
}
}
PreparedBrowserWindow::PreparedBrowserWindow(base::RepeatingClosure changed)
    : changed_(std::move(changed)) {
  using T = base::MemoryConsumerTraits;
  registration_ = std::make_unique<base::MemoryConsumerRegistration>(
      "WinMuxPreparedWindow",
      T(T::EstimatedMemoryUsage::kLarge, T::ReleaseMemoryCost::kRequiresTraversal,
        T::InformationRetention::kLossy, T::ExecutionType::kSynchronous,
        T::InProcess::kNo), this);
}

PreparedBrowserWindow::~PreparedBrowserWindow() { Reset(); }

void PreparedBrowserWindow::Prepare(Profile* profile) {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("winmux-disable-tab-warming") ||
      !profile || !profile->IsRegularProfile() || under_pressure_ ||
      browser_shutdown::IsTryingToQuit() || browser_shutdown::HasShutdownStarted()) {
    Reset();
    return;
  }
  if (spare_ && !spare_->IsDeleteScheduled() && spare_->GetProfile() == profile)
    return;
  // Reset cancels the previous profile's pending timer too. Acquire no profile
  // lifetime here: the inventory's authenticated profile owner already does.
  Reset();
  timer_.Start(FROM_HERE, base::Milliseconds(250),
               base::BindOnce(&PreparedBrowserWindow::Create,
                              base::Unretained(this), profile));
}

void PreparedBrowserWindow::Create(Profile* profile) {
  if (under_pressure_ || browser_shutdown::IsTryingToQuit() ||
      browser_shutdown::HasShutdownStarted()) return;
  BrowserWindowCreateParams params(profile, false);
  params.should_trigger_session_restore = false;
  params.omit_from_session_restore = true;
  auto* browser = CreateBrowserWindow(std::move(params));
  if (!browser) return;
  BrowserInitState::From(browser)->MarkPreparedWindowForWinMux();
  spare_ = browser->GetWeakPtr();
  // The tab helper/navigator path installs Chromium's normal keyed services.
  // No Show(), activation, profile loading, or speculative network request.
  if (!chrome::AddAndReturnTabAt(browser, GURL("about:blank"), -1, true)) {
    Reset(); return;
  }
  browser->GetWindow()->Hide();
  changed_.Run();
}

BrowserWindowInterface* PreparedBrowserWindow::Take(Profile* profile) {
  timer_.Stop();
  if (!spare_ || spare_->IsDeleteScheduled() || spare_->GetProfile() != profile ||
      !profile->IsRegularProfile() || under_pressure_ ||
      spare_->GetTabStripModel()->count() != 1 || !Pristine(spare_.get())) {
    Reset(); return nullptr;
  }
  auto* browser = spare_.get();
  spare_.reset();
  Promote(browser);
  return browser;
}

bool PreparedBrowserWindow::Contains(BrowserWindowInterface* browser) const {
  return spare_.get() == browser;
}

void PreparedBrowserWindow::ReleaseIfModified() {
  if (spare_ && !spare_->IsDeleteScheduled() && !Pristine(spare_.get())) Reset();
}

void PreparedBrowserWindow::Reset() {
  timer_.Stop();
  auto old = spare_;
  spare_.reset();
  if (old && !old->IsDeleteScheduled() && !browser_shutdown::HasShutdownStarted() &&
      !browser_shutdown::IsTryingToQuit()) {
    // An extension can find even a hidden Chromium window. Never discard work
    // it inserted/navigated while the window was waiting to be consumed.
    if (!Pristine(old.get())) {
      Promote(old.get());
      old->GetWindow()->ShowInactive();
    } else {
      // Window Close() records a recently-closed window independently of
      // SessionService's omit flag. Discard the unused blank without a
      // historical tab; closing the last tab also closes its empty window.
      auto* strip = old->GetTabStripModel();
      if (!strip->empty()) strip->CloseWebContentsAt(0, TabCloseTypes::CLOSE_NONE);
      else old->GetWindow()->Close();
    }
  }
}

void PreparedBrowserWindow::OnReleaseMemory() {
  under_pressure_ = true;
  Reset();
}
void PreparedBrowserWindow::OnUpdateMemoryLimit() {
  under_pressure_ = memory_limit() < 100;
  if (under_pressure_) Reset();
  // Memory coordinator requests release separately. Do not warm automatically
  // on recovery: the next foreground interaction supplies the profile again.
}
}  // namespace winmux
