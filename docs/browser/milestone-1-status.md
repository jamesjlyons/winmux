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
and native activation has now been verified against a launch-bound synthetic fixture.

1. macOS approval is granted and isolated native/browser switching passed. The
   config/socket/session separation, ownership checks, host reconciliation and
   shared native focus clock are implemented. No permission request remains.
   Existing native keyboard/gesture traversal still enumerates native windows;
   traversal across mixed stacks belongs to the generalized model below.
2. Generalize the layout tree, drag/drop, groups and split hosts to accept both
   surface kinds. The alpha sidebar now uses the shared recursive SurfaceTree
   described below, with typed moves and mixed groups. Native geometry and global
   traversal still use `Window`; shared organization is only in memory.
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

## Isolated native activation — 2026-10-01

- The embedded helper now accepts explicit `--manage-native <state-directory>`
  activation on a uniquely named staging service. Normal enrollment stays
  transport-only, and `--sidebar-preview` stays free of native management.
- Native startup uses a dedicated marked state directory, explicit configuration,
  separate restart snapshot and a short path-specific Unix socket. It does not
  import the original config, remove its socket, migrate its LaunchAgents, change
  its login registration or toggle the standalone manager in debug builds.
- An exclusive per-user lease refuses simultaneous alpha managers. A running
  standalone WinMux is checked before startup and again after Accessibility
  approval. A newly launched standalone manager revokes alpha mutation access;
  alpha exits without restoring windows over that manager. An optional PID and
  launch-date scope restricts discovery to a disposable native test process.
- Authenticated browser ownership now removes previously discovered native leaves
  without treating them as closed windows or focusing a replacement. Pending AX
  placement/focus jobs are quarantined. Installed alpha browser windows are also
  conservatively excluded before a bridge handshake.
- Native command/keyboard/gesture selections now use the shared focus clock,
  including selecting the previously focused native leaf and moving to an empty
  workspace. Native selection dispatches before browser fence replies. A bounded
  pending-focus hold prevents stale AX observations immediately undoing a browser
  request; explicit pointer input clears it. This is not input-readiness proof.
- Native refresh does not raise the old native leaf over a foreground browser.
  Browser intent suppresses stale native sidebar highlights. Alpha gesture
  selection bypasses the screenshot-based double-sided flip path.
- The live test uses only the synthetic `WinMux Native Fixture` app and two fresh
  local browser tabs. Its signed browser/helper authenticated, but native startup
  reached macOS's protected Device Control and Data Access password prompt.
  **Native/browser live selection is not yet verified.** The user has been asked
  once to approve that prompt; do not read credentials or repeat the request.
- Mixed trees, drag/drop, groups, split hosts, browser-host geometry and shared
  placement persistence remain the next implementation work. Permission approval
  blocks the live native proof, not this independent implementation. Performance
  and extension checks remain deferred by the user's direction.

The final staging app is `.local/browser/packages/alpha-native-3/WinMux Browser
Alpha.app`; it passes deep/strict signing and its recorded native source hashes
match this implementation. **731 native regression tests, 30 final targeted
focus/gesture tests, 16 bridge/core tests and 35 Python checks pass.** The initial
live attempt used package 1; its browser exited 0 and its unique service and
synthetic fixture were removed while waiting for the protected approval. The
installed browser and previously enrolled helper remain unchanged.

[Native activation evidence and precise limits](evidence/2026-10-01-native-activation.json).

The final package also passed a real signed **headless** browser/helper check:
focus and repeated fences, close/repeated close, stale/foreign/conflicting request
rejection, authoritative inventory after recovery, **17.03 seconds** of stability,
exit 0 and test-service cleanup. The enrolled helper identity stayed unchanged.
This preserves transport correctness; it does not satisfy the pending live
native-window proof.


## Permission granted and shared sidebar tree — 2026-10-01

- The user confirmed macOS approval. `alpha-native-3` then reached **Native
  workspace ready (isolated state)**. Computer Use selected both launch-bound
  synthetic native windows and both fresh local browser tabs. Native key-window
  notifications and Chromium's selected tab confirmed the owner transitions.
  This resolves the earlier protected-permission blocker; no further approval
  request is pending. It does not establish input-ready latency.
- `SurfaceTree` now gives the alpha sidebar one recursive organization for native
  and browser IDs, with reorder, grouping/ungrouping, root moves, removal pruning
  and workspace merging. Owner refreshes preserve mixed order; temporary browser
  disconnects retain placement, and confirmed owner removal prunes it. Profile
  UUIDs remain part of browser identity. No fake native windows are created.
- The actual alpha sidebar renders both kinds through the same row and drag
  payload. It exposes Move Earlier/Later, Group with Selected Item, Ungroup Items,
  typed moves to existing/new workspace headers, and owner-specific Close. Search
  and search selection recurse into mixed groups. Native numeric CLI and the
  standalone sidebar remain on their existing paths.
- Browser-only workspaces count as occupied during lifecycle/sidebar decisions.
  Moving workspace contents to a deletion fallback also moves browser references
  and shared organization. Native move dispatch resolves the durable ID inside
  the session so a recycled native window number cannot redirect the operation.
- The signed **alpha-tree-1** passed live Computer Use grouping of **WinMux Native
  One + WinMux Sidebar Two**, reordering those children, selecting the browser tab
  (inventory revision 5), selecting the native window (key-window notification),
  and ungrouping with all four original items still present. A screenshot is
  retained with the evidence. Physical dragging and cross-workspace moves were
  not exercised in this UI run; their typed payload/model paths are implemented.
- **734 native regression tests, 17 WorkspaceCore tests, 5 bridge tests and 35
  Python checks pass.** The new package passes deep/strict signature verification
  and its native source hashes match. Both isolated test browsers exited 0,
  temporary services were removed and fixtures were stopped. Installed alpha
  PID 33776 and enrolled transport helper PID 17212 stayed unchanged.
- These are **sidebar organization groups**, not yet mixed pane layouts. The
  native geometry tree remains native-only; browser host geometry/visibility,
  tab transfer, mixed splits, global mixed keyboard/gesture traversal and durable
  shared placement persistence are the next work. Existing native tab-group
  membership is not yet imported into the new sidebar organization. Normal
  Chromium controls remain available. Performance and extension work stay deferred.

[Verified evidence](evidence/2026-10-01-mixed-sidebar-tree.json) ·
[Actual mixed-sidebar screenshot](evidence/2026-10-01-mixed-sidebar-tree.jpeg).
Current staging app: `.local/browser/packages/alpha-tree-1/WinMux Browser Alpha.app`.
It has not replaced the installed application or its enrolled helper.

## Browser-owned hosts and actual mixed layouts — 2026-10-01

- The shared tree now plans stacks and horizontal/vertical splits. The real
  sidebar exposes both split directions; grouping becomes a stack after explicit
  native activation with a layout-capable browser. Native placement resolves
  typed IDs back to live windows. Chromium owns its host frames and visibility.
- Authenticated protocol v3 adds bounded, asynchronous layout requests with
  connection epochs, inventory revisions, generations and operation-id reuse
  checks. Chromium validates tab identities, profile boundaries, selections and
  frames before moving tabs. Transfers use existing TabModel objects, preserving
  tab/profile identity and page state. Hosts are reused by container and profile;
  different profiles are never merged. Fullscreen sources return unsupported.
- Layout requests coalesce while one is in flight. Late replies from an older
  epoch cannot change current state. Layout completion reaffirms only the current
  selection. Disabling native management or losing the helper connection releases
  browser hosts back to conventional controls. Normal enrollment stays transport-only.
- Live Computer Use on **alpha-layout-2** proved a native/browser horizontal split:
  native `(240,30,840,959)` and Chromium `(1080,30,840,960)`. A subsequent vertical
  split placed native `(240,30,1680,480)` and Chromium `(240,510,1680,480)`.
  Selecting the native stack item made Chromium report hidden; selecting the tab
  restored Chromium and parked the native window using the existing native path.
  Text entered into the synthetic browser page survived both split directions
  and stack switching. This verifies those operations, not input-ready latency.
- Final **alpha-layout-3** passed the actual signed headless test: two separate
  hosts with exact requested bounds, merge back to one host, identity retention,
  hidden-host reporting, repeated requests, stale/conflicting request rejection,
  focus/close fences and reconnection. It remained authenticated for **17.06
  seconds** after recovery, then exited 0. Two earlier harness attempts failed
  because conflicting requests raced and the expanded sequence exceeded its
  deliberate-disconnection delay; both are documented in the evidence. Package 3
  changes only that test timing and retired-endpoint diagnostics from package 2.
- **734 native regression tests**, **31 final targeted native tests**, **20
  WorkspaceCore tests**, **5 bridge tests** and **35 Python checks** pass. The
  final package passes deep/strict verification and all 563 recorded native source
  hashes match. UI and headless test services were removed, the synthetic fixture
  was stopped and both test browsers exited 0. Installed alpha PID 33776 and the
  enrolled transport helper PID 17212 remained unchanged.

The next work is durable shared placement restoration and mixed global
keyboard/gesture traversal. Existing native tab-group membership is not yet
imported. Physical dragging and cross-workspace UI moves, minimum window sizes,
display changes, popups and large workloads remain unqualified. Hidden hosts are
currently materialized eagerly. Normal Chromium controls remain available;
performance and extension testing remain deferred by the user's direction.

[Actual mixed-layout evidence](evidence/2026-10-01-mixed-layouts.json).
Current final staging app: `.local/browser/packages/alpha-layout-3/WinMux Browser Alpha.app`.
It has not replaced the installed application or its enrolled helper.

## Shared restoration and mixed navigation — 2026-10-01

- Alpha snapshots now use version 4 with the shared tree, stack/split styles,
  selected item, enabled layout workspaces and confirmed browser-close tombstones.
  They use the existing serialized writer, one-second checkpoint and orderly-quit
  flush. Readers retain versions 1–3 and reject unknown versions, duplicate
  references, excessive nesting and invalid selection/layout metadata. Workspace
  snapshots contain typed references, without browser titles, URLs or host IDs.
- Chromium retains authority over live tabs and session content. Missing saved
  references cannot reopen a tab. Initial live tabs without placements enter
  Recovered; subsequent new tabs use the current workspace. Browser quit no longer
  reports its session teardown as individual tab closes. Native identity reuse
  still requires the boot/process/window match. Version 4 can preserve browser
  placements across a boot while unmatched native references remain placeholders.
- Existing native sidebar tab groups are imported when shared organization first
  initializes. Mixed DFS, tab-index, next/previous and workspace-direction focus
  dispatch through owner adapters; numeric native IDs keep their meaning.
  Cross-monitor directional boundary handling remains on the existing path.
  Trackpad candidates capture shared selection/generation/tree state and reject
  commits after the owner, workspace, group or selection changes. No screenshot
  transition is introduced.
- Live **alpha-persistence-1** created a mixed stack through the actual sidebar.
  After its isolated browser/helper session ended, a new session restored the
  exact tree, group UUID, two native IDs, two browser IDs, stack selection and
  hidden browser host. Native fixture PID/launch identity stayed the same.
  Through the isolated helper's command interface, `focus tab-next --wrap-around`
  selected the browser and showed its host; `trigger-binding --mode main alt-k`
  returned to the native window, with a native key-window event and hidden web host.
- The physical-keyboard attempt is **not a pass**. The first UI session reached
  its fifteen-minute timeout; a later Computer Use browser lookup started a
  staged browser without the test-profile arguments. Further browser UI inspection
  was stopped. That separate process was left untouched; the installed signed-in
  browser and original helper stayed running. The successful restart/navigation
  evidence comes from isolated profiles, owner reports and the scoped command API.
  Physical trackpad delivery, physical drag and cross-workspace UI moves remain
  unverified. Unit gesture checks are not hardware-delivery proof.
- **737 native regression tests**, **13 final targeted integration tests**, **23
  WorkspaceCore tests**, **5 bridge tests** and **35 Python checks** pass. The final
  targeted checks include inventory arriving before restoration and restored-tab
  workspace activation. The final package adds those startup-order corrections
  and preserves imported native stack selection after the package-1 live proof.

Final staging package: `.local/browser/packages/alpha-persistence-2/WinMux Browser Alpha.app`.
It passes deep/strict signing and all 566 recorded native source hashes match.
Its signed headless layout/action/recovery check also passes, exits 0 and removes
its temporary service without changing the previously enrolled helper.
[Restoration/navigation evidence](evidence/2026-10-01-shared-restoration.json).
The installed app and helper have not been replaced. Remaining work includes
physical mixed drag/drop, cross-workspace/display transitions, completing shared
CLI/action coverage and a deliberate daily-driver activation path. Performance
and extension testing remain deferred.
