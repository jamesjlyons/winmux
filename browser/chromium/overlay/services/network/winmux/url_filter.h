#ifndef SERVICES_NETWORK_WINMUX_URL_FILTER_H_
#define SERVICES_NETWORK_WINMUX_URL_FILTER_H_

#include <string_view>
#include <string>
#include <vector>
#include <cstdint>
#include "components/winmux/blocking/engine.h"
#include "services/network/public/mojom/fetch_api.mojom.h"
#include "url/gurl.h"

namespace net { class URLRequest; class URLRequestContext; }
namespace network::winmux_filter {
void SetDisabledSites(const net::URLRequestContext* context, const std::vector<std::string>& sites);
void ForgetContext(const net::URLRequestContext* context);
uint64_t BlockedCount(const net::URLRequestContext* context, const GURL& site);
winmux::RequestDecision Check(const net::URLRequest& request, mojom::RequestDestination destination,
                             const GURL& target, std::string_view method);
bool ShouldBlock(const net::URLRequest& request,
                 mojom::RequestDestination destination,
                 const GURL& target,
                 std::string_view method);
}
#endif
