# WinMux Browser Alpha — October 4, 2026 release candidate

This candidate combines the Chromium browser, native window management, global
new tabs, per-Space pinned groups, and the startup and switching performance fixes.
The application source is `06519287` on `codex/performance-audit`. The release
branch `codex/alpha-release-2026-10-04` adds documentation and a CI toolchain update
to that tested source.
The existing signed application is packaged without rebuilding or modifying it.

## Download and requirements

Open the repository's [Releases page](https://github.com/jamesjlyons/winmux/releases)
while signed into the GitHub account with access to its draft releases. Select
**WinMux Browser Alpha — 2026-10-04 RC1** and download these assets into one folder:

- `WinMux-Browser-Alpha-2026-10-04-rc1-arm64.zip`
- `SHA256SUMS`
- `release-manifest.json`
- `INSTALL.md`

The release remains a draft for testing on another Mac. The app is **Apple silicon
only**; Intel Macs cannot run this build. The browser, embedded workspace helper,
and framework declare macOS 13.0 as their minimum. Runtime testing so far used an
M1 Pro on macOS 27.0.1; compatibility with other macOS versions is not yet qualified.

The app is signed with **Apple Development**, team `F7QMMNZWXX`, and is **not
notarized**. This is a personal development alpha, with manual updates. It is not
a general distribution release. Chromium reports version `153.0.8010.53`; the RC
name and release manifest identify the WinMux changes separately.

## Install on the other Mac

1. Open Terminal in the folder containing the four downloaded files and run:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

   All three listed files must report `OK`. If a checksum differs, download that
   asset again before continuing.
2. If an older alpha is installed, first use its **Workspace Setup… → Stop
   Workspace**, quit the browser, and retain the old app and a stopped-state
   data backup as described below, before replacing the app in Applications.
3. Extract the ZIP. Copy **WinMux Browser Alpha.app** into **Applications** before
   launching it or starting its workspace. The app contains Chromium and the
   workspace helper; no source checkout, compiler, or signing certificate is
   needed on the destination Mac.
4. Check the extracted application's signature:

   ```sh
   codesign --verify --deep --strict '/Applications/WinMux Browser Alpha.app'
   codesign --verify --strict -R '=anchor apple generic and identifier "com.jameslyons.winmux.browser.alpha" and certificate leaf[subject.OU] = "F7QMMNZWXX"' '/Applications/WinMux Browser Alpha.app'
   ```

   These commands normally produce no output on success. A checksum verifies
   transfer integrity; signature checks additionally verify the signed bundle.
   If verification fails, preserve the exact error for diagnosis before starting
   the workspace. Do not replace the signature with an ad-hoc signature.
5. Open the app. If macOS blocks it because its developer cannot be verified or
   it is not notarized, follow Apple's app-specific **System Settings → Privacy
   & Security → Open Anyway** flow after attempting to open it. See
   [Apple's instructions](https://support.apple.com/en-us/102445). Acceptance of
   this development signature on another Mac remains part of validation.
6. Quit standalone WinMux, then choose **Workspace Setup…** from the alpha's
   application menu. Click **Start Workspace**. Allow **WinMux Workspace** in
   Login Items and grant Accessibility permission when requested. The managed
   browser opens once the helper is ready.

The new Mac starts with its own browser profile and layout. This download
contains the application only: no browser history, passwords, accounts,
extensions, personal settings, or window-session backups are transferred.
Workspace data is stored at
`~/Library/Application Support/WinMux Browser Workspace Alpha`, with the browser
profile in `daily/browser-profile` and layout/configuration in `daily/native-state`.

Move or replace the app only after **Stop Workspace**. The active workspace is
bound to the app's installed path. Closing all browser windows or quitting the
browser does not unregister the managed helper; **Stop Workspace** does.

## Acceptance checks on the other Mac

Record the Mac model/chip, macOS version, and any permission or signature errors.
Use disposable pages and ordinary test windows for these checks. Record pass/fail
and any delay or incorrect behavior; the destination checks are initially pending.

| Check | Expected result | Status |
| --- | --- | --- |
| Fresh installation | Checksums and signature pass; Start Workspace reaches a working sidebar and managed browser. Record the first startup time separately from permission prompts. | Pending |
| Basic browsing | Open two pages; address entry, navigation, typing and native browser controls work. | Pending |
| Global new tab | Press Option–Command–T with another app focused, then with all browser pages closed. Each action opens one new page. The shortcut is editable in Settings → Shortcuts → Browser. | Pending |
| Groups and pins | Create two Groups. Pin one page and one native app. Pins appear above regular Groups in that Space and focus or reopen their item. Other Spaces keep separate pins. | Pending |
| Reopen and unpin | Close a pinned page, reopen it from its icon, then unpin it. The page stays open in a regular Group. | Pending |
| Rapid switching | Switch between Groups and pins 50 times, including reversals. No accumulated position/size drift, window bounce, missing windows, or unexpected focus. | Pending |
| Input readiness | Immediately type in a page or native editor after selecting it; the first keystroke reaches the selected item. Observe this separately from windows becoming visible. | Pending |
| Shortcuts and layout | Option–J/K changes the selected item; Option–Space changes layout; Command–L selects the browser address field. | Pending |
| Restart restoration | Stop Workspace, quit normally, reopen and Start Workspace twice. Browser pages, pins, Groups and saved layouts return. Native windows still open in the Mac session retain placement. | Pending |
| Native interactions | Minimize/restore, fullscreen/return, and drag a page/native window; controls and layout recover. | Pending |
| Hardware coverage | Try physical trackpad navigation if enabled, sleep/wake, and display disconnect/reconnect if available. Mark unavailable hardware checks as not tested. | Pending |
| Stop and rollback | Stop Workspace restores native windows; ordinary browser controls remain usable. Standalone WinMux can then run again. | Pending |

The existing [performance audit](performance-audit.md) records 1,096 passing
automated tests, three full process restarts, and 50 switches without frame drift.
The final group-command median was 22.5 ms; matching geometry was observed at
89.6 ms median. Complete managed geometry appeared in 4.5–4.9 seconds after
starting the workspace in three process restarts. These are measurements from
the original Mac, not targets guaranteed on other hardware. They do not measure
page-content readiness, compositor presentation, or destination input readiness.

## Stop, update, or roll back

Use **Workspace Setup… → Stop Workspace** in the app currently managing the
workspace. This unregisters management and restores native windows. Browser
pages remain open with conventional controls; quit the browser separately.
Standalone WinMux can then be reopened with its original configuration.

Before replacing an existing alpha, stop the workspace, quit the browser, and
copy both the old app and the complete workspace data folder to a backup. For a
full rollback, stop and quit the new build, preserve its data separately, then
restore the old app and its matching stopped-state data backup. Start the old app
from its final installed location. Do not merge live profile directories or
delete current data before preserving a copy.

## Release preparation and provenance

The release archive contains only the installed `.app`. A frozen copy is created
using `ditto`; ZIP packaging uses `ditto -c -k --sequesterRsrc --keepParent` so
framework symlinks and macOS metadata survive transfer. The archive is extracted
into a separate verification directory, with every bundle file hash, symlink and
executable permission compared before and after. Both installed and extracted
bundles must pass strict nested signature verification.

The release manifest records the archive hash, binary hashes, source revision,
615 native source hashes, 28 Chromium overlay hashes, eight patch hashes and
build-configuration provenance. The historical engine manifest records parent
`27cd99f1` plus dirty source hashes because the build preceded its final audit
commit. Matching hashes establish the packaged application's relationship to
`06519287`; the release preparation and compiler-pin commits do not imply a rebuild.

The scoped release review covered startup readiness, layout retries, group
focus/placement, pin persistence, helper enrollment/rollback and packaging. It
found no release-blocking defect. The application suites and runtime checks
above are existing qualification evidence; packaging checks do not rerun them.
New-Mac results must be recorded before promoting this draft.

### CI compiler

Local builds through Swiftly and GitHub Actions use the compiler pinned in
`.swift-version`. The release branch now selects stable Swift 6.4.0. The earlier
Swift 6.2.4 CI run crashed during module serialization of `SettingsDemoActivity`'s
`isolated deinit`, before the tests ran. Updating the compiler retains the
actor-isolated cleanup used by the application already built with Xcode's Swift
6.4. The RC1 download remains the original signed application; this compiler pin
does not change its binary or the source provenance in its release manifest.
Swiftly 1.2 or later is required to resolve Swift 6.4.0's download URL; CI installs
the signed Swiftly 1.2.0 package directly instead of an older Homebrew build.

Further usage details: [Workspace Setup](workspace-setup.md),
[page controls and pins](page-windows.md), and
[Spaces and Groups](fork-interface.md).
