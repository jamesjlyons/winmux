#ifndef CHROME_RENDERER_WINMUX_COSMETICS_AGENT_H_
#define CHROME_RENDERER_WINMUX_COSMETICS_AGENT_H_

#include "base/memory/weak_ptr.h"
#include "components/winmux/blocking/cosmetics.mojom.h"
#include "content/public/renderer/render_frame_observer.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "third_party/blink/public/common/tokens/tokens.h"

namespace winmux {
class CosmeticsAgent : public content::RenderFrameObserver {
 public:
  explicit CosmeticsAgent(content::RenderFrame* frame);
  ~CosmeticsAgent() override;
  void DidDispatchDOMContentLoadedEvent() override;
  void DidCreateNewDocument() override;
  void OnDestruct() override;

 private:
  void Apply(blink::DocumentToken document_token, const std::string& selectors);
  mojo::Remote<mojom::Cosmetics> host_;
  base::WeakPtrFactory<CosmeticsAgent> weak_factory_{this};
};
}  // namespace winmux
#endif
