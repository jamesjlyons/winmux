#include "components/winmux/blocking/engine.h"

#include <utility>

namespace winmux {
// Compatibility entry points for the existing network/renderer patch layer.
// The bundled uBlock component is the only active filter engine. Keeping these
// inert avoids double blocking and preserves old profile data for rollback.
bool DeferUntilBlockingReady(base::OnceClosure) { return false; }
void ReplaceBlockingRules(std::string, base::OnceCallback<void(bool)> completion) {
  std::move(completion).Run(false);
}
std::string CurrentBlockingRules() { return {}; }
RequestDecision CheckRequest(const GURL&, const GURL&, std::string_view, std::string_view) {
  return {};
}
bool ShouldBlockRequest(const GURL&, const GURL&, std::string_view, std::string_view) {
  return false;
}
std::string CosmeticSelectors(const GURL&, std::string_view) { return "[]"; }
}  // namespace winmux
