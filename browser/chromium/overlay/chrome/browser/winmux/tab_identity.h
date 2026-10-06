#ifndef CHROME_BROWSER_WINMUX_TAB_IDENTITY_H_
#define CHROME_BROWSER_WINMUX_TAB_IDENTITY_H_

#include <map>
#include <string>

class PrefRegistrySimple;
class Profile;
namespace content { class WebContents; }

namespace winmux {
inline constexpr char kTabIdentityKey[] = "winmux.tab_uuid";
void RegisterWorkspaceProfilePrefs(PrefRegistrySimple* registry);
// Returns an existing regular-profile UUID without creating or changing it.
std::string ExistingProfileID(Profile* profile);
// Only a fresh, unassigned regular profile can acquire the requested identity.
// Existing profiles must already match; their identity is never overwritten.
bool InitializeWorkspaceProfileIdentity(Profile* profile, const std::string& uuid);
// Private tabs return empty and never enter session metadata or diagnostics.
std::string PersistentTabID(content::WebContents* contents);
std::string PersistentSurfaceID(content::WebContents* contents);
void RestoreTabIdentity(content::WebContents* contents,
                        const std::map<std::string, std::string>& extra_data);
}  // namespace winmux

#endif  // CHROME_BROWSER_WINMUX_TAB_IDENTITY_H_
