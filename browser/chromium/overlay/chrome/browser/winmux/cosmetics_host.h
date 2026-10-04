#ifndef CHROME_BROWSER_WINMUX_COSMETICS_HOST_H_
#define CHROME_BROWSER_WINMUX_COSMETICS_HOST_H_

#include "base/memory/weak_ptr.h"
#include "components/winmux/blocking/cosmetics.mojom.h"
#include "content/public/browser/document_service.h"

namespace winmux {
class CosmeticsHost : public content::DocumentService<mojom::Cosmetics> {
 public:
  static void Create(content::RenderFrameHost* frame,
                     mojo::PendingReceiver<mojom::Cosmetics> receiver);
  void GetSelectors(const std::string& tokens_json,
                    GetSelectorsCallback callback) override;

 private:
  CosmeticsHost(content::RenderFrameHost& frame,
                mojo::PendingReceiver<mojom::Cosmetics> receiver);
  ~CosmeticsHost() override;
  void Query(std::string tokens_json, GetSelectorsCallback callback);
  void RunQuery(std::string tokens_json, GetSelectorsCallback callback);
  void Reply(GetSelectorsCallback callback, std::string selectors);
  bool in_flight_ = false;
  size_t queries_ = 0;
  base::WeakPtrFactory<CosmeticsHost> weak_factory_{this};
};
}  // namespace winmux
#endif
