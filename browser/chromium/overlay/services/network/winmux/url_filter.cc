#include "services/network/winmux/url_filter.h"

#include "components/winmux/blocking/engine.h"
#include "net/url_request/url_request.h"
#include "url/origin.h"

namespace network::winmux_filter {
namespace {
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

bool ShouldBlock(const net::URLRequest& request,
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
    return false;
  return winmux::ShouldBlockRequest(target, source, Type(destination), method);
}
}  // namespace network::winmux_filter
