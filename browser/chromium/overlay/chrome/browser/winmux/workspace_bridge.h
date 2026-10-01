#ifndef CHROME_BROWSER_WINMUX_WORKSPACE_BRIDGE_H_
#define CHROME_BROWSER_WINMUX_WORKSPACE_BRIDGE_H_

namespace winmux {
// M0 only: authenticate the packaged helper without taking native-window
// ownership or replacing the browser's normal controls.
void StartWorkspaceBridge();
}  // namespace winmux

#endif  // CHROME_BROWSER_WINMUX_WORKSPACE_BRIDGE_H_
