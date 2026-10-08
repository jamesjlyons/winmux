#ifndef CHROME_BROWSER_WINMUX_PREPARED_BROWSER_WINDOW_H_
#define CHROME_BROWSER_WINMUX_PREPARED_BROWSER_WINDOW_H_

#include <memory>

#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/memory_coordinator/memory_consumer.h"
#include "base/timer/timer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"

namespace winmux {
// One installation-wide spare, confined to the browser UI sequence. Only a
// loaded regular profile is eligible; warming never loads profiles or URLs.
class PreparedBrowserWindow final : public base::MemoryConsumer {
 public:
  explicit PreparedBrowserWindow(base::RepeatingClosure changed);
  ~PreparedBrowserWindow() override;
  void Prepare(Profile* profile);
  BrowserWindowInterface* Take(Profile* profile);
  bool Contains(BrowserWindowInterface* browser) const;
  void ReleaseIfModified();
  void Reset();
  void OnReleaseMemory() override;
  void OnUpdateMemoryLimit() override;

 private:
  void Create(Profile* profile);
  base::RepeatingClosure changed_;
  base::WeakPtr<BrowserWindowInterface> spare_;
  base::OneShotTimer timer_;
  bool under_pressure_ = false;
  // Registration is destroyed before any of the consumer state.
  std::unique_ptr<base::MemoryConsumerRegistration> registration_;
};
}  // namespace winmux
#endif
