# Focus responsiveness — September 15, 2026

## Changes

Light command sessions now request native focus immediately after window placement and
the cancellation check. Sidebar/tab publication and session checkpointing follow that
request. This lets the selected app receive input while WinMux finishes updating chrome.
The existing serialized Accessibility queue and cancellation of superseded focus jobs
remain in place.

Fullscreen chrome suppression reuses the window's existing event-invalidated native
fullscreen cache. An unknown value is fetched live; a failed read remains retryable.
Successful fullscreen-only observations do not invent a minimized-state value. A result
is discarded if another focus check superseded it, the native-state generation changed,
or the window was removed/replaced during the await. Existing move/resize and minimize
events invalidate the cache. Native focus itself is still queried before each session.

`focus --window-id` resolves a concrete window directly. It no longer reads every floating
window's geometry or temporarily attaches those windows to the tiling tree. Directional,
DFS, and tab-relative focus retain their existing spatial/group traversal behavior.

## Instrumentation

Added Points of Interest intervals for `Native focus lookup`, `Fullscreen chrome state`,
`Light session command`, `Layout workspaces`, and `Native focus job`, plus `Native focus
requested`, `Fullscreen state cached`, and `Fullscreen state read` events. Focus requests
and jobs carry the window ID so queue delay can be separated from time executing the job.
The activation-only focus path emits a request without an AX job.

New intervals and the two outer refresh/session intervals use a separate signpost ID per
invocation. The old default exclusive ID was ambiguous when refreshes overlapped across
an await; old full-refresh durations should not be compared as if they were correctly
paired. See Apple's [OSSignpostID documentation](https://developer.apple.com/documentation/os/ossignpostid).

## Deterministic workload checks

The same optimized test fixtures ran before and after the source change. The simulated
2 ms request delay makes redundant work visible; elapsed times include scheduler overhead
and do not represent a real app's focus latency. Tests assert counts and behavior, not
timing thresholds.

| Workload | Before | After |
| --- | ---: | ---: |
| Fullscreen reads across 20 unchanged chrome updates | 20 | 1 |
| Geometry reads across 10 exact-window focus commands, 4 floating neighbors | 40 | 0 |

Observed fixture totals were 61.3 → 3.1 ms for fullscreen checks and 426.2 → 0.2 ms for
exact-window focus. The work-count reductions are the portable result.

## Live comparison

Both runs used an optimized Dev build on the same LG UltraFine at 3072 × 1728, with
the same 16 existing tracked windows. Time Profiler and Points of Interest were attached
for both runs. The probe made 16 alternating focus commands between two temporary windows.

| Metric | Before | After |
| --- | ---: | ---: |
| Native key-window notification, median | 50.087 ms | 35.937 ms |
| Native key-window notification, p95 | 134.571 ms | 116.157 ms |
| CLI completion, median | 44.945 ms | 47.642 ms |
| CLI completion, p95 | 138.952 ms | 135.964 ms |
| Failed commands / timeouts | 0 / 0 | 0 / 0 |

Native focus arrived about 28% sooner at the median in this small sequential comparison.
CLI completion did not improve at the median. Earlier input focus is the measured benefit;
this does not establish an app-wide speedup. Measurements include CLI process startup,
socket transport, target-app response, event delivery, and profiler overhead. They do not
measure screen presentation or physical hotkey/tab/group gestures. With 16 samples,
nearest-rank p95 is the maximum; system-load variation remains significant.

The updated trace contains exactly 16 light sessions. All 16 used cached fullscreen state,
and all 16 requested native focus after layout completed and before sidebar publication
started. Their phase timings were:

| Phase | Median | Maximum |
| --- | ---: | ---: |
| Native focus lookup | 0.890 ms | 50.841 ms |
| Fullscreen chrome state | 0.002 ms | 0.017 ms |
| Command body | 0.098 ms | 0.158 ms |
| Layout workspaces | 5.166 ms | 22.579 ms |
| Sidebar model | 2.407 ms | 6.739 ms |
| Tab model | 5.677 ms | 12.828 ms |
| Focus request to AX job start | 0.493 ms | 1.076 ms |
| Native focus job execution | 23.323 ms | 66.763 ms |

These phases can overlap; their medians must not be added. Native focus jobs completed
after their light sessions. Light-session median duration changed from 23.767 to 21.051 ms;
the maximum was essentially unchanged, 89.576 to 90.214 ms. The old light-session intervals
did not overlap in this recording, so that comparison is usable. Old full-refresh intervals
did overlap and are excluded.

## Validation

- All **667 tests passed** in the optimized local checkout, including separate sidebar/icon
  work outside this focus pass. The 10 new tests cover work counts, fullscreen entry/exit
  invalidation, normalization-cache reuse, nil focus, stale/superseded/failed reads, focus
  ordering, cancellation, and floating-window membership. A final focused rerun passed all 10.
- `make dev-build VERSION=0.0.0` built and signed the optimized Dev bundle. It was installed
  and left running. Strict signature verification passed with system trust-service access;
  the sandboxed verifier could not establish trust.
- All 16 tracked windows restored with zero unmatched windows; their IDs and the config
  fingerprint matched before and after. The Dev bundle identity and `WinMux-Debug` session
  directory were retained. Effective Accessibility access remained granted.
- The live geometry probe completed all 12 move/resize corrections without a timeout.
  This is a functional check; this pass did not capture a matched geometry-speed baseline.
- Shell syntax and `git diff --check` passed. The build-generated source files were restored
  to their pre-build contents.

Cache behavior during simulated fullscreen transitions is covered by regression tests;
native fullscreen animation/chrome presentation was not manually validated. Screen capture
remains unavailable, so flip-image capture and rendered animation timing remain unmeasured.

## Next investigations

The focus queue was short in this workload. Profile the individual operations inside the
native focus job and the long-tail native focus lookup across several real apps before
changing queue policy or dropping AX operations. Keep the per-app serialized queue and
fresh focus discovery: input targeting must remain correct when another app takes focus.

Repeat the phase trace for real tab/group gestures, including their animation and presentation
cost. Persistent model caches should follow evidence of expensive model construction and
complete invalidation rules; these live model intervals include publication work and should
not be equated with the earlier synthetic computation benchmarks.

Local evidence: `/tmp/winmux-focus-tests.log`, `/tmp/winmux-focus-tests-final.log`,
`/tmp/winmux-focus-unit-before.log`,
`/tmp/winmux-focus-build.log`, `/tmp/winmux-focus-before.log`, `/tmp/winmux-focus-after.log`,
`/tmp/winmux-focus-before.trace`, `/tmp/winmux-focus-after.trace`,
`/tmp/winmux-focus-comparison.json`, `/tmp/winmux-focus-phase-comparison.json`, and
`/tmp/winmux-focus-geometry.log`. These temporary files are local evidence, not repository assets.

## Reproduce

```sh
swift test --disable-sandbox -c release -Xswiftc -DDEBUG --filter FocusLatencyTest
make dev-test
make dev-build VERSION=0.0.0
./script/benchmarks/run-focus-probe.sh candidate > /tmp/winmux-focus-candidate.log 2>&1
```

The focus probe creates two temporary Cocoa windows in the active workspace, alternates
focus 16 times using the Dev CLI, then closes both and restores the previously active app.
Each sample records the receiving window's `didBecomeKey` notification separately from
the CLI process's completion. A sample fails on a nonzero command result or a two-second
timeout. Set `WINMUX_BENCHMARK_CLI` to use a different matching Dev CLI.

Keep the screen, app load, and profiling configuration the same across comparison runs.
Run compilation and other benchmarks outside the measurement interval. To inspect the
phases, record Time Profiler with the Points of Interest instrument attached to the running
WinMux Dev process while the probe runs. The trace includes discovery/cleanup and desktop
events outside the 16 commands; do not attribute its entire AX total to those switches.
