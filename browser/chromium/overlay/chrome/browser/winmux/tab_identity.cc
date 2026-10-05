#include "chrome/browser/winmux/tab_identity.h"

#include <set>
#include <utility>

#include "base/callback_list.h"
#include "base/command_line.h"
#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/supports_user_data.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/uuid.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "components/prefs/pref_registry_simple.h"
#include "components/prefs/pref_service.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/web_contents.h"

namespace winmux {
namespace {
constexpr char kProfileIdentityPref[] = "winmux.profile_uuid";
const char kIdentityDataKey = 0;
const char kPrivateProfileDataKey = 0;

class PrivateProfileIdentity final : public base::SupportsUserData::Data {
 public:
  const std::string id = base::Uuid::GenerateRandomV4().AsLowercaseString();
};

std::set<std::string>& LiveIDs() {
  static base::NoDestructor<std::set<std::string>> ids;
  return *ids;
}

std::string ProfileID(Profile* profile) {
  if (profile->IsOffTheRecord()) {
    auto* identity = static_cast<PrivateProfileIdentity*>(profile->GetUserData(&kPrivateProfileDataKey));
    if (!identity) {
      auto data = std::make_unique<PrivateProfileIdentity>();
      identity = data.get();
      profile->SetUserData(&kPrivateProfileDataKey, std::move(data));
    }
    return identity->id;
  }
  auto* prefs = profile->GetPrefs();
  auto id = base::Uuid::ParseCaseInsensitive(prefs->GetString(kProfileIdentityPref));
  if (!id.is_valid()) {
    id = base::Uuid::GenerateRandomV4();
    prefs->SetString(kProfileIdentityPref, id.AsLowercaseString());
  }
  return id.AsLowercaseString();
}

void ReportIdentity(Profile* profile, const std::string& id, bool restored) {
  auto path = base::CommandLine::ForCurrentProcess()->GetSwitchValuePath("winmux-tab-report");
  if (path.empty() || !path.IsAbsolute())
    return;
  base::DictValue record;
  record.Set("event", restored ? "restored" : "created");
  record.Set("surface_id", "browser:" + ProfileID(profile) + ":" + id);
  record.Set("private", false);
  auto json = base::WriteJson(record);
  if (!json)
    return;
  // No URL/title, private-tab data or UI-thread file IO. Explicit diagnostics
  // are opt-in; normal browsing does not write a second session store.
  static base::NoDestructor<scoped_refptr<base::SequencedTaskRunner>> writer(
      base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
           base::TaskShutdownBehavior::BLOCK_SHUTDOWN}));
  (*writer)->PostTask(FROM_HERE, base::BindOnce(
      [](base::FilePath output, std::string line) {
        base::File file(output, base::File::FLAG_OPEN_ALWAYS | base::File::FLAG_APPEND);
        if (file.IsValid())
          (void)file.WriteAtCurrentPos(base::as_byte_span(line));
      }, std::move(path), *json + "\n"));
}

class TabIdentity final : public base::SupportsUserData::Data {
 public:
  explicit TabIdentity(std::string requested) {
    auto parsed = base::Uuid::ParseCaseInsensitive(requested);
    if (parsed.is_valid() && !LiveIDs().contains(parsed.AsLowercaseString())) {
      id_ = parsed.AsLowercaseString();
      restored_ = true;
    } else {
      do {
        id_ = base::Uuid::GenerateRandomV4().AsLowercaseString();
      } while (LiveIDs().contains(id_));
    }
    LiveIDs().insert(id_);
  }
  ~TabIdentity() override { LiveIDs().erase(id_); }
  const std::string& id() const { return id_; }
  bool restored() const { return restored_; }

  void Observe(tabs::TabInterface* tab) {
    if (!tab)
      return;
    discard_subscription_ = tab->RegisterWillDiscardContents(base::BindRepeating(
        [](tabs::TabInterface*, content::WebContents* old_contents,
           content::WebContents* new_contents) {
          // Chromium retains the logical tab when discarding its WebContents.
          // Move our existing identity and subscription with that logical tab.
          auto identity = old_contents->TakeUserData(&kIdentityDataKey);
          if (identity)
            new_contents->SetUserData(&kIdentityDataKey, std::move(identity));
        }));
  }

 private:
  std::string id_;
  bool restored_ = false;
  base::CallbackListSubscription discard_subscription_;
};

TabIdentity* EnsureIdentity(content::WebContents* contents,
                            const std::string& requested = {}) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* value = static_cast<TabIdentity*>(contents->GetUserData(&kIdentityDataKey));
  if (!value) {
    auto data = std::make_unique<TabIdentity>(requested);
    value = data.get();
    contents->SetUserData(&kIdentityDataKey, std::move(data));
    // Establish the profile UUID even when diagnostics are disabled.
    auto* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
    ProfileID(profile);
    if (!profile->IsOffTheRecord())
      ReportIdentity(profile, value->id(), value->restored());
  }
  value->Observe(tabs::TabInterface::MaybeGetFromContents(contents));
  return value;
}
}  // namespace

void RegisterWorkspaceProfilePrefs(PrefRegistrySimple* registry) {
  registry->RegisterStringPref(kProfileIdentityPref, "");
}

std::string ExistingProfileID(Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile || !profile->IsRegularProfile())
    return {};
  const auto id = base::Uuid::ParseCaseInsensitive(
      profile->GetPrefs()->GetString(kProfileIdentityPref));
  return id.is_valid() ? id.AsLowercaseString() : std::string();
}

bool InitializeWorkspaceProfileIdentity(Profile* profile, const std::string& uuid) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const auto id = base::Uuid::ParseCaseInsensitive(uuid);
  if (!profile || !profile->IsRegularProfile() || !id.is_valid()) return false;
  const auto existing = profile->GetPrefs()->GetString(kProfileIdentityPref);
  if (existing.empty() && profile->IsNewProfile()) {
    profile->GetPrefs()->SetString(kProfileIdentityPref, id.AsLowercaseString());
  }
  return ExistingProfileID(profile) == id.AsLowercaseString();
}

std::string PersistentTabID(content::WebContents* contents) {
  // Private IDs are memory-only and must never enter Chromium session data.
  if (contents->GetBrowserContext()->IsOffTheRecord()) return {};
  auto* identity = EnsureIdentity(contents);
  return identity ? identity->id() : std::string();
}

std::string PersistentSurfaceID(content::WebContents* contents) {
  auto* identity = EnsureIdentity(contents);
  if (!identity)
    return {};
  auto* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  return "browser:" + ProfileID(profile) + ":" + identity->id();
}

void RestoreTabIdentity(content::WebContents* contents,
                        const std::map<std::string, std::string>& extra_data) {
  if (contents->GetBrowserContext()->IsOffTheRecord()) return;
  auto found = extra_data.find(kTabIdentityKey);
  EnsureIdentity(contents, found == extra_data.end() ? std::string() : found->second);
}
}  // namespace winmux
