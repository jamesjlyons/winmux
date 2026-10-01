#ifndef COMPONENTS_WINMUX_BLOCKING_ENGINE_H_
#define COMPONENTS_WINMUX_BLOCKING_ENGINE_H_

#include <string>
#include <string_view>

#include "base/functional/callback.h"
#include "url/gurl.h"

namespace winmux {
// Returns true when deferred. The callback is posted back to the caller's
// sequence after background initialization, including initialization failure.
bool DeferUntilBlockingReady(base::OnceClosure resume);

// Call only after readiness, on the native network sequence. No disk or IPC.
bool ShouldBlockRequest(const GURL& url,
                        const GURL& initiator,
                        std::string_view type,
                        std::string_view method);

// Background-only cosmetic query. Produces declarative selectors, never script.
std::string CosmeticSelectors(const GURL& url, std::string_view tokens_json);
}  // namespace winmux

#endif
