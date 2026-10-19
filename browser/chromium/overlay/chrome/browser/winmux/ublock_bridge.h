#ifndef CHROME_BROWSER_WINMUX_UBLOCK_BRIDGE_H_
#define CHROME_BROWSER_WINMUX_UBLOCK_BRIDGE_H_
#include "url/gurl.h"
class Profile;
namespace content { class WebContents; }
namespace winmux {
inline constexpr char kUBlockId[] = "blockjmkbacgjkknlgpkjjiijinjdanf";
void RegisterUBlockAPI();
bool UBlockSiteEnabled(Profile* profile, const GURL& site);
int UBlockBlockedCount(content::WebContents* contents);
void SetUBlockSiteEnabled(content::WebContents* contents, bool enabled);
}
#endif
