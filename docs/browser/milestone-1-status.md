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

The real sidebar now shows and operates Chromium tabs in the explicitly isolated
preview described below. The installed browser/helper have not been upgraded,
and a combined native-window manager is not yet activated.

1. Add explicit native management activation with isolated configuration, socket
   and session state, and an ownership check before running AppBundle's startup.
   Normal helper launch remains transport-only; `--sidebar-preview` starts just
   the sidebar in a uniquely named test service. It never starts AX management.
   Reconcile any previously discovered host bindings before enabling native
   layouts, and route keyboard/gesture selection through shared focus intent.
2. Generalize the layout tree, drag/drop, groups and split hosts to accept both
   surface kinds. Add typed surface commands while keeping native numeric CLI
   compatibility. Native trees/drag still use `Window`; browser rows currently
   append to their assigned workspace, and placement is only in memory.
3. Implement owner host geometry, visibility and tab transfer for mixed stacks
   and splits, then persist shared placements without copying browser sessions.

Do not restart benchmark or extension-testing loops before this integration.

## Live sidebar integration — 2026-10-01

- The helper can now link the actual AppBundle sidebar through a root-package
  `WinMuxWorkspaceHelper` product. Validated endpoint snapshots reach a main-actor
  `BrowserSurfaceSession`; connection teardown removes its rows and queued old
  callbacks cannot recreate them. Duplicate live owners of the same durable ID
  are rejected for selection rather than choosing an arbitrary connection.
- Browser rows have typed IDs, browser-specific icons/labels, normal sidebar
  search/keyboard selection and a Close Tab context action. They do not create
  native `Window` objects or fake numeric window IDs. Only an authoritative
  Chromium removal deletes a row; an issued close leaves it in place.
- Sidebar selections share one generation clock across native windows and all
  browser connections. Native selection dispatches immediately, fences older
  browser focus work asynchronously, and reaffirms the still-current native
  target after the fence. Stale replies cannot switch back to an earlier target.
  Browser fences are revision-independent and idempotent. This is selection
  arbitration, not verified native input readiness, and non-sidebar native
  keyboard/gesture paths still need integration.
- Normal browser records include their real macOS host window number. Inventory
  validation rejects conflicting host/window bindings. The authenticated client
  PID and process launch date quarantine its windows from ordinary AX discovery,
  including unclassified popup/extension UI. Quarantine survives a transient XPC
  disconnect. These native discovery checks have unit coverage; no second native
  manager was started for the UI proof.
- The helper is packaged as its own signed accessory application, with signed
  SwiftPM resource bundles, inside the alpha. Its new relative executable path
  is recorded in the manifest and LaunchAgent. The initial package caught an
  unsigned MASShortcut resource bundle and was discarded; the corrected packages
  pass deep/strict signing verification. Existing SMAppService enrollment is
  still the previous transport helper.
- Actual Computer Use testing of `alpha-sidebar-3` displayed the two fresh local
  pages **WinMux Sidebar One/Two** in the production sidebar. Clicking Two changed
  the browser inventory from revision 4 to 5. Close Tab removed Two from both
  Chromium's inventory (revision 6, one tab) and the visible sidebar.
- Restarting only that temporary helper produced authenticated generation 2 and
  a full inventory at revision 7 containing exactly One. Its sidebar window
  repopulated correctly. The browser subsequently exited 0 and the test service
  was removed. No signed-in browser UI, extension or vault content was read.
- Final staging package: `.local/browser/packages/alpha-sidebar-5/WinMux Browser
  Alpha.app`. Package 4 passed the signed headless repeated-fence/action and
  recovery test. Package 5 additionally corrects reaffirmation when several
  browser connections complete their fences at different times, with a new
  three-connection unit test. The visible UI proof above used package 3; these
  distinct package proofs are recorded separately below.
- **725 native regression tests**, **16 bridge/core tests**, **11 final targeted
  sidebar/native tests** and **35 Python checks** pass. Native focus tests use
  synthetic TestWindows; they do not establish live native/browser layout or
  Accessibility permission acceptance. Performance and extension work remain
  deferred as requested.

[UI observations, package provenance and final checks](evidence/2026-10-01-live-sidebar.json).
`browser/tools/launch_sidebar_preview.py --app <staged-app> --output <new-dir>`
launches only fresh synthetic tabs and a uniquely named sidebar service. Use
Computer Use for its UI; create `<new-dir>/stop` to cleanly remove the test session.
It also stops automatically after fifteen minutes. This is a staging proof, not
the daily-driver activation path.
