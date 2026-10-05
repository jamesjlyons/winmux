# WinMux Views Trial: Incognito Spaces — October 5, 2026

This trial uses the new tab-style model: each ordinary app window or browser tab
starts in its own view and fills the usable desktop. Splits and stacks appear
when you explicitly combine views. Each Space has its own Pinned area. Website
favicons follow the current page, including the selected member of a stack.

Private windows create a temporary **Incognito** Space for their off-the-record
browser session. Private pages have purple window chrome and an eye-slash icon;
the Space is marked temporary and its new-tab button opens a **New Private Tab**.
Private sessions from different browser profiles use separate temporary Spaces.
Closing the last private tab removes its Space and returns to a regular Space.
Private tabs cannot be pinned or sent into regular Spaces, and regular tabs and
apps cannot be sent into Incognito. Private tabs, group arrangements, selections,
and Space metadata are excluded from saved workspace state. Reopening the trial
does not restore a closed private session.

Used groups disappear when their last item closes or moves away. A completely
empty Space retains one blank view. Deliberately created, unused named groups,
configured persistent groups, and groups containing minimized windows remain.

The profile update adds named browser profiles that can be reused across Spaces.
Use **Space → Manage Space → Browser Profile → New Profile…**, enter a name such
as Work or Personal, then open a new tab. Other Spaces can select that same name,
choose a different profile, or use **Shared**.

Each named profile has Chromium's own history, cookies, site storage, extensions,
settings, and saved-password database. Spaces that choose the same profile share
that data. Shared uses the trial's original browser profile. New tabs from the
sidebar, page-toolbar **+**, and **Option–Command–T** use the Space's choice.
Startup bypasses Chromium's profile chooser, including when several named
profiles exist. Saved tabs restore under their original profiles; new tabs use
the active Space's profile without an additional profile-selection screen.
Pages opened by a website or Chromium's own commands retain their source browser
profile. Existing tabs and
pins keep their original profile when a Space's setting changes. Sending a tab,
pin, or group to another Space uses the destination profile: if it differs, the
current page reopens there, then the original is asked to close. Login state,
back/forward history, and unsaved page contents are not copied. A closed pin
opens in the destination profile when moved. Same-profile moves preserve the
live tab. Failed reopens leave the originals in place; groups wait for all
replacement tabs before moving. Deleting a Space keeps the reusable
profile and its data. Profiles are local to this trial installation and aren't
imported from another browser or the daily alpha.

The download is a complete application for **Apple Silicon Macs (M1 or newer)**.
No source checkout, compiler, Python installation, or signing certificate is
needed. The binaries require macOS 13 or newer; runtime testing on this machine
uses macOS 27.0.1. Other Mac and OS combinations remain to be tested.

## Install and start

1. Download the trial ZIP, `INSTALL.md`, `trial-manifest.json`, and `SHA256SUMS`
   from the latest **WinMux Views Trial** draft on the repository's
   [Releases page](https://github.com/jamesjlyons/winmux/releases). Sign into the
   GitHub account that can access the draft releases.
2. In Terminal, open the download folder and run `shasum -a 256 -c SHA256SUMS`.
   The three listed files should report `OK`.
3. If another WinMux workspace is running, use its **Workspace Setup… → Stop
   Workspace**, then quit that browser and standalone WinMux.
4. Extract the ZIP and copy **WinMux Browser Views Trial.app** into
   **Applications**. Keep the existing alpha app for returning to it later.
5. Open **WinMux Browser Views Trial**. This personal trial uses an Apple
   Development signature and is not notarized. If macOS asks for approval, use
   the app-specific **Privacy & Security → Open Anyway** flow described in
   [Apple's instructions](https://support.apple.com/en-us/102445). If a signature
   or damaged-app error persists, keep the exact error for diagnosis.
6. **The workspace starts automatically when you open the app.** On first
   launch, setup guides you through any missing permissions. Enable
   **WinMux Workspace** in **Privacy & Security → Accessibility** using the
   setup window's button. If a macOS prompt does not appear, the button still
   opens the correct Settings page. Return to setup; startup continues once
   permission is granted.
7. If setup asks for background-item approval, use **Open Login Items Settings**
   and allow WinMux Workspace. Setup opens the managed browser when ready.
   You can reopen setup later from the application's **Workspace Setup…** menu.

The new model is enabled automatically in a fresh trial. It has its own profile,
settings, and saved layout under
`~/Library/Application Support/WinMux Browser Views Trial Workspace`. Existing
marked trial workspaces continue using their original
`WinMux Browser Views Trial` folder. An unmarked browser folder created by an
earlier failed first launch is left untouched. The download contains
no browser profile, accounts, passwords, or session from the build machine.
Only one WinMux workspace can manage native windows at a time.

The trial uses the same signing identity as the existing alpha. Its name and
profile distinguish the experiment; it is not intended to run beside the other
workspace manager.

## What to try

- Open the app on a new Mac: setup should appear without an ordinary Chromium
  window and automatically request Accessibility. It should explain the missing
  permission; cancelling or closing setup must not start window management.
  Grant permission and approve the background item if requested, then confirm
  the managed browser opens. On later launches, the workspace should open
  automatically without clicking Start.

- With Work and Personal profiles already created, quit and reopen the trial.
  The Chromium profile chooser should not appear. Saved pages should retain
  their accounts, and new tabs should use the active Space's selected profile.

- Open three pages and two ordinary app windows. Each should have its own view.
  Selecting a view should fill the desktop without entering macOS fullscreen.
- Combine two views with **Combine with…**, or drag one onto another and choose
  a split or stack. Try **Separate into Own View** to reverse it.
- Close or move every item out of a group. Its empty row should disappear and
  focus should move to another view; closing the last view leaves a blank Space.
- Open an Incognito window with **Shift–Command–N**. Check the temporary Space,
  private icon, purple chrome, and **New Private Tab** button. Close all private
  tabs and confirm the Space disappears. Reopen the trial and confirm none of
  those private pages or groups returns.
- Pin a page and an app. Select them independently, combine pins, close and
  reopen a pin, and open a new tab while Pinned is active.
- Navigate to another website and check the sidebar favicon. Check both the
  expanded sidebar and its narrow icon rail.
- Create Work and Personal profiles in two Spaces. Open the same site in both
  and check separate sign-ins and history. Install a test extension in only one
  profile and check its availability in the other. Save a test password in one
  profile and check the other profile's password list.
- Send a tab, a pin, and a split group from Work to Personal. Each should reopen
  using Personal's login. Send a tab back to Shared and verify Shared's login.
  Moving between two Spaces using Work should preserve the live page and its
  back/forward history. A page with unsaved changes may ask before closing its
  original tab; cancelling that close leaves the original in the source Space.
- Assign Work to a third Space and confirm it shares Work's browser data.
  Switch a Space back to Shared and open a new tab. Existing tabs and pins
  should keep their original account.
- Switch views repeatedly and immediately type in the selected page or app.
  Note any hesitation, missed keystroke, missing window, or size drift.
- Stop the workspace, quit and reopen the trial. Confirm it starts automatically and
  its tabs, pins, and explicit arrangements return.

Useful shortcuts: **Option–Command–T** opens a tab, **Command–L** selects its
address, **Option–J/K** switches items, and **Option–Space** changes layout.
Include the Mac model/chip and macOS version with any issue you notice.

## Stop or return to the previous version

Quit the updated trial with **Command–Q**, its **Quit** menu, or Raycast's
**Quit Application**. When its last managed browser process exits, the workspace
helper unregisters and shuts down, restoring native windows. Closing a browser
window with the red button leaves the app and workspace running. You can also
use **Workspace Setup… → Stop Workspace** to stop management while leaving the
browser open. Open the previous alpha
and use its **Start Workspace**. Its separate profile and settings are retained.

Keep the app in its installed location while the workspace is active. Closing
browser windows alone does not stop the workspace helper. For a later trial
update, stop and quit it first, preserve its app and data folder, and then replace
the app. Do not merge browser profile folders.

## Build reproduction

The signed package is produced with `browser/tools/package_alpha.py --views-trial`
using the Chromium engine with version 7 private-tab routing. The package manifest records exact
native source hashes and the helper binary hash. The transfer archive is extracted
and compared against the signed bundle, including symlinks and executable bits.
The performance findings are recorded in
[`views-performance-audit-2026-10-04.md`](views-performance-audit-2026-10-04.md).
