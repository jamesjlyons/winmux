#ifndef CHROME_BROWSER_WINMUX_PAGE_LIFETIME_H_
#define CHROME_BROWSER_WINMUX_PAGE_LIFETIME_H_

#include <string>
namespace content { class WebContents; }
namespace winmux {
void SetWorkspacePageVisibility(content::WebContents* contents, bool managed, bool visible);
void ForgetWorkspacePage(const std::string& surface);
void StopWorkspacePageLifetime();
bool WorkspacePageKeepActive(content::WebContents* contents);
void SetWorkspacePageKeepActive(content::WebContents* contents, bool enabled);
std::string WorkspacePageLifecycle(content::WebContents* contents);
}
#endif
