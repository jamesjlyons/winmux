# Overall app speed — September 15, 2026

## Use optimized builds for everyday Dev use

The app installed for daily use came from `.build/debug/WinMuxApp`. The existing
SwiftPM build description selected `-Onone`; the Dev packaging script always copied
that binary. The production Xcode release workflow already uses Release configuration.

`make dev-build` now uses `swift build -c release -Xswiftc -DDEBUG` and packages the
matching executable, Sparkle framework, and resource bundles. `make dev-test` runs
the same configuration. SwiftPM's optimized configuration is documented in the
[Swift build guide](https://www.swift.org/documentation/server/guides/building.html).

The explicit `DEBUG` condition is required: `Common/appMetadata.swift` uses it for
the Dev identity, socket, and session directory, while `WinMuxApp.swift` uses it to
disable production automatic updates. Optimization and that app identity are independent.
The same signing identity, bundle identifier, and installation path are retained.

For debugger-friendly builds, use `make dev-build DEV_BUILD_CONFIGURATION=debug`
and `make dev-test DEV_BUILD_CONFIGURATION=debug`. Direct `script/dev-app.sh build`
keeps its historical Debug default; the Make target passes the chosen configuration
explicitly. The packaged Info.plist records `WinMuxBuildConfiguration`.
Optimized compilation takes longer; the Debug option remains available for rapid edit/debug cycles.

## Separate computation from app response time

The five-second baseline idle sample found the main thread waiting in the event loop
for all 3,794 samples. The sampled per-app Accessibility threads were also waiting.
There was no evidence of a persistent idle-work bottleneck in that interval.

The baseline doctor run measured individual Accessibility requests at about 22–26 ms
for four apps, with others around 0.4–1.4 ms. These are single observations of queued
cross-process calls, not stable per-app rankings. Faster compiled code can reduce
WinMux's processing around those calls; target-app response remains a separate cost.

## Measured computation improvement

The same five benchmark cases ran sequentially on the same checkout and machine, first
in Debug, then optimized with `-DDEBUG`. Source algorithms were unchanged. Each scenario
uses its existing 15–30 samples and asserts the resulting data; no timing threshold is asserted.

| Workload | Debug median | Optimized median | Speedup |
| --- | ---: | ---: | ---: |
| Sidebar model, 32 groups | 2.572 ms | 0.653 ms | 3.94× |
| Visibility filtering, 96 groups | 0.557 ms | 0.175 ms | 3.19× |
| Frozen snapshot, 256 windows | 0.609 ms | 0.135 ms | 4.50× |
| Tab model, 40 windows | 0.0139 ms | 0.0031 ms | 4.45× |
| Session comparison, 128 windows | 0.0327 ms | 0.0030 ms | 10.75× |

These measure computation in synthetic workloads. End-to-end interaction includes
Accessibility queueing, target-app response, and screen presentation. The small absolute
tab/comparison savings should be read alongside the larger sidebar/snapshot savings.

## Live window correction

The display changed from the built-in screen to an LG UltraFine during the first build.
Those initial before/after samples are not compared. The saved Debug bundle was then
reinstalled temporarily and the optimized bundle restored, preserving the session at
each graceful shutdown. Both comparison runs used the same LG display at 3072 × 1728,
the same 16 existing windows, and the same temporary test-window frame.

| Geometry correction, 12 samples per build | Debug | Optimized |
| --- | ---: | ---: |
| Median | 21.585 ms | 15.029 ms |
| p95, nearest rank | 38.315 ms | 24.913 ms |
| Timeouts | 0 | 0 |

The median was about 30% lower in this small comparison. This measures the time from
an external frame change until the test window's original tiled frame is observed again.
It does not measure actual screen presentation, drag latency, launch speed, or every app
interaction. The runs were sequential on a live desktop, so normal system-load variation
remains. The optimized bundle was left installed and running.

## Validation

- All **657 tests passed** in the complete local checkout under the optimized configuration,
  including separate sidebar/icon/reordering work outside this build-workflow commit.
- The initial run exposed an icon raster-color assertion that also failed in Debug with
  the exact same value (0.88849 vs an assumed minimum of 0.9). It now compares the icon
  with a solid sRGB control rendered through the same display profile, while retaining
  channel, opacity, template, and size checks. That test correction stays with the separate
  icon feature; it is not included in this build-workflow commit. App rendering code did not change.
- Shell syntax and the optimized/Debug Make target commands were checked.
- The corrected icon test also passed in Debug.
- `make dev-build VERSION=0.0.0` compiled and signed the optimized Dev bundle successfully.
- Every reinstall restored all 16 tracked windows with zero unmatched windows. The session
  path remained `WinMux-Debug/window-state.json`, Accessibility remained granted, and the
  configuration hash was unchanged. The installed bundle passed strict signature verification.

Local evidence is recorded in `/tmp/winmux-speed-debug-benchmarks.log`,
`/tmp/winmux-speed-release-benchmarks.log`, `/tmp/winmux-speed-benchmarks.json`,
`/tmp/winmux-speed-release-tests-final.log`, `/tmp/winmux-speed-icon-debug-final.log`,
`/tmp/winmux-speed-before.sample.txt`, and `/tmp/winmux-speed-dev-build.log`.
The live comparison is in `/tmp/winmux-speed-lg-debug-geometry.log`,
`/tmp/winmux-speed-lg-optimized-geometry.log`, and `/tmp/winmux-speed-lg-comparison.json`.

## Further work, in priority order

1. **Extend the [focus responsiveness pass](focus-performance.md) to tab/group gestures.**
   Exact-window focus now has a repeatable native key-window probe and detailed phase
   signposts. Light sessions request changed native focus immediately after layout and
   reuse event-invalidated fullscreen state. Capture repeated tab/group gestures next;
   command-driven key-window timing does not measure their full animation/presentation path.
2. **Reduce Accessibility queue delays where traces show them.** Preserve one serialized
   queue per app, cancellation of superseded frame jobs, and geometry corrections.
   Any further batching needs to retain origin correction after resizing and size correction
   when moving across displays.
3. **Cache only model values with complete invalidation rules.** The optimized model
   timings establish a lower baseline for deciding whether persistent caches are worthwhile.
   Titles, focus, frames, config, monitor assignments, and lifecycle can all change a row.
4. **Profile the image-capture path with Screen Recording available.** The current process
   lacks that permission. The existing flip-capture signpost is ready; changing capture
   ordering still needs image and animation validation.

## Reproduce

Run benchmarks sequentially under similar load:

```sh
swift test --disable-sandbox --filter 'ModelRefreshBenchmarkTest|WorkspaceVisibilityBenchmarkTest'
swift test --disable-sandbox -c release -Xswiftc -DDEBUG --filter 'ModelRefreshBenchmarkTest|WorkspaceVisibilityBenchmarkTest'
make dev-test
make dev-build
```

For a live geometry sample, use `./script/benchmarks/run-geometry-probe.sh` with an
unlocked session and Dev running. It temporarily creates, moves, resizes, and closes
one window. Record median, nearest-rank p95, and timeouts. Keep compiler work and
other benchmarks out of the measurement interval.
