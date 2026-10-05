# Workspace Setup

The staged alpha's application menu contains **Workspace Setup…**. Opening it
does not enroll a helper or begin managing windows. Keep the staged package in a
stable location while its workspace is active.

Double-clicking the Views Trial starts its workspace automatically, using setup
to request missing permissions. Its empty launcher does not open an ordinary
Chromium window or contact the workspace service. If the workspace is already
ready, setup opens the managed browser. Opening the setup menu manually does
not start a stopped workspace.

1. Quit standalone WinMux if it is running. Setup refuses to start alongside it;
   it does not quit another manager for you.
2. Choose **Start Workspace**. Setup requests Accessibility and shows a direct
   Settings button until it is granted. It continues the explicit start request
   once permission is available; Cancel Start or closing setup cancels that
   pending request. Allow WinMux Workspace in macOS Login Items if requested.
3. A separate browser profile opens after the helper is ready. The sidebar can
   combine its browser tabs and native windows. Existing browser sessions remain
   separate. This profile starts without importing accounts or extensions.
4. Use **Option–J / K** to select the next/previous item and **Option–Space** to
   change horizontal/vertical layout. These defaults are written only when the
   workspace configuration is first created. Shared structural commands are
   documented in [surface commands](surface-commands.md).
5. Choose **Stop Workspace** to unregister the managed helper. It flushes saved
   placement and restores native windows. Chromium releases hidden managed hosts
   on disconnect and keeps its ordinary browser controls available. The browser
   stays open; quitting it is a separate action. Standalone WinMux can then be
   reopened with its original configuration and session.

The separate data root is
`~/Library/Application Support/WinMux Browser Workspace Alpha`. Normal usage
stores its profile in `daily/browser-profile` and its native configuration and
session in `daily/native-state`. Its command socket uses the existing state-path
hash under `/tmp`; the standalone CLI endpoint is not replaced. No original
profile, config or session is copied, reset or migrated by Setup.

New Views Trial workspaces use `WinMux Browser Views Trial Workspace` under
Application Support. Existing marked workspaces retain their legacy
`WinMux Browser Views Trial` directory. The launcher's default Chromium
directory is separate, preventing an unmanaged browser launch from blocking
workspace activation. Unmarked older browser directories are never adopted or
deleted; malformed existing activation state still fails validation.

The managed service is
`com.jameslyons.winmux.browser.alpha.workspace.managed`, registered through
`SMAppService` by the signed embedded helper application. The existing
transport-only helper registration has a different service name and remains
untouched. Ordinary non-trial Chromium launches continue to use that transport service.
Only the separate profile launched by Setup uses the managed service.
Registration remains active until Stop Workspace; macOS can start the registered
agent again at login. Quit the browser independently when desired. To disable
workspace management across logins, use Stop Workspace.

An active workspace is bound to the exact staged package path. Stop it from that
package before activating another build. A second Setup window cannot race an
activation or rollback operation. The native ownership lease and checks before
and after Accessibility approval remain in force; launching standalone WinMux
causes the alpha to relinquish native management.

## Isolated validation

Launch the signed embedded helper executable with
`--workspace-setup --fixture-process <PID>` only after launching and verifying the
synthetic `com.jameslyons.winmux.browser.native-fixture` app. This opens the same
Setup interface with a **Fixture Validation** title. It uses the same
SMAppService flow with a uniquely named `.workspace.test.<UUID>` agent bundled
and signed for each staging package. It saves a launch-bound fixture PID and a
fresh validation UUID. The production managed service is not enrolled by this
test. The helper rejects a dead or reused PID. Validation requests cannot omit
the process scope or fall back to all native apps.

Validation profiles/state live under `validation/<UUID>` in the marked data
root. Start/Stop must be tested here before trying the unscoped daily workspace.
Do not activate the normal daily workspace as a test. A stopped validation
request is retained as diagnostic state; it does not activate itself when Setup
is next opened.

Physical keyboard delivery, display transitions, fullscreen/popups and full
daily-workload qualification remain separate from setup/rollback validation.
