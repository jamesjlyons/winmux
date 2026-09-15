# Performance audit follow-up — September 15, 2026

The first pass is committed as `f944ea32` (`Optimize model refresh and session snapshots`).
This follow-up covers all six opportunities identified in
[the initial deep dive](performance-deep-dive.md). Four have targeted implementations;
two have additional profiling support and explicitly remain measurement-dependent.

## Implemented

### 1. Session disk work runs outside the main actor

`RestartSessionWriter` serializes equality checks, encoding, backup validation, and atomic file
writes on its own actor. The main actor still captures the live tree synchronously. Checkpoint
scheduling stays bounded to one pending/in-flight save, and a monotonically increasing revision
prevents an older checkpoint from overwriting a newer quit snapshot if tasks arrive out of order.

Shutdown captures the final snapshot before it yields, then awaits the writer before moving
windows for cleanup. Failed writes retain the previous successful snapshot and can retry.
Save status reports the timestamp actually persisted, including when identical content skips a
write. The existing file format, backup rules, and locked/read-only/restoring guards remain.

New tests cover late checkpoints, successful backups, unchanged content, failed-write retry,
changed destinations, and a deliberately blocked disk operation while the main actor keeps
running. New `Session snapshot` and `Session file write` signposts separate capture from I/O.

### 2. Sidebar panels receive one completed update

Changed workspace updates previously synchronized each active panel before workspace assignment,
again after assignment, and again inside `refreshAll`. The application path now chooses a single
refresh or sync after all shared fields are assigned. Monitor targets are resolved once per refresh.

Panel models no longer copy menu-bar text/items/workspaces or tab strips: the sidebar does not
read those fields, but their `@Published` writes invalidated its observed model. A Combine
regression test records zero sidebar notifications after a menu-text-only change and one after
a real sidebar-padding change. Local width and expansion state survive both synchronizations.
This measures model notifications, not SwiftUI render counts. `Sidebar panel sync` signposts
support measuring the remaining rendering cost.

### 3. Responsive title lookups no longer wait for a stalled app

Background title requests are tracked independently by window identity. New requests can start
while another request is suspended, and completed changes publish after a 16 ms coalescing delay.
There is one publication worker; completions arriving during a publication schedule its next
batch. No timer runs when there is no title work.

Request sharing, fallback titles, cache generation, and replacement-window checks remain. Reset
cancels both requests and pending publication. A regression test starts a suspended lookup,
then requests a second title and observes its publication before releasing the first lookup.
This validates the slow-app dependency directly, without timing a simulated AX response.

### 4. Visibility checks share minimized ownership and retained empty slots

Bulk visibility filtering builds the set of workspaces owning minimized windows once and lazily
resolves retained empty slots once per pass. A single-workspace retention lookup now checks its
own project. Retention calculation uses the ownership set for empty/anchor classification and
neighbor checks, avoiding repeated scans of the global minimized-window container.

The benchmark contains 96 groups across four projects, including 24 minimized windows and many
empty groups. Twenty samples use the same Debug build configuration on the same machine:

| Metric | Before | After |
| --- | ---: | ---: |
| Median visibility filtering | 82.090 ms | 0.541 ms |
| p95 visibility filtering | 91.399 ms | 0.558 ms |

This is about 99.3% less time in this synthetic stress case. Median is the middle sorted sample;
p95 uses nearest rank. No timing thresholds are asserted. A separate regression compares the
batched result with the original scalar rules across occupied, minimized, persistent, archived,
transient, and visible empty groups. The earlier occupied-group benchmarks continue to run.

## Remaining profiling decisions

### Broad model caching

Sidebar and tab signposts now include their triggering refresh event; individual workspace and
tab-group builds have separate intervals. The redundant title-cache prune in the outer tab
update was removed. Existing equality checks still suppress unchanged model publication.

A persistent cache keyed only by workspace ID would miss changes to title, focus, layout,
monitor assignment, configuration, and window lifecycle. This pass keeps rebuilding those
values until event-attributed traces justify a cache and its complete invalidation contract.
The measured problems above were addressed without introducing that lifetime risk.

### Double-sided flip capture

`Flip snapshot capture` measures the three synchronous image captures separately from panel
construction, animation, and focus switching. The installed Dev process reports Screen
Recording unavailable, so the animated capture path could not be measured live. Moving capture
past focus changes can alter the front/back images and background; that behavior needs visual
validation before changing execution order. No capture/animation speedup is claimed here.

## Validation

- **657 tests passed** in the complete local checkout, including eight added follow-up
  cases/benchmarks. This total includes separate sidebar/icon/reordering work outside this commit.
- The app and CLI built successfully; the Dev bundle passed strict signature verification.
- The updated Dev app restored all 16 saved windows with zero unmatched windows on first launch.
- `git diff --check` passed. Existing unrelated sidebar/icon/reordering edits were preserved.

Live checks on the signed updated Dev build:

- Two reopen cycles retained the same 16 window IDs; both reported 16 restored and zero unmatched.
- The temporary-window geometry probe completed 12/12 corrections with no timeouts: median
  48.162 ms, nearest-rank p95 66.405 ms. This is a smoke measurement, not a controlled speed comparison.
- The updated app completed graceful SIGTERM shutdown in 267.73 ms. The saved version, boot,
  world, window records, projects, and focus exactly matched the pre-quit checkpoint; cleanup
  did not leak into the persisted layout.
- The configuration SHA-256 hash was unchanged, Accessibility remained granted, and the installed
  app passed strict code-signature verification. Screen Recording remained unavailable.

## Reproduce

```sh
swift test --disable-sandbox --filter 'RestartSessionWriterTest|SessionWindowTitleTest|WorkspaceVisibilityBenchmarkTest|WorkspaceVisibilitySnapshotTest|WorkspaceSidebarPublicationTest'
swift test --disable-sandbox
swift build --disable-sandbox
```

Local evidence:

- `/tmp/winmux-audit2-visibility-before.log`
- `/tmp/winmux-audit2-final-tests.log`
- `/tmp/winmux-audit2-build.log`
- `/tmp/winmux-audit2-package.log`
- `/tmp/winmux-audit2-live-geometry.log`
- `/tmp/winmux-audit2-quit-result.json`
- `/tmp/winmux-audit2-doctor-final.txt`
