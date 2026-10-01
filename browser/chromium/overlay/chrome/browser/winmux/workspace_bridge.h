#ifndef CHROME_BROWSER_WINMUX_WORKSPACE_BRIDGE_H_
#define CHROME_BROWSER_WINMUX_WORKSPACE_BRIDGE_H_

namespace winmux {
// Authenticate the packaged helper and publish browser-owned tab state. Normal
// browser controls remain available while native workspace UI is integrated.
void StartWorkspaceBridge();
void StopWorkspaceBridge();
}  // namespace winmux

#endif  // CHROME_BROWSER_WINMUX_WORKSPACE_BRIDGE_H_
