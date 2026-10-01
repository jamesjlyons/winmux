# Tab and native-window integration status

The user asked on October 1 to proceed directly to tab/window integration and
optimize performance afterward. Remaining performance qualification and extension
scenarios are deferred. The implementation retains the correctness and process
security requirements in [the approved plan](approved-plan.md).

## Shared identity and native adapter — 2026-10-01

- `WorkspaceCore` defines typed native-window and profile-scoped browser-tab
  identities, capabilities, and an owner-adapter interface. Numeric macOS window
  IDs, browser tab indices and renderer IDs are not durable workspace identities.
- Native sidebar rows, group selections and keyboard search selection now use
  typed identities. The native adapter resolves the live owner again before
  focusing or closing, rejecting a stale item even if macOS reuses its old
  numeric window ID. Existing native CLI lookups and native workspace fallback
  remain available. A close request waits for the owning app's normal close/save
  flow; issuing the request does not remove the item or claim completion.
- Session version 3 persists native surface IDs. Version 1/2 imports and backup
  handling remain; the next native checkpoint writes version 3. IDs are restored
  only after matching the existing boot, process-launch and window binding.
  Missing, duplicate and wrong-kind identities in version 3 are rejected.
- All **721 native regression tests** pass, including six new adapter/migration
  tests. Three shared identity tests also pass. Tests use synthetic windows and
  temporary session files; no second native window manager was launched.

## Chromium tab identity — 2026-10-01

- A small owned patch registers a persistent profile UUID and stores each tab's
  UUID in Chromium's normal session extra data. Session insertion, rebuild and
  restore use the same metadata. Live UUID conflicts receive a fresh identity.
- The identity moves with the tab when Chromium replaces discarded WebContents.
  This path is compiled but has not yet been exercised at runtime. Private tabs
  receive no persistent identity and write no identity diagnostic records.
- The four-job optimized Chromium build and Personal Team packaging succeeded.
  Staging package:
  `.local/browser/packages/alpha-identities-1/WinMux Browser Alpha.app`.
  It passed deep/strict signature verification. The installed browser and the
  previously enrolled helper were not replaced.
- The actual signed headless browser created a tab, quit cleanly, and restored
  **the exact same tab/profile surface identity** from its saved session. A
  second fresh profile received a different profile identity. An incognito run
  emitted no persistent-ID records. All four isolated test browsers exited 0.
  Existing profiles, signed-in UI and vaults were not inspected.
- The first test attempt used two command-line targets, which headless Chromium
  rejects before startup. The successful test uses one synthetic tab. Multiple
  tabs, duplicate/closed-tab restoration, renderer replacement and crash recovery
  still need correctness coverage; no performance claim is made.

[Build, package, source hashes and actual-browser results](evidence/2026-10-01-surface-identities.json).
Reproduce with `browser/tools/test_tab_identities.py --app <staged-app> --output
<new-directory>`; it refuses an existing output directory and stops only its own
test processes.

## Authenticated inventory and owner actions — 2026-10-01

- Protocol version 2 publishes a full browser inventory at connection/recovery,
  then coalesced tab upserts/removals from Chromium's tab-strip events. It records
  stable surface IDs, runtime host IDs, titles and selected-tab state in memory.
  Popup, app, developer-tool and private windows are excluded from this initial
  normal-tab inventory. There is no polling, page scripting or inventory file.
- The helper validates message size, sequence, epoch, revisions, record bounds
  and identity kinds before atomically reconciling its connection-scoped mirror.
  Private/native records, duplicate IDs, conflicting updates and missing/out-of-
  order deltas are rejected. A rejected inventory causes a fresh authenticated
  connection and full inventory.
- Browser-owned focus/close requests use exact surface identity, connection
  epoch, inventory revision, UUID operation ID and monotonically increasing
  focus generation. Newer queued focus requests supersede older ones. A bounded
  operation journal handles retries without repeating a close, and rejects
  reuse of an operation ID for a different request. Chromium performs operations
  on its UI thread through normal tab/window APIs and before-unload handling.
- `BrowserTabSurfaceAdapter` supports focus and close. Its UI-facing session
  ignores stale inventory and late focus acknowledgements across reconnects,
  keeps newer focus intent, and waits for an owner removal delta before removing
  a tab. An `issued` response is **not** confirmed native focus or input readiness.
- The Personal Team staging package is
  `.local/browser/packages/alpha-inventory-2/WinMux Browser Alpha.app`.
  In a real signed headless browser, a separately signed temporary helper
  received one full inventory plus incremental updates, observed two tabs, issued a
  focus and close, and observed one remaining tab. Repeated close was idempotent;
  old focus, conflicting operation and foreign epoch requests were rejected.
  After disconnect/reconnect, a fresh endpoint received exactly one tab in a
  new full inventory and remained stable for **17.09 seconds**. The test browser
  exited 0 and the temporary launchd service was removed.
- A separate actual incognito run sent an empty inventory before and after
  reconnection, issued no actions, remained stable for the same 17-second
  observation and exited cleanly. No private tab records reached the helper.
- The initial test caught a real shutdown failure: the inventory observer
  retained the browser collection after Chromium destroyed it. An explicit
  `PostMainMessageLoopRun` cleanup now cancels queued UI actions, disconnects the
  transport and destroys observations before browser-process teardown. The fixed
  package passed clean shutdown in both version 2 and legacy-helper tests.
- The browser negotiates version 1 with the existing transport-only helper;
  that actual signed fallback/reconnection test passed with the helper's process
  identity unchanged. The installed alpha, original WinMux, signed-in profiles
  and existing SMAppService enrollment remain untouched. Normal Chromium controls
  stay available; the tab strip is not hidden before the shared UI is ready.
- **721 native regression tests, 15 native bridge/core tests, 35 Python checks**
  and the C++ connection-state probe pass. No benchmark or extension acceptance
  work was resumed. Browser-visible focus, before-unload dialogs, mixed layouts
  and live sidebar selection remain pending.

[Actual browser/helper results, package provenance and checks](evidence/2026-10-01-browser-inventory.json).
Reproduce with `browser/tools/test_browser_inventory.py` and a new output path.
The test creates only a uniquely named temporary service with the same exact
Apple team/helper signing requirement, stops its own headless browser, verifies
the existing helper identity and removes the test service. It never enrolls over
the live helper or reads signed-in browser UI.

## Next implementation work

The browser does **not yet show its tabs in the WinMux sidebar**. Stable references,
native/browser adapters and the authenticated inventory/action connection are
implemented; the visible mixed UI remains next.

1. Connect the helper's validated inventory and `BrowserSurfaceSession` to the
   existing native sidebar, then add browser item rows. Keep Chromium authoritative
   for actual tab lifecycle and WinMux for placement. The helper is still a
   transport process; it does not yet launch AppBundle or take native WM ownership.
2. Add browser host registration/exclusion from ordinary AX discovery and a
   focus generation shared across native and browser selections. Current focus
   guards apply to browser requests; global mixed-item arbitration is not wired.
3. Generalize the layout tree, drag/drop, groups and split hosts to accept both
   surface kinds. Add typed surface commands while keeping native numeric CLI
   compatibility. The native layout tree and drag APIs still use `Window` today.

Do not restart benchmark or extension-testing loops before this integration.
