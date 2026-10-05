# Tab-style views: performance audit

One audit of the new window/view model and favicon build, starting at
`0357563d853c9eca3d175d1ceb9613651e8c16b9`. The scope was sidebar publication,
standalone-view scaling, owner reconciliation, image reuse, and idle helper work.
The test machine was an M1 Pro MacBook Pro with 16 GB RAM and macOS 27.0.1.

## Measured result

| Optimized sidebar workload | Before, median | After, median | Before / after p95 |
| --- | ---: | ---: | ---: |
| Refresh 50 standalone browser views | 9.29 ms | 0.34 ms | 9.45 / 0.45 ms |
| Refresh 200 standalone browser views | 73.47 ms | 1.11 ms | 74.18 / 1.18 ms |

The 200-view model workload is about 66 times faster. These measurements cover
building and reconciling sidebar rows, including the fresh browser projection;
they do **not** measure SwiftUI drawing, browser rendering, window presentation,
or the time until the destination accepts a keystroke. Each case uses one warmup
and ten timed passes, with the same synthetic tab/workspace counts and row
identity assertions. Compilation had completed before the final measurement.

The installed baseline helper consumed 0.021% of one CPU core during a 30-second
observation, with a stable sampled footprint of about 112 MiB. A five-second
stack sample found its main thread waiting in the event loop. That observation
does not show an idle CPU problem. It covers the helper alone, not Chromium or
whole-system battery usage. No before/after memory reduction is claimed.

## Findings and fixes

**Every unchanged view triggered whole-tree work.** `SurfaceTree.reconcile`
looked up each leaf across all workspaces and pruned all layout, selection, and
weight metadata on every sidebar refresh. The new model makes a workspace per
ordinary tab, multiplying that cost. Reconciliation now checks local membership
first and returns when nothing changed. Real arrivals, removals, transfers,
group collapse, and metadata cleanup retain their original behavior. The
tree-only fix reduced the 200-view median from 73.47 to 42.50 ms.

**Every row repeated inventory and process discovery.** Each workspace scanned
the entire browser inventory and placement table, and each browser row resolved
its running application. A sidebar refresh now builds one value projection of
unique owners, rows, app paths, and retained placements. All workspace rows use
that projection. The projection is created after asynchronous native reads and
consumed without suspension; it is not a persistent cache that can retain stale
favicons or ownership. Ambiguous owners remain excluded.

Favicon images already use a bounded shared cache, and unchanged sidebar state
is already guarded against repeated publication. This pass found no measured
reason to replace those mechanisms or change the interaction design.

## Validation and limits

- 948 Debug and 948 optimized Dev tests passed.
- 114 independent native-package tests and 69 Python checks passed.
- Regression coverage includes retained/disconnected leaves, metadata cleanup,
  duplicate-owner exclusion, fresh favicon data, and separate trial defaults.
- Dependency resolution left the lockfile unchanged.
- The final signed trial's native source hashes and helper digest matched the
  checkout. Archive extraction, file hashes, symlinks, executable permissions,
  and nested signatures are checked when preparing the download.

The audit used a live sample of the existing build and controlled model
benchmarks for the fixes. The final trial was not activated on this Mac; its
fresh startup, permissions, display behavior, and input readiness remain
acceptance checks on the destination Mac. No new compositor or hardware latency
claim is made.

Exact measurements and scope are saved in
[`evidence/2026-10-04-views-performance.json`](evidence/2026-10-04-views-performance.json).
Run `WorkspaceViewsPerformanceTest/testStandaloneSidebarRefreshBenchmark` in an
optimized Dev build to repeat the model workload. The
[`trial instructions`](views-trial-2026-10-04.md) describe the separate app/profile
and the behavior to try on the other Mac.
