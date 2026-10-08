#include "chrome/browser/winmux/tab_creation_trace.h"
#include "base/logging.h"
#include "base/json/json_writer.h"
#include "base/values.h"
#include <map>
#include <deque>
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/time/time.h"
#include "chrome/browser/ui/views/frame/browser_view.h"
#include "components/viz/common/frame_timing_details.h"
#include "ui/compositor/compositor.h"
#include "ui/views/widget/widget.h"

namespace winmux {
namespace {
bool Enabled() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch("winmux-trace-tabs");
}
std::map<std::string, std::string>& Operations() {
  static base::NoDestructor<std::map<std::string, std::string>> operations;
  return *operations;
}
std::deque<std::string>& OperationOrder() {
  static base::NoDestructor<std::deque<std::string>> order;
  return *order;
}
void Emit(const std::string& operation, const char* stage, base::TimeTicks at) {
  base::DictValue event;
  event.Set("operation", operation);
  event.Set("stage", stage);
  event.Set("time_us", static_cast<double>(at.since_origin().InMicroseconds()));
  LOG(INFO) << "WINMUX_TAB_TIMING " << base::WriteJson(event).value_or("{}");
}
}
void TraceTabCreation(const std::string& operation, const char* stage,
                      const std::string& surface) {
  if (!Enabled()) return;
  if (!surface.empty()) {
    if (!Operations().contains(surface)) OperationOrder().push_back(surface);
    Operations()[surface] = operation;
    if (OperationOrder().size() > 128) {
      Operations().erase(OperationOrder().front());
      OperationOrder().pop_front();
    }
  }
  Emit(operation, stage, base::TimeTicks::Now());
}
void TraceTabSurface(const std::string& surface, const char* stage) {
  if (!Enabled()) return;
  if (auto found = Operations().find(surface); found != Operations().end())
    Emit(found->second, stage, base::TimeTicks::Now());
}
void TraceTabPresentation(BrowserWindowInterface* browser,
                          const std::string& surface) {
  if (!Enabled()) return;
  auto found = Operations().find(surface);
  if (found == Operations().end()) return;
  auto* view = BrowserView::GetBrowserViewForBrowser(browser);
  auto* compositor = view && view->GetWidget() ? view->GetWidget()->GetCompositor() : nullptr;
  if (!compositor) return;
  compositor->RequestSuccessfulPresentationTimeForNextFrame(base::BindOnce(
      [](std::string operation, const viz::FrameTimingDetails& details) {
        Emit(operation, "presented", details.presentation_feedback.timestamp);
      }, found->second));
}
}
