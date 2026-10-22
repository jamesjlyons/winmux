#ifndef CHROME_BROWSER_WINMUX_UBLOCK_BRIDGE_H_
#define CHROME_BROWSER_WINMUX_UBLOCK_BRIDGE_H_
#include "url/gurl.h"
class Profile;
namespace content { class WebContents; }
namespace winmux {
inline constexpr char kUBlockId[] = "blockjmkbacgjkknlgpkjjiijinjdanf";
void RegisterUBlockAPI();
bool UBlockSiteEnabled(Profile* profile, const GURL& site);
// Direct tab lookup for inventory; falls back to the URL scan above.
bool UBlockSiteEnabledForTab(content::WebContents* contents);
int UBlockBlockedCount(content::WebContents* contents);
void SetUBlockSiteEnabled(content::WebContents* contents, bool enabled);
// Wakes the bundled extension's exchange in every loaded regular profile, for
// example after the saved filter-update consent changed.
void NotifyUBlockConfigurationChanged();
}
#endif
