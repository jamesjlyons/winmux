#include "chrome/browser/winmux/filter_updates.h"

#include <algorithm>
#include <utility>
#include <memory>
#include <optional>
#include <string>
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/task/thread_pool.h"
#include "base/timer/timer.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/common/chrome_paths.h"
#include "components/winmux/blocking/engine.h"
#include "content/public/browser/storage_partition.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/network_context.mojom.h"

namespace winmux {
namespace {
// DownloadToString DCHECKs if its requested limit exceeds this API maximum,
// before receiving any response. Use the API's bound for each complete list.
constexpr size_t kMaxList = network::SimpleURLLoader::kMaxBoundedStringDownloadSize;
constexpr size_t kMaxCombinedLists = 2 * (kMaxList + 1);
constexpr net::NetworkTrafficAnnotationTag kTraffic = net::DefineNetworkTrafficAnnotation("winmux_filter_updates", R"(
  semantics {
    sender: "WinMux filter updater"
    description: "Downloads EasyList and EasyPrivacy after explicit permission."
    trigger: "At most once daily while filter updates are enabled."
    data: "No browsing history, page URL, cookies, or identifiers."
    destination: WEBSITE
  }
  policy {
    cookies_allowed: NO
    setting: "Disabled by default; enabled in Workspace Setup or Privacy Settings."
    policy_exception_justification: "User-controlled optional browser feature."
  })");

void Broadcast(const std::string& rules) {
  if (!g_browser_process || !g_browser_process->profile_manager()) return;
  for (auto* profile : g_browser_process->profile_manager()->GetLoadedProfiles()) {
    profile->ForEachLoadedStoragePartition([&](content::StoragePartition* partition) {
      // Each process compiles before swapping; a failed compilation retains its
      // previous immutable snapshot and never changes site exceptions.
      partition->GetNetworkContext()->SetWinMuxBlockingRules(rules, base::DoNothing());
    });
  }
}
struct Cached { std::string current; std::string previous; base::Time modified; };
class Updater {
 public:
  void Start(Profile* profile, bool permitted) {
    if (started_) {
      permitted_ = permitted;
      if (!permitted) { loader_.reset(); timer_.Stop(); }
      else if (!loader_ && !timer_.IsRunning()) timer_.Start(FROM_HERE, base::Days(1), this, &Updater::Download);
      return;
    }
    started_ = true; permitted_ = permitted;
    factory_ = profile->GetDefaultStoragePartition()->GetURLLoaderFactoryForBrowserProcess();
    if (!base::PathService::Get(chrome::DIR_USER_DATA, &directory_)) return;
    cache_ = directory_.AppendASCII("winmux-filters.txt");
    base::ThreadPool::PostTaskAndReplyWithResult(FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
        base::BindOnce([](base::FilePath path) {
          Cached cache;
          if (!base::ReadFileToStringWithMaxSize(path, &cache.current, kMaxCombinedLists)) cache.current.clear();
          if (!base::ReadFileToStringWithMaxSize(path.AddExtensionASCII("previous"), &cache.previous, kMaxCombinedLists)) cache.previous.clear();
          base::File::Info info; if (base::GetFileInfo(path, &info)) cache.modified = info.last_modified;
          return cache;
        }, cache_), base::BindOnce(&Updater::Loaded, base::Unretained(this)));
  }
 private:
  void Loaded(Cached cache) {
    const auto delay = std::clamp(base::Days(1) - (base::Time::Now() - cache.modified), base::Seconds(0), base::Days(1));
    if (permitted_) timer_.Start(FROM_HERE, delay, this, &Updater::Download);
    if (cache.current.empty()) { RestorePrevious(std::move(cache.previous)); return; }
    auto current = cache.current;
    ReplaceBlockingRules(std::move(current), base::BindOnce(
        [](Updater* self, Cached cache, bool ok) {
          if (ok) Broadcast(cache.current); else self->RestorePrevious(std::move(cache.previous));
        }, base::Unretained(this), std::move(cache)));
  }
  void RestorePrevious(std::string rules) {
    if (rules.empty()) return;
    auto copy = rules;
    ReplaceBlockingRules(std::move(copy), base::BindOnce([](std::string rules, bool ok) { if (ok) Broadcast(rules); }, std::move(rules)));
  }
  void Download() {
    part_ = 0; combined_.clear(); Fetch();
  }
  void Fetch() {
    auto request = std::make_unique<network::ResourceRequest>();
    request->url = GURL(part_ == 0 ? "https://easylist.to/easylist/easylist.txt" : "https://easylist.to/easylist/easyprivacy.txt");
    request->credentials_mode = network::mojom::CredentialsMode::kOmit;
    request->redirect_mode = network::mojom::RedirectMode::kError;
    loader_ = network::SimpleURLLoader::Create(std::move(request), kTraffic);
    loader_->SetTimeoutDuration(base::Seconds(30));
    loader_->DownloadToString(factory_.get(), base::BindOnce(&Updater::Downloaded, base::Unretained(this)), kMaxList);
  }
  void Downloaded(std::optional<std::string> body) {
    loader_.reset();
    if (!permitted_) return;
    // Fixed HTTPS endpoints, bounded complete payloads, no HTML/error pages or
    // executable resources. The bundled engine remains available offline.
    if (!body || !body->starts_with("[Adblock") || body->size() < 1024) { Reschedule(); return; }
    combined_ += *body + "\n";
    if (++part_ == 1) { Fetch(); return; }
    auto rules = std::exchange(combined_, {});
    auto previous = CurrentBlockingRules();
    auto candidate = rules;
    ReplaceBlockingRules(std::move(candidate), base::BindOnce(
        [](Updater* self, std::string rules, std::string previous, bool accepted) {
          if (accepted) {
            Broadcast(rules);
            base::ThreadPool::PostTask(FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT, base::TaskShutdownBehavior::BLOCK_SHUTDOWN},
                base::BindOnce([](base::FilePath path, std::string rules, std::string previous) {
                  if (!previous.empty() && !base::ImportantFileWriter::WriteFileAtomically(path.AddExtensionASCII("previous"), previous)) return;
                  base::ImportantFileWriter::WriteFileAtomically(path, rules);
                }, self->cache_, std::move(rules), std::move(previous)));
          }
          self->Reschedule();
        }, base::Unretained(this), std::move(rules), std::move(previous)));
  }
  void Reschedule() { if (permitted_) timer_.Start(FROM_HERE, base::Days(1), this, &Updater::Download); }
  bool started_ = false, permitted_ = false;
  int part_ = 0;
  std::string combined_;
  base::FilePath directory_, cache_;
  scoped_refptr<network::SharedURLLoaderFactory> factory_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  base::OneShotTimer timer_;
};
}
void StartFilterUpdates(Profile* profile, bool permitted) {
  static base::NoDestructor<Updater> updater;
  updater->Start(profile, permitted);
}
}
