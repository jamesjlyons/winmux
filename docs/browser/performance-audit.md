# Group switching performance audit

This audit targets the Browser Alpha build used on October 3, 2026, including its native window manager, mixed workspace tree, sidebar, browser controls, Chromium host windows, and command transport. The source baseline is `e001f175`; all 611 source hashes in the installed package matched that checkout. The work is on `codex/performance-audit`.

## Measured outcome

The signed update is installed in `/Applications/WinMux Browser Alpha.app`. On this MacBook Pro (M1 Pro, 16 GB, macOS 27.0.1), 30 sequential warm switches through Groups 1, 2, and Recovered produced:

| Measurement | Before | After |
| --- | ---: | ---: |
| Command response, median | 80.5 ms | 26.8 ms |
| Command response, p95 | 102.9 ms | 39.4 ms |
| First matching window geometry, median | about 431 ms | observed by 101.4 ms |
| First matching window geometry, p95 | about 480 ms | observed by 136.1 ms |
| Final frame drift | 0 / 30 | 0 / 30 |
| Idle helper CPU, 10-second observation | 25.3% of one core | 1.1% of one core |

Command response improved about 3×. Window geometry settled substantially sooner, with the updated observation around 4× faster. The old trace timestamps precede the snapshot request; updated timestamps follow its completion. This is a conservative comparison of observation intervals, not a precise compositor latency claim. Neither number measures destination input readiness.

The three-switch before trace contains hundreds of intermediate scaled frames. Across the final 30-switch after trace, every observed browser frame matched its stable geometry: no scaling, overshoot, or positional drift. Incoming and outgoing groups may briefly overlap while native ordering completes; there is no artificial switch animation.

A separate 20-switch native/browser workload verified the pinned native app returned to the exact original frame and selected surface. Median command response was 38.9 ms and matching geometry was observed by 100.7 ms; p95 values were 77.7 ms and 162.4 ms. There is no comparable before measurement for that workload.

The CPU comparison was collected with compilation and benchmark activity stopped. The updated settings demonstrations were opened and closed before the idle sample; while visible they still animated. The later stack sample contains no MoveDemo/SplitDemo animation stacks. This measures only the helper, not Chromium's renderer processes or whole-system power. The resource collector's legacy fixed workload label describes an older transport-only use; these runs used the actual managed workspace. The process ages differ, so no memory-reduction claim is made.

## Findings and fixes

### Browser windows animated on every switch

Chromium gives its native windows Cocoa's document-window animation behavior. Hiding and showing a managed page consequently shrank, expanded, and bounced its WindowServer frame even when its layout had not changed. A three-switch geometry trace reproduced the effect: a page with a final width of 1,674 points appeared at widths of 1,644, 1,668, and 1,676 before settling. Outgoing pages also remained onscreen during their disappearance animation.

Managed hosts now use `NSWindowAnimationBehaviorNone`. WinMux saves and restores each window's prior behavior when releasing managed controls, including transitions to normal native fullscreen behavior. The host layout also skips matching bounds and unchanged visibility, and reveals incoming hosts before hiding outgoing hosts. Repeated updates no longer reorder already visible peers through `ShowInactive`.

### Native restoration waited on redundant Accessibility calls

A warm shared layout used to apply a native frame synchronously and then read it back on every return to a group. The helper now retains the last size the native app accepted. Returning to that size queues the real frame update on the app's serialized Accessibility queue without blocking the entire workspace on a repeated size probe. First layouts, new sizes, native geometry events, cancellation, and clamping retain verification. Resize notifications invalidate the accepted size even while a group is hidden.

The regression workload restores one native frame 20 times: blocking applications and observations drop from 20 each to one each, while all 20 necessary frame writes still happen. This measures work counts, not native application response latency.

Tiled parking reuses known layout geometry and shared visibility is computed once per workspace, instead of recomputing the surface plan for each native window.

### Floating positions and focus could move before settling

Parking now retains the exact floating frame. Returning to the same monitor preserves its position and size, including fractional coordinates and partial offscreen placement. Monitor changes use proportional relocation and bounds checks. A restored cross-monitor window bypasses the following redundant relocation pass; converting a tiled window to floating while hidden preserves the size explicitly chosen by that command.

Remembered native group targets and hidden native window rows record selection immediately but wait until their destination placement has been queued before raising the window. Focus generations, window identity, visibility, and intervening foreground-app changes prevent stale requests from raising the wrong window. Visible native window rows keep immediate activation.

### Switching rebuilt controls and performed unnecessary discovery

Native tab panels remain available while their containers live. Browser toolbar/backing pairs use a cache limited to 32 hidden pages, pruning closed pages and removing hidden controls from accessibility and keyboard interception. Unsubmitted address drafts return to the committed URL when a toolbar is shown again.

Unchanged panel frames, toolbar control state, symbols, background colors, and tab-shell geometry skip redundant native layout/redraw work. Tab indices and favicon decoding are reused; pin reconciliation runs once per sidebar snapshot. Repeated always-expanded sidebar refreshes do not publish unchanged model state. Project swipes dispatch immediately instead of waiting 120 ms for a transition delay.

Explicit sidebar group/monitor selection avoids an outgoing-app focus lookup and an unnecessary global discovery pass. Focus-relative commands continue using live native focus. Read-only command queries avoid layout, persistence checkpoints, and cancellation of ongoing discovery. Stateless queries also skip focus lookup.

Browser inventory and validated surface edits use one coalesced refresh task across suspension, with one trailing pass for new work. A regression holds the first pass suspended while submitting 1,000 updates: only two passes run, with no overlap. Browser-owned updates no longer add unrelated global Accessibility discovery or duplicate sidebar publication. Native app lifecycle and minimize events target their own process.

The global mouse-release discovery fallback remains: it recovers window creation and closure from applications with unreliable Accessibility notifications. Removing it without equivalent recovery would sacrifice correctness.

### Background settings animation and disconnected sockets consumed work

The live sample found settings demonstration timers continuing to animate a retained view after its window stopped being used. Demonstrations now run cancellable tasks only while their settings window is key, visible, unminimized, and not fully occluded, and respect Reduce Motion. The settings view remains retained so drafts and navigation are preserved.

The socket reader previously ignored clean EOF during a header or payload and repeatedly requested empty reads. It now terminates the incomplete request with a connection error. Loopback tests cover immediate disconnect, partial header, partial payload, and a complete response followed by EOF. Header decoding also supports unaligned storage.

## Measurement method and limits

The live probe switches existing Groups 1, 2, and Recovered sequentially and restores the original selected surface. It measures command response and the first WindowServer snapshot matching the expected visible window IDs and frames. It records no titles, URLs, page content, or screenshots. Compilation and browser validation should be finished before collecting comparable runs.

These are geometry/visibility measurements, not compositor presentation or destination input readiness. Snapshots and polling add several milliseconds of uncertainty. The saved probe now timestamps completed snapshots, rejects browser layouts that are not managed and acknowledged, and rejects identical or empty group baselines. It records missing matches, partial failures, and restoration errors rather than silently dropping them. The small sequential workload does not qualify every application, display, extension, or cold-start condition. Real native app response still depends on macOS Accessibility and the target application's own queue. Multi-display restoration has deterministic regression coverage; the live switching comparison uses one display.

Reproduce a run with the explicit current workspace socket, browser PID, and existing group names:

```sh
python3 script/benchmarks/run-group-switch-probe.py \
  --socket /tmp/your-active-workspace.sock --browser-pid 12345 \
  --groups 1 2 Recovered --samples 30 --output /tmp/winmux-switch-run
```

Add `--capture-frames` for per-snapshot window geometry. Each run requires a new evidence directory and an available selected surface to restore. The helper compiles before measuring.

## Validation and rollout

- Optimized app suite: **917 tests passed**, including rapid switching, focus interruption, native-frame caching/invalidation, fractional and cross-monitor floating restoration, toolbar retention, sidebar publication, browser-refresh coalescing, query refresh scopes, and socket EOF.
- Native bridge packages: **95 tests passed** (84 WorkspaceCore and 11 BridgeCore).
- Browser tooling: **39 tests passed**.
- Chromium rebuilt successfully. The signed package passed strict nested signature verification using the existing application identity.
- Two isolated signed-browser runs passed: 63 inventory/navigation/layout checks and 91 checks including native minimize, fullscreen, zoom, and restoration. Their temporary services were removed and the existing helper remained unchanged.
- All 613 packaged native source hashes and 28 Chromium overlay hashes matched the performance worktree. The engine build's inherited `native_revision` points to the parent of the staging archive; source provenance for this audit uses the explicit baseline and verified file hashes instead of that field.
- The original 12 surface identities, group assignments, selected surface, projects, pin data, complete surface tree, and configuration bytes were checked after installation. Set-backed saved-state arrays can serialize in a different order without changing their members.
- The previous signed app, native state, and browser profile were backed up before replacement. Work remains reviewable on `codex/performance-audit`.

### First-launch observation and discarded measurement

The first run after installation is excluded from performance results. Its browser layout was still unacknowledged: every group incorrectly produced the same all-visible baseline. Its apparent 13 ms response and near-zero geometry timing therefore did not measure functioning group switching. The probe now refuses that state.

The browser later acknowledged layout and normal group visibility resumed. A clean browser restart with the same helper/profile acknowledged layout immediately at the first observation and remained managed through a 20-second check. The one-time first-launch delay was not reproduced, and its cause is unresolved. No speculative scheduler change was made; cold-start behavior is not qualified by this warm-switch audit. A blank tab created by the restart diagnostic was verified and closed, and the original selected native app was restored.

### Local evidence

Evidence is retained under the main checkout's ignored `.local/performance-audit` directory: `evidence/app-tests-release.log`, `evidence/native-tests.log`, `evidence/tool-tests.log`, `engine-headless/result.json`, `engine-window-controls/result.json`, `evidence/switch-before.json`, `evidence/switch-animation-before.json`, `switch-after-final/results.json`, `evidence/mixed-switch-after-20/results.json`, `evidence/resources-before-clean.json`, `evidence/resources-after-settings-closed.json`, and `evidence/browser-restart-observations.json`. The invalid initial after-run remains separately labeled `switch-after/results.json` for diagnosis and must not be used in comparisons.
