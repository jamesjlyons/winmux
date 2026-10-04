#ifndef SERVICES_NETWORK_WINMUX_URL_FILTER_H_
#define SERVICES_NETWORK_WINMUX_URL_FILTER_H_

#include <string_view>
#include "services/network/public/mojom/fetch_api.mojom.h"
#include "url/gurl.h"

namespace net { class URLRequest; }
namespace network::winmux_filter {
bool ShouldBlock(const net::URLRequest& request,
                 mojom::RequestDestination destination,
                 const GURL& target,
                 std::string_view method);
}
#endif
