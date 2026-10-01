#include "components/winmux/blocking/engine.h"

#include <atomic>
#include <memory>
#include <utility>
#include <vector>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/trace_event/trace_event.h"
#include "components/winmux/blocking/winmux_blocking.h"

namespace winmux {
namespace {
WMStringView View(std::string_view value) {
  return {reinterpret_cast<const uint8_t*>(value.data()), value.size()};
}

struct Pending {
  scoped_refptr<base::SequencedTaskRunner> sequence;
  base::OnceClosure callback;
};

// One immutable ruleset per process, shared by all profiles. Queries receive
// site context separately; no browsing data is stored in this shared object.
class EngineState {
 public:
  bool Defer(base::OnceClosure callback) {
    base::AutoLock guard(lock_);
    if (finished_)
      return false;
    pending_.push_back(
        {base::SequencedTaskRunner::GetCurrentDefault(), std::move(callback)});
    if (!started_) {
      started_ = true;
      base::ThreadPool::PostTask(
          FROM_HERE, {base::TaskPriority::USER_VISIBLE},
          base::BindOnce(&EngineState::Initialize, base::Unretained(this)));
    }
    return true;
  }

  WMBlocker* Get() { return published_.load(std::memory_order_acquire); }

 private:
  void Initialize() {
    TRACE_EVENT("loading", "WinMux.CompileBundledRules");
    std::unique_ptr<WMBlocker, decltype(&wm_blocker_free)> engine(
        wm_blocker_create_bundled(), &wm_blocker_free);
    if (!engine)
      LOG(ERROR) << "WinMux bundled blocker initialization failed";
    std::vector<Pending> pending;
    {
      base::AutoLock guard(lock_);
      engine_ = std::move(engine);
      published_.store(engine_.get(), std::memory_order_release);
      finished_ = true;
      pending.swap(pending_);
    }
    for (auto& item : pending)
      item.sequence->PostTask(FROM_HERE, std::move(item.callback));
  }

  base::Lock lock_;
  bool started_ = false;
  bool finished_ = false;
  std::vector<Pending> pending_;
  std::unique_ptr<WMBlocker, decltype(&wm_blocker_free)> engine_{
      nullptr, &wm_blocker_free};
  std::atomic<WMBlocker*> published_{nullptr};
};

EngineState& State() {
  // Callback targets and the ruleset live until process teardown.
  static base::NoDestructor<EngineState> state;
  return *state;
}
}  // namespace

bool DeferUntilBlockingReady(base::OnceClosure resume) {
  return State().Defer(std::move(resume));
}

bool ShouldBlockRequest(const GURL& url,
                        const GURL& initiator,
                        std::string_view type,
                        std::string_view method) {
  if (!url.SchemeIsHTTPOrHTTPS() || !State().Get())
    return false;
  WMDecision decision = wm_blocker_check(
      State().Get(), View(url.spec()), View(initiator.spec()), View(type),
      View(method), true);
  bool blocked = decision.status == WM_OK && decision.blocked;
  // M0 proves block/exception decisions. Replacement bodies and URL rewriting
  // require their own loader response integration and are not applied here.
  wm_string_free(decision.redirect);
  wm_string_free(decision.rewritten_url);
  TRACE_EVENT("loading", "WinMux.RequestDecision", "blocked", blocked);
  return blocked;
}

std::string CosmeticSelectors(const GURL& url, std::string_view tokens_json) {
  WMBlocker* engine = State().Get();
  if (!engine || !url.SchemeIsHTTPOrHTTPS())
    return "[]";
  std::unique_ptr<char, decltype(&wm_string_free)> initial(
      wm_blocker_cosmetics(engine, View(url.spec()), true), &wm_string_free);
  std::unique_ptr<char, decltype(&wm_string_free)> dynamic(
      wm_blocker_dynamic_cosmetics(engine, View(url.spec()), View(tokens_json),
                                  true), &wm_string_free);
  base::ListValue selectors;
  if (initial) {
    auto value = base::JSONReader::ReadDict(initial.get(), base::JSON_PARSE_RFC);
    if (value) {
      if (auto* list = value->FindList("hide_selectors"))
        selectors = list->Clone();
    }
  }
  if (dynamic) {
    auto list = base::JSONReader::ReadList(dynamic.get(), base::JSON_PARSE_RFC);
    if (list) {
      for (auto& value : *list)
        selectors.Append(std::move(value));
    }
  }
  return base::WriteJson(selectors).value_or("[]");
}
}  // namespace winmux
