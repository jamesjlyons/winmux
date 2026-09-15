# Performance deep dive — September 14, 2026

## Result

Implemented five improvements in the refresh and session paths:

1. Build tab items synchronously from the existing title cache.
2. Calculate automatic group numbering once per sidebar or menu-bar rebuild.
3. Replace repeated sibling-array searches during frozen-tree capture with identity lookups.
4. Check window IDs before rebuilding an already-populated closed-window snapshot.
5. Compare session content as values before serializing it, including workspace comparisons during pending restoration.

The changes preserve project ordering, custom labels, minimized-window ownership, tab selection,
background title loading, and the existing restart-file format and backup behavior.

## Measurements

These are **Debug-build synthetic model benchmarks**, on the same machine and checkout. They
measure CPU-side model construction/comparison, not frame presentation or total interaction
latency. The baseline was recorded before changing the production functions. An isolated final
run used the same workloads. The JSON/value comparison runs the old comparison operation and
the replacement side by side on independently captured, equivalent snapshots.

| Workload | Before median | After median | Reduction | Before p95 | After p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Sidebar: 8 automatic groups, 4 windows each | 0.961 ms | 0.333 ms | 65% | 1.137 ms | 0.473 ms |
| Sidebar: 32 automatic groups, 4 windows each | 10.303 ms | 2.384 ms | 77% | 10.702 ms | 2.511 ms |
| Tab items: 40 windows, cached titles | 0.691 ms | 0.0145 ms | 98% | 0.746 ms | 0.0159 ms |
| Frozen world: 256 sibling windows | 4.545 ms | 0.548 ms | 88% | 4.710 ms | 0.595 ms |
| Existing closed-window cache: 256 windows | 4.512 ms | 0.114 ms | 97% | 4.706 ms | 0.127 ms |
| Unchanged session comparison: 128 windows | 0.896 ms | 0.0329 ms | 96% | 0.924 ms | 0.0416 ms |

Sidebar runs use 15 samples, tab and session comparison runs 30, and frozen/cache runs 20.
The reported median is the middle sorted sample and p95 uses nearest rank. Large tab/sibling
counts are stress cases. Timings are reported rather than asserted; tests assert content and
ordering. These results do not establish Release-build gains, battery savings, or drag latency.

## Why these changes help

### Tab items no longer schedule tasks that cannot do useful work concurrently

`ui/tabs/chrome/WindowTabChromeBuilder+Tabs.swift` previously created a main-actor child task for
every tab, collected items into a dictionary, and rebuilt their order. The earlier title-cache
work had already made `getSessionWindowTitle` synchronous: it immediately returns a cached title
or fallback and schedules the AX read separately. A synchronous map now preserves the order
directly. Real title reads still share requests and reject stale results.

### Automatic group numbering is computed once per presentation snapshot

`workspaceDisplayName` previously called `automaticWorkspaceDisplayIndex` for each automatic
group. Each call rebuilt presentation order and filtered that project’s visible groups.
`automaticWorkspaceDisplayIndices` now calculates the indices once, with independent counters
per project. Sidebar and menu-bar builders pass that short-lived map through their name lookup.
Individual callers retain the original lookup. No persistent invalidation cache was added.

### Frozen snapshots no longer do quadratic sibling searches

`TreeNode.childrenByMostRecentUse` checked every sibling against a growing array. Then
`FrozenContainer` looked up each recent child’s `ownIndex` by searching the sibling array again.
Identity sets and an identity-to-index dictionary make those two passes linear in sibling count.
The saved recent-use order still changes after focus, removal, and reinsertion.

### Repeated close notifications skip unnecessary tree capture

`cacheClosedWindowIfNeeded` previously captured the entire world before discovering that its
window IDs were already cached. It now checks the same set-membership condition first. A new
window still triggers a fresh snapshot; a known window preserves the original recovery snapshot.

### Unchanged session checks avoid JSON allocation

`RestartSessionController.save` used JSON bytes as an equality signature, so an unchanged
checkpoint still encoded the entire session. Frozen types now have value equality and
`RestartSessionSnapshot.hasSameContent` compares all persisted content except `savedAt`.
Only successful writes replace the previous snapshot. Pending restoration also compares frozen
workspace values, avoiding two rounds of per-workspace JSON encoding around a command.

## Validation

- Full suite: **649 tests, zero failures**. Baseline suite: 636 tests; other sidebar work was
  active in the shared checkout, and this audit adds 10 tests including four benchmarks.
- `swift build --disable-sandbox` passed for the app and CLI products.
- `git diff --check` passed.
- New regression cases cover bulk/scalar name parity after reordering, project boundaries,
  custom names, archived and minimized groups; cold/warm tab titles and nested representative
  windows; recent-use ordering; closed-cache reuse and refresh; and session comparisons after
  changes to layout, weights, selection, names, identities, frame, focus, boot, and version.
- Existing restoration, title-cache cancellation, layout, and focus tests continue to pass.

### Runtime observations

A five-second sample of the original running Dev process found the main thread waiting for
events throughout the sample. This provides no evidence of an idle busy loop. Its physical
footprint was 708.8 MB (987.5 MB peak); without an allocation history that is not evidence of a
leak or of savings from this patch.

The Dev app was rebuilt/restarted independently while this shared-checkout audit ran. The
installed executable’s Mach-O UUID subsequently matched this checkout’s built executable:
`3BA03AC7-329B-3854-8683-7EA6422F0CC8`. The live doctor reported Accessibility granted and
screen capture missing, with 16 successfully restored session windows.
Consequently, there is no controlled before/after live-process timing comparison in this report.

The repository's temporary-window geometry probe then completed **12/12 corrections with zero
timeouts**: median 57.845 ms, nearest-rank p95 74.405 ms. This is a behavior smoke test, not a
speed comparison. The 16 window IDs recorded before the probe exactly matched those afterward,
and the configuration's SHA-256 hash was unchanged. The helper emitted a sandbox-extension
diagnostic but opened, completed all samples, and closed normally.

## Further opportunities, ordered by value

The [September 15 follow-up](performance-follow-up.md) implements four of these opportunities
and records the profiling decisions for broad model caching and flip capture.

These are code-backed follow-ups requiring their own measurements, not additional claimed wins.

| Priority | Area and evidence | Next step and correctness constraint |
| --- | --- | --- |
| 1 | Changed session saves still perform encoding, backup read/validation, and two atomic writes on the main actor (`tree/frozen/persistedFrozenWorld.swift`, `RestartSessionFile.swift`). | Measure save signposts under active input; move changed-snapshot I/O to a serialized writer with explicit flush-on-quit ordering and failure reporting. |
| 2 | Sidebar model application syncs panel models before and after changed workspace assignment; panel copies include many unrelated published fields (`WorkspaceSidebarModelStateApplier.swift`, `WorkspaceSidebarPanelController.swift`, `TrayMenuModel.swift`). | Measure actual SwiftUI invalidations, then publish one complete panel snapshot or narrower observable models while preserving each panel’s browsing and hover state. |
| 3 | Every refresh still rebuilds model values even when equality suppresses publication (`layout/refresh.swift`, sidebar/tab model builders). | Add model-build signposts by event and workspace; consider dirty-workspace snapshots only after covering title, focus, monitor, config, and lifecycle invalidation. |
| 4 | The background title worker publishes after all batches drain, so one slow app can delay visible title updates from fast apps (`ui/core/WindowTitleCache.swift`). | Measure cold titles across responsive and stalled apps; publish completed changes in bounded batches without rebuilding the UI per title. |
| 5 | Empty-slot visibility can recalculate retained slots across all projects (`tree/WorkspaceRetainedEmptySlot.swift`). | Benchmark many empty groups and minimized windows; share retention/ownership lookups within a reconciliation pass. The occupied-group benchmark above does not cover this case. |
| 6 | Double-sided flips capture three images synchronously before switching focus (`ui/tabs/DoubleSidedWindowController.swift`). | Profile capture separately from animation with screen capture enabled, and preserve immediate focus behavior if capture is slow. This path was unavailable in the live session. |

## Reproduce

```sh
swift test --disable-sandbox --filter ModelRefreshBenchmarkTest
swift test --disable-sandbox
swift build --disable-sandbox
git diff --check
```

Raw logs from this run are local temporary artifacts:

- `/tmp/winmux-optimization-model-before.log`
- `/tmp/winmux-optimization-model-after.log`
- `/tmp/winmux-optimization-tests.log`
- `/tmp/winmux-optimization-build.log`
- `/tmp/winmux-optimization-idle-before.sample.txt`
- `/tmp/winmux-optimization-live-geometry.log`
