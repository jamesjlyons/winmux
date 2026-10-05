# WinMux Views Trial with Profiles — October 4, 2026

This trial uses the new tab-style model: each ordinary app window or browser tab
starts in its own view and fills the usable desktop. Splits and stacks appear
when you explicitly combine views. Each Space has its own Pinned area. Website
favicons follow the current page, including the selected member of a stack.

The profile update adds named browser profiles that can be reused across Spaces.
Use **Space → Manage Space → Browser Profile → New Profile…**, enter a name such
as Work or Personal, then open a new tab. Other Spaces can select that same name,
choose a different profile, or use **Shared**.

Each named profile has Chromium's own history, cookies, site storage, extensions,
settings, and saved-password database. Spaces that choose the same profile share
that data. Shared uses the trial's original browser profile. New tabs from the
sidebar, page-toolbar **+**, and **Option–Command–T** use the Space's choice.
Pages opened by a website or Chromium's own commands retain their source browser
profile. Existing tabs and
pins keep their original profile when a Space's setting changes or a tab moves;
only new tabs use the selected profile. Deleting a Space keeps the reusable
profile and its data. Profiles are local to this trial installation and aren't
imported from another browser or the daily alpha.

The download is a complete application for **Apple Silicon Macs (M1 or newer)**.
No source checkout, compiler, Python installation, or signing certificate is
needed. The binaries require macOS 13 or newer; runtime testing on this machine
uses macOS 27.0.1. Other Mac and OS combinations remain to be tested.

## Install and start

1. Download the trial ZIP, `INSTALL.md`, `trial-manifest.json`, and `SHA256SUMS`
   from the **WinMux Views Trial with Profiles — 2026-10-04** draft on the repository's
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
6. From the trial's application menu, choose **Workspace Setup…**, then
   **Start Workspace**. Allow the workspace background item and Accessibility
   permission if macOS requests them. The trial's managed browser opens when
   startup completes.

The new model is enabled automatically in a fresh trial. It has its own profile,
settings, and saved layout under
`~/Library/Application Support/WinMux Browser Views Trial`. The download contains
no browser profile, accounts, passwords, or session from the build machine.
Only one WinMux workspace can manage native windows at a time.

The trial uses the same signing identity as the existing alpha. Its name and
profile distinguish the experiment; it is not intended to run beside the other
workspace manager.

## What to try

- Open three pages and two ordinary app windows. Each should have its own view.
  Selecting a view should fill the desktop without entering macOS fullscreen.
- Combine two views with **Combine with…**, or drag one onto another and choose
  a split or stack. Try **Separate into Own View** to reverse it.
- Pin a page and an app. Select them independently, combine pins, close and
  reopen a pin, and open a new tab while Pinned is active.
- Navigate to another website and check the sidebar favicon. Check both the
  expanded sidebar and its narrow icon rail.
- Create Work and Personal profiles in two Spaces. Open the same site in both
  and check separate sign-ins and history. Install a test extension in only one
  profile and check its availability in the other. Save a test password in one
  profile and check the other profile's password list.
- Assign Work to a third Space and confirm it shares Work's browser data.
  Switch a Space back to Shared and open a new tab. Existing tabs and pins
  should keep their original account.
- Switch views repeatedly and immediately type in the selected page or app.
  Note any hesitation, missed keystroke, missing window, or size drift.
- Stop the workspace, quit and reopen the trial, and start it again. Confirm
  its tabs, pins, and explicit arrangements return.

Useful shortcuts: **Option–Command–T** opens a tab, **Command–L** selects its
address, **Option–J/K** switches items, and **Option–Space** changes layout.
Include the Mac model/chip and macOS version with any issue you notice.

## Stop or return to the previous version

Use the trial's **Workspace Setup… → Stop Workspace**, then quit the trial
browser. Native windows return to ordinary behavior. Open the previous alpha
and use its **Start Workspace**. Its separate profile and settings are retained.

Keep the app in its installed location while the workspace is active. Closing
browser windows alone does not stop the workspace helper. For a later trial
update, stop and quit it first, preserve its app and data folder, and then replace
the app. Do not merge browser profile folders.

## Build reproduction

The signed package is produced with `browser/tools/package_alpha.py --views-trial`
using the Chromium engine with version 6 profile routing. The package manifest records exact
native source hashes and the helper binary hash. The transfer archive is extracted
and compared against the signed bundle, including symlinks and executable bits.
The performance findings are recorded in
[`views-performance-audit-2026-10-04.md`](views-performance-audit-2026-10-04.md).
