#ifndef CHROME_BROWSER_WINMUX_PAGE_LIFETIME_POLICY_H_
#define CHROME_BROWSER_WINMUX_PAGE_LIFETIME_POLICY_H_

#include <cstdint>
#include <span>
#include <vector>

namespace winmux {

enum class BackgroundPageAction { kWarm, kFreeze, kDiscard };

// The caller excludes protected pages and orders eligible pages by recency.
// Milliseconds keep this policy independently testable without a browser.
inline std::vector<BackgroundPageAction> PlanBackgroundPages(
    std::span<const int64_t> hidden_milliseconds, bool memory_pressure) {
  std::vector<BackgroundPageAction> actions;
  actions.reserve(hidden_milliseconds.size());
  for (size_t index = 0; index < hidden_milliseconds.size(); ++index) {
    auto action = BackgroundPageAction::kWarm;
    if (memory_pressure && index + 1 == hidden_milliseconds.size()) {
      action = BackgroundPageAction::kDiscard;
    } else if (index >= 12 && hidden_milliseconds[index] >= 120000) {
      // Recheck memory after one discard. Other cold pages remain frozen.
      action = !memory_pressure && hidden_milliseconds[index] >= 900000
                   ? BackgroundPageAction::kDiscard
                   : BackgroundPageAction::kFreeze;
    }
    actions.push_back(action);
  }
  return actions;
}

}  // namespace winmux
#endif  // CHROME_BROWSER_WINMUX_PAGE_LIFETIME_POLICY_H_
