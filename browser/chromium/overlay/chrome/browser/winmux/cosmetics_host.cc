#include "chrome/browser/winmux/cosmetics_host.h"

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/task/thread_pool.h"
#include "components/winmux/blocking/engine.h"
#include "content/public/browser/render_frame_host.h"

namespace winmux {
void CosmeticsHost::Create(content::RenderFrameHost* frame,
                           mojo::PendingReceiver<mojom::Cosmetics> receiver) {
  if (!frame->GetLastCommittedURL().SchemeIsHTTPOrHTTPS())
    return;
  new CosmeticsHost(*frame, std::move(receiver));
}

CosmeticsHost::CosmeticsHost(content::RenderFrameHost& frame,
                             mojo::PendingReceiver<mojom::Cosmetics> receiver)
    : DocumentService(frame, std::move(receiver)) {}

CosmeticsHost::~CosmeticsHost() = default;

void CosmeticsHost::GetSelectors(const std::string& tokens_json,
                                 GetSelectorsCallback callback) {
  // Bounds apply even to a compromised renderer. The document-scoped service
  // and weak callbacks prevent a stale result from crossing a navigation.
  if (in_flight_ || queries_ >= 64 || tokens_json.size() > 64 * 1024 ||
      !render_frame_host().GetLastCommittedURL().SchemeIsHTTPOrHTTPS()) {
    std::move(callback).Run("[]");
    return;
  }
  in_flight_ = true;
  ++queries_;
  Query(tokens_json, std::move(callback));
}

void CosmeticsHost::Query(std::string tokens_json, GetSelectorsCallback callback) {
  auto continuation = base::BindOnce(&CosmeticsHost::RunQuery,
                                     weak_factory_.GetWeakPtr(), tokens_json,
                                     std::move(callback));
  // SplitOnceCallback preserves ownership whether initialization defers or not.
  auto split = base::SplitOnceCallback(std::move(continuation));
  if (DeferUntilBlockingReady(std::move(split.first)))
    return;
  std::move(split.second).Run();
}

void CosmeticsHost::RunQuery(std::string tokens_json, GetSelectorsCallback callback) {
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&CosmeticSelectors, render_frame_host().GetLastCommittedURL(),
                     std::move(tokens_json)),
      base::BindOnce(&CosmeticsHost::Reply, weak_factory_.GetWeakPtr(), std::move(callback)));
}

void CosmeticsHost::Reply(GetSelectorsCallback callback, std::string selectors) {
  in_flight_ = false;
  if (selectors.size() > 256 * 1024)
    selectors = "[]";
  std::move(callback).Run(std::move(selectors));
}
}  // namespace winmux
