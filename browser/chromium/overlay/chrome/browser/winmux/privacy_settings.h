#ifndef CHROME_BROWSER_WINMUX_PRIVACY_SETTINGS_H_
#define CHROME_BROWSER_WINMUX_PRIVACY_SETTINGS_H_
#include <string>
#include "base/values.h"
#include "base/functional/callback.h"
#include "url/gurl.h"
class Profile;
class PrefRegistrySimple;
namespace content { class WebContents; }
namespace winmux {
void PreparePrivacyStartup();
void ApplyPrivacyProfile(Profile* profile);
bool WorkspaceSiteBlockingEnabled(Profile* profile, const GURL& site);
int WorkspaceBlockedCount(content::WebContents* contents);
void SetWorkspaceSiteBlocking(content::WebContents* contents, bool enabled);
GURL WorkspaceSearch(Profile* profile, const std::string& text);
base::DictValue WorkspacePrivacyState(Profile* profile);
void UpdateWorkspacePrivacy(Profile* profile, const std::string& json, base::OnceCallback<void(std::string)> completion);
}
#endif
