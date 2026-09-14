# Interaction performance updates

## Behavior

- Known move/resize notifications reconcile the emitting windows without application discovery.
  Pending events union window IDs; lifecycle events broaden the scope to their apps, and global
  recovery events retain full reconciliation. Active gesture frames retain their layout baseline.
- Pointer events feed shake recognition. Preview rendering follows display ticks, with immediate
  startup and a forced mouse-up flush. The display mailbox holds one pending delivery with the
  newest timestamp; stopped sessions and newly subscribed owners reject old callbacks.
- Resize previews no longer snapshot the entire world per frame. Snapshots remain at gesture
  startup and immediately before committed changes, capturing any intervening tree changes.
- Frame writes skip matching dimensions while preserving origin correction after resize and size
  correction after cross-monitor movement. Cancellation and animation restoration remain intact.
- Window placement precedes sidebar/tab model work. Cold titles use the existing app-name fallback
  and load in the background. Requests are shared; reset, closure, and replaced-window results are
  rejected. The switcher palette still waits for cold titles so names are searchable immediately.

Set `WINMUX_DEBUG_FOCUS=1` or `WINMUX_DEBUG_DRAG=1` before launching Dev to enable verbose logs.
Both are off by default. Signposts remain available for refresh sessions, discovery, native-state
normalization, frame requests/jobs, display sample age, gesture processing, and sidebar/tab models.

## Validation — September 13, 2026

The full suite passed: **607 tests, zero failures**. New coverage includes window-scoped geometry,
event coalescing and recovery, stale/shared title requests, frame clamping/cancellation, and
concurrent display mailbox delivery.

A synthetic six-window workload with a simulated 1 ms frame-request cost produced:

| Metric | Global geometry refresh | Scoped geometry refresh |
| --- | ---: | ---: |
| Frame requests across 20 updates | 120 | 20 |
| Median session time | 8.31 ms | 2.30 ms |
| p95 session time | 8.89 ms | 3.47 ms |

A live Cocoa test window was moved/resized programmatically and timed until its original tiled
frame returned. Both runs used 12 samples on the built-in display:

| Metric | Before restart | Updated Dev |
| --- | ---: | ---: |
| Median frame restoration | 55.68 ms | 20.33 ms |
| p95 (nearest rank) | 60.45 ms | 28.14 ms |
| Timeouts | 0 | 0 |

This small live sample measures external geometry correction, not pointer-drag latency, actual
screen presentation, workspace-switch latency, or CPU savings. It is not evidence that the
4 ms gesture-processing target is met. All 11 tracked windows survived the Dev restart; the
updated process reported both Accessibility and screen-capture permissions granted. A separate
computer-use mouse smoke test returned an unusable screenshot and timed out before a verified
gesture; it is not counted as validation. Its temporary app was closed afterward.

## Repeat the measurements

Run the suite with `swift test --disable-sandbox`. The `testGeometryRefreshBenchmark` test reports
request counts, median, and p95; it asserts work counts instead of fragile timing thresholds.

With an unlocked session and Dev running, execute `./script/benchmarks/run-geometry-probe.sh`.
It opens a temporary window in the active workspace, performs 12 frame changes, and closes it.
Expect temporary tiling changes while it runs. Redirect stdout to save each run, and compare
before/after under the same app load. Do not interact with the test window during measurement.

For drag/resize and switching, profile the signposts while repeating the same gestures at the
same display refresh rate and app load. Separate WinMux processing from AX job queueing and target
app response; record CPU use and median/p95. Keep the 4 ms p95 processing target at 120 Hz as an
unverified target until those gesture traces are collected.
