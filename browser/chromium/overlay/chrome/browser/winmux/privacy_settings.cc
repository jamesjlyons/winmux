#include "chrome/browser/winmux/privacy_settings.h"
#include "chrome/browser/winmux/filter_updates.h"

#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/search_engines/template_url_service_factory.h"
#include "components/search_engines/template_url_service.h"
#include "components/search_engines/template_url.h"
#include "components/search_engines/template_url_data.h"
#include "components/search_engines/template_url_data_util.h"
#include "components/search_engines/default_search_manager.h"
#include "base/task/thread_pool.h"
#include "base/task/sequenced_task_runner.h"
#include "base/supports_user_data.h"
#include "base/time/time.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "chrome/browser/winmux/browser_inventory.h"
#include "base/functional/bind.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/chrome_paths.h"
#include "components/prefs/pref_registry_simple.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "content/public/browser/web_contents.h"
#include "net/base/schemeful_site.h"

namespace winmux {
namespace {
constexpr char kDisabledSites[] = "winmux.blocking_disabled_sites";
constexpr char kSearchTemplate[] = "winmux.search_template";
base::FilePath& ConsentPath() { static base::NoDestructor<base::FilePath> path; return *path; }
base::DictValue& Consent() { static base::NoDestructor<base::DictValue> consent; return *consent; }
bool Allowed(std::string_view name) { return Consent().FindBool(name).value_or(false); }
}

void PreparePrivacyStartup() {
  auto* command = base::CommandLine::ForCurrentProcess();
  auto path = command->GetSwitchValuePath("user-data-dir");
  if (path.empty()) base::PathService::Get(chrome::DIR_USER_DATA, &path);
  if (!path.empty()) {
    ConsentPath() = path.AppendASCII("winmux-services.json");
    std::string bytes;
    if (base::ReadFileToStringWithMaxSize(ConsentPath(), &bytes, 8192)) {
      auto value = base::JSONReader::ReadDict(bytes, base::JSON_PARSE_RFC);
      if (value && value->size() == 4 && value->FindInt("version") == 1 &&
          value->FindBool("security_updates") && value->FindBool("extension_updates") &&
          value->FindBool("filter_updates")) Consent() = std::move(*value);
    }
  }
  // Apply before service construction, for direct launches as well as Setup.
  for (const char* name : {"metrics-recording-only", "disable-breakpad", "disable-domain-reliability", "disable-sync", "disable-background-networking"}) command->AppendSwitch(name);
  if (!Allowed("security_updates")) {
    command->AppendSwitch("disable-component-update");
    command->AppendSwitch("disable-client-side-phishing-detection");
  }
  if (!Allowed("extension_updates")) command->AppendSwitch("winmux-disable-extension-updates");
}

void ApplyPrivacyProfile(Profile* profile) {
  if (!profile || !profile->IsRegularProfile()) return;
  auto* prefs = profile->GetPrefs();
  prefs->SetBoolean("search.suggest_enabled", false);
  prefs->SetInteger("net.network_prediction_options", 2);
  prefs->SetBoolean("safebrowsing.enhanced", false);
  if (!Allowed("security_updates")) prefs->SetBoolean("safebrowsing.enabled", false);
  StartFilterUpdates(profile, Allowed("filter_updates"));
}

bool WorkspaceSiteBlockingEnabled(Profile* profile, const GURL& site) {
  return !profile->GetPrefs()->GetList(kDisabledSites).contains(net::SchemefulSite(site).Serialize());
}
void SetWorkspaceSiteBlocking(content::WebContents* contents, bool enabled) {
  const auto& site = contents->GetLastCommittedURL();
  if (!site.SchemeIsHTTPOrHTTPS()) return;
  auto* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  {
  ScopedListPrefUpdate update(profile->GetPrefs(), kDisabledSites);
  const auto key = net::SchemefulSite(site).Serialize();
  update->EraseValue(base::Value(key));
  if (!enabled && update->size() < 1024) update->Append(key);
  }
  std::vector<std::string> sites;
  for (const auto& entry : profile->GetPrefs()->GetList(kDisabledSites)) if (entry.is_string()) sites.push_back(entry.GetString());
  profile->ForEachLoadedStoragePartition([&](content::StoragePartition* partition) {
    partition->GetNetworkContext()->SetWinMuxBlockingSettings(sites);
  });
}
int WorkspaceBlockedCount(content::WebContents* contents) {
  static const char key = 0;
  struct Counter : base::SupportsUserData::Data {
    int count = 0;
    bool pending = false;
    base::TimeTicks requested;
    GURL site;
  };
  auto* counter = static_cast<Counter*>(contents->GetUserData(&key));
  if (!counter) { auto data = std::make_unique<Counter>(); counter = data.get(); contents->SetUserData(&key, std::move(data)); }
  const auto site = contents->GetLastCommittedURL();
  if (counter->site != site) { counter->site = site; counter->count = 0; }
  if (site.SchemeIsHTTPOrHTTPS() && !counter->pending && base::TimeTicks::Now() - counter->requested > base::Seconds(1)) {
    counter->requested = base::TimeTicks::Now(); counter->pending = true;
    contents->GetPrimaryMainFrame()->GetStoragePartition()->GetNetworkContext()->GetWinMuxBlockedCount(site,
        base::BindOnce([](base::WeakPtr<content::WebContents> contents, GURL site, uint64_t count) {
          if (!contents) return;
          auto* counter = static_cast<Counter*>(contents->GetUserData(&key));
          if (!counter) return;
          counter->pending = false;
          if (counter->site == site && counter->count != static_cast<int>(count)) {
            counter->count = static_cast<int>(std::min(count, uint64_t{2147483647})); RefreshBrowserInventory();
          }
        }, contents->GetWeakPtr(), site));
  }
  return counter->count;
}
GURL WorkspaceSearch(Profile* profile, const std::string& text) {
  auto* service = TemplateURLServiceFactory::GetForProfile(profile);
  return service ? service->GenerateSearchURLForDefaultSearchProvider(base::UTF8ToUTF16(text)) : GURL();
}
base::DictValue WorkspacePrivacyState(Profile* profile) {
  auto result = Consent().Clone();
  result.Set("version", 1);
  for (const char* key : {"security_updates", "extension_updates", "filter_updates"}) result.Set(key, Allowed(key));
  auto* service = TemplateURLServiceFactory::GetForProfile(profile);
  const auto* provider = service ? service->GetDefaultSearchProvider() : nullptr;
  result.Set("search_template", provider ? provider->url() : profile->GetPrefs()->GetString(kSearchTemplate));
  result.Set("third_party_cookies_blocked", profile->GetPrefs()->GetInteger("profile.cookie_controls_mode") == 1);
  return result;
}
void UpdateWorkspacePrivacy(Profile* profile, const std::string& json, base::OnceCallback<void(std::string)> completion) {
  auto value = base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
  if (!value || value->size() != 5) { std::move(completion).Run("invalid_request"); return; }
  const auto* pattern = value->FindString("search_template");
  auto cookies = value->FindBool("third_party_cookies_blocked");
  auto* service = TemplateURLServiceFactory::GetForProfile(profile);
  const auto* provider = service ? service->GetDefaultSearchProvider() : nullptr;
  const bool unchanged_search = pattern && provider && *pattern == provider->url();
  if (!pattern || pattern->size() > 2048 || pattern->find("{searchTerms}") == std::string::npos ||
      (!unchanged_search && (!GURL(*pattern).is_valid() || !GURL(*pattern).SchemeIsHTTPOrHTTPS())) || !cookies) { std::move(completion).Run("invalid_request"); return; }
  for (const char* key : {"security_updates", "extension_updates", "filter_updates"}) {
    auto enabled = value->FindBool(key);
    if (!enabled) { std::move(completion).Run("invalid_request"); return; }
  }
  auto consent = Consent().Clone();
  for (const char* key : {"security_updates", "extension_updates", "filter_updates"}) consent.Set(key, *value->FindBool(key));
  consent.Set("version", 1);
  auto serialized = base::WriteJson(consent);
  if (!serialized || ConsentPath().empty()) { std::move(completion).Run("invalid_request"); return; }
  // Serialize consent writes off the UI thread. Acknowledgement follows the
  // atomic write, so failure leaves both the displayed and durable state intact.
  static base::NoDestructor<scoped_refptr<base::SequencedTaskRunner>> writer(
      base::ThreadPool::CreateSequencedTaskRunner({base::MayBlock(), base::TaskPriority::USER_VISIBLE,
                                                  base::TaskShutdownBehavior::BLOCK_SHUTDOWN}));
  (*writer)->PostTaskAndReplyWithResult(FROM_HERE,
      base::BindOnce([](base::FilePath path, std::string bytes) {
        return base::ImportantFileWriter::WriteFileAtomically(path, bytes);
      }, ConsentPath(), *serialized),
      base::BindOnce([](base::WeakPtr<Profile> profile, base::DictValue consent, std::string pattern,
                       bool cookies, bool unchanged_search, base::OnceCallback<void(std::string)> completion, bool saved) {
        if (!saved || !profile) { std::move(completion).Run("unavailable"); return; }
        Consent() = std::move(consent);
        StartFilterUpdates(profile.get(), Allowed("filter_updates"));
        if (!unchanged_search) {
          profile->GetPrefs()->SetString(kSearchTemplate, pattern);
          TemplateURLData search;
          search.SetShortName(base::UTF8ToUTF16(GURL(pattern).host()));
          search.SetKeyword(base::UTF8ToUTF16(GURL(pattern).host()));
          search.SetURL(pattern);
          profile->GetPrefs()->SetDict(DefaultSearchManager::kDefaultSearchProviderDataPrefName, TemplateURLDataToDictionary(search));
        }
        profile->GetPrefs()->SetInteger("profile.cookie_controls_mode", cookies ? 1 : 0);
        std::move(completion).Run("issued");
      }, profile->GetWeakPtr(), std::move(consent), *pattern, *cookies, unchanged_search, std::move(completion)));
}
}
