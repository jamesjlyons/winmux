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
      worker_->PostTask(
          FROM_HERE,
          base::BindOnce(&EngineState::Initialize, base::Unretained(this)));
    }
    return true;
  }

  std::shared_ptr<WMBlocker> Get() { base::AutoLock guard(lock_); return engine_; }
  std::string Rules() { base::AutoLock guard(lock_); return rules_; }
  void Replace(std::string rules, base::OnceCallback<void(bool)> completion) {
    if (rules.empty() || rules.size() > 16 * 1024 * 1024) { std::move(completion).Run(false); return; }
    auto caller = base::SequencedTaskRunner::GetCurrentDefault();
    worker_->PostTask(FROM_HERE, base::BindOnce(
        [](EngineState* state, std::string rules, scoped_refptr<base::SequencedTaskRunner> caller,
           base::OnceCallback<void(bool)> done) {
          std::shared_ptr<WMBlocker> next(wm_blocker_create(View(rules)), &wm_blocker_free);
          bool accepted = next != nullptr;
          if (accepted) {
            base::AutoLock guard(state->lock_);
            state->engine_ = std::move(next);
            state->rules_ = std::move(rules);
          }
          caller->PostTask(FROM_HERE, base::BindOnce(std::move(done), accepted));
        }, base::Unretained(this), std::move(rules), std::move(caller), std::move(completion)));
  }

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
      if (!engine_) engine_ = std::move(engine);
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
  std::shared_ptr<WMBlocker> engine_;
  std::string rules_;
  scoped_refptr<base::SequencedTaskRunner> worker_ = base::ThreadPool::CreateSequencedTaskRunner({base::TaskPriority::USER_VISIBLE});
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

void ReplaceBlockingRules(std::string rules, base::OnceCallback<void(bool)> completion) { State().Replace(std::move(rules), std::move(completion)); }
std::string CurrentBlockingRules() { return State().Rules(); }

RequestDecision CheckRequest(const GURL& url, const GURL& initiator, std::string_view type, std::string_view method) {
  auto engine = State().Get();
  if (!url.SchemeIsHTTPOrHTTPS() || !engine) return {};
  WMDecision decision = wm_blocker_check(engine.get(), View(url.spec()), View(initiator.spec()), View(type), View(method), true);
  RequestDecision result;
  result.blocked = decision.status == WM_OK && decision.blocked;
  // Only the locally authored empty.js resource is executable. Downloaded
  // filter lists cannot introduce remote redirects or JavaScript bodies.
  if (result.blocked && decision.redirect && type == "script" && method == "GET") {
    std::string_view redirect(decision.redirect);
    result.empty_script = redirect == "data:application/javascript;base64," || redirect == "data:text/javascript;base64,";
  }
  wm_string_free(decision.redirect);
  wm_string_free(decision.rewritten_url);
  TRACE_EVENT("loading", "WinMux.RequestDecision", "blocked", result.blocked);
  return result;
}
bool ShouldBlockRequest(const GURL& url, const GURL& initiator, std::string_view type, std::string_view method) {
  return CheckRequest(url, initiator, type, method).blocked;
}

std::string CosmeticSelectors(const GURL& url, std::string_view tokens_json) {
  auto engine = State().Get();
  if (!engine || !url.SchemeIsHTTPOrHTTPS())
    return "[]";
  std::unique_ptr<char, decltype(&wm_string_free)> initial(
      wm_blocker_cosmetics(engine.get(), View(url.spec()), true), &wm_string_free);
  std::unique_ptr<char, decltype(&wm_string_free)> dynamic(
      wm_blocker_dynamic_cosmetics(engine.get(), View(url.spec()), View(tokens_json),
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
