#include "services/network/winmux/url_filter.h"

#include "components/winmux/blocking/engine.h"
#include "net/url_request/url_request.h"
#include "url/origin.h"
#include "net/base/schemeful_site.h"
#include "base/no_destructor.h"
#include <map>
#include <set>

namespace network::winmux_filter {
namespace {
struct Context { std::set<std::string> disabled; std::map<std::string, uint64_t> counts; };
auto& Contexts() { static base::NoDestructor<std::map<const net::URLRequestContext*, Context>> contexts; return *contexts; }
std::string_view Type(mojom::RequestDestination destination) {
  using D = mojom::RequestDestination;
  switch (destination) {
    case D::kDocument: return "document";
    case D::kFrame:
    case D::kIframe:
    case D::kFencedframe: return "subdocument";
    case D::kImage: return "image";
    case D::kStyle:
    case D::kXslt: return "stylesheet";
    case D::kFont: return "font";
    case D::kScript:
    case D::kWorker:
    case D::kSharedWorker:
    case D::kServiceWorker:
    case D::kAudioWorklet:
    case D::kPaintWorklet: return "script";
    case D::kAudio:
    case D::kVideo:
    case D::kTrack: return "media";
    case D::kObject:
    case D::kEmbed: return "object";
    case D::kEmpty: return "xmlhttprequest";
    default: return "other";
  }
}
}  // namespace

winmux::RequestDecision Check(const net::URLRequest& request,
                 mojom::RequestDestination destination,
                 const GURL& target,
                 std::string_view method) {
  // This URLRequest has already been configured from the validated loader
  // factory and browser isolation context. No page-supplied source URL API.
  GURL source;
  if (request.initiator() && !request.initiator()->opaque())
    source = request.initiator()->GetURL();
  else if (request.isolation_info().top_frame_origin() &&
           !request.isolation_info().top_frame_origin()->opaque())
    source = request.isolation_info().top_frame_origin()->GetURL();
  else if (destination == mojom::RequestDestination::kDocument)
    source = target;
  if (!source.SchemeIsHTTPOrHTTPS())
    return {};
  GURL top = source;
  if (request.isolation_info().top_frame_origin() && !request.isolation_info().top_frame_origin()->opaque())
    top = request.isolation_info().top_frame_origin()->GetURL();
  if (destination == mojom::RequestDestination::kDocument) top = target;
  const auto site = net::SchemefulSite(top).Serialize();
  auto& context = Contexts()[request.context()];
  if (context.disabled.contains(site)) return {};
  auto decision = winmux::CheckRequest(target, source, Type(destination), method);
  if (decision.blocked) {
    if (context.counts.size() >= 1024 && !context.counts.contains(site)) context.counts.erase(context.counts.begin());
    auto& count = context.counts[site]; if (count < uint64_t{2147483647}) ++count;
  }
  return decision;
}
bool ShouldBlock(const net::URLRequest& request, mojom::RequestDestination destination, const GURL& target, std::string_view method) {
  return Check(request, destination, target, method).blocked;
}
void SetDisabledSites(const net::URLRequestContext* context, const std::vector<std::string>& sites) {
  auto& state = Contexts()[context]; state.disabled.clear();
  for (const auto& site : sites) {
    if (state.disabled.size() >= 1024) break;
    if (GURL(site).SchemeIsHTTPOrHTTPS()) state.disabled.insert(net::SchemefulSite(GURL(site)).Serialize());
  }
}
void ForgetContext(const net::URLRequestContext* context) { Contexts().erase(context); }
uint64_t BlockedCount(const net::URLRequestContext* context, const GURL& site) {
  auto found = Contexts().find(context); if (found == Contexts().end()) return 0;
  auto count = found->second.counts.find(net::SchemefulSite(site).Serialize());
  return count == found->second.counts.end() ? 0 : count->second;
}
}  // namespace network::winmux_filter
