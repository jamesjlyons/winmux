# Startup and interaction performance audit

This audit targets the Browser Alpha build used on October 3, 2026, including its native window manager, mixed workspace tree, sidebar, browser controls, Chromium host windows, and command transport. The source baseline is `e001f175`; all 611 source hashes in the installed package matched that checkout. The work is on `codex/performance-audit`.

## First-pass measured outcome

The first signed update was installed and measured in `/Applications/WinMux Browser Alpha.app`. On this MacBook Pro (M1 Pro, 16 GB, macOS 27.0.1), 30 sequential warm switches through Groups 1, 2, and Recovered produced:

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

## First-pass validation and rollout

- Optimized app suite: **917 tests passed**, including rapid switching, focus interruption, native-frame caching/invalidation, fractional and cross-monitor floating restoration, toolbar retention, sidebar publication, browser-refresh coalescing, query refresh scopes, and socket EOF.
- Native bridge packages: **95 tests passed** (84 WorkspaceCore and 11 BridgeCore).
- Browser tooling: **39 tests passed**.
- Chromium rebuilt successfully. The signed package passed strict nested signature verification using the existing application identity.
- Two isolated signed-browser runs passed: 63 inventory/navigation/layout checks and 91 checks including native minimize, fullscreen, zoom, and restoration. Their temporary services were removed and the existing helper remained unchanged.
- All 613 packaged native source hashes and 28 Chromium overlay hashes matched the performance worktree. The engine build's inherited `native_revision` points to the parent of the staging archive; source provenance for this audit uses the explicit baseline and verified file hashes instead of that field.
- The original 12 surface identities, group assignments, selected surface, projects, pin data, complete surface tree, and configuration bytes were checked after installation. Set-backed saved-state arrays can serialize in a different order without changing their members.
- The previous signed app, native state, and browser profile were backed up before replacement. Work remains reviewable on `codex/performance-audit`.

### Second pass: startup starvation and additional interaction work

The first run after installation is excluded from performance results. Its browser layout was still unacknowledged: every group incorrectly produced the same all-visible baseline. Its apparent 13 ms response and near-zero geometry timing therefore did not measure functioning group switching. The probe now refuses that state.

The deeper audit reproduced the startup failure by restarting both the helper and browser with the saved native pin selected. Authenticated inventory arrived, but the browser left its pages unmanaged for more than 30 seconds. Opt-in bridge phase logging showed that layout requests reached the XPC endpoint; later requests waited before their Chromium UI task began. This rules out a missing helper refresh as the sole cause of that captured failure.

Chromium's startup scheduler trace identified strict-priority starvation. In the retained browser-main interval, 12.655–15.358 seconds after the trace began, all 13,715 task selections chose `UI_STARTUP_TQ` at highest priority. The enabled, unfenced normal queues retained thousands of tasks, including pending layout work. Compositor and Mojo callbacks continually replenished the startup queue. There were no recorded application-task-disallowed events in that interval. The trace's ring buffer did not retain the earlier main-thread interval, so these counts describe the captured interval only.

The source explains this starvation. `content/browser/browser_main_loop.cc` routes Mac resize/compositor work to the highest-priority startup queue when `PrioritizeResizeTaskRunnerOnStartup` is enabled. `content/browser/scheduler/browser_task_queues.cc` restores its normal priority only after startup completes. The completion and failsafe tasks in `chrome/browser/after_startup_task_utils.cc` themselves use the normal queue. The feature defaults off, but `WebUIReloadButtonStudy` in `testing/variations/fieldtrial_testing_config.json` enables it. Unbranded Chromium applies this testing configuration by default, as specified in `components/variations/service/variations_field_trial_creator.cc`.

A controlled launch disabling only `PrioritizeResizeTaskRunnerOnStartup` completed layout with zero layout timeouts. The selected production fix is `disable_fieldtrial_testing_config = true` in the shared Chromium GN configuration, so ordinary launches use upstream feature defaults rather than the bundled developer experiment configuration. This covers direct browser launches as well as the setup flow. The generated buildflag affects 71 already-built objects plus their archives and final link, rather than a global recompilation. The final GN build is installed and qualified below; the measurements above describe the earlier signed update. No message-pump or GCD scheduling bypass is part of the fix.

The second pass also addresses independent issues:

- The refresh scheduler retains inventory received before native startup is ready and explicitly resumes it at readiness. Startup waits for the pass covering work already queued, while later inventory continues through the coalescer; continuous browser events cannot make readiness wait for the entire browser to become idle. Empty startup-command lists no longer request another global discovery pass.
- A missing layout reply can no longer block every later layout indefinitely. The adapter uses deadlines of 1, 2, and 4 seconds, permitting at most three attempts for an unchanged plan and inventory revision. A retry sends the latest plan with a fresh generation; late callbacks cannot acknowledge it or replay obsolete focus. New groups or inventory receive a fresh budget, including changes arriving during the last attempt. Uncertain failure invalidates the previously acknowledged frame. Navigation, creation, and close are not replayed by this watchdog.
- Optimistic sidebar selection preserves pinned-group metadata and pin tiles until the asynchronous refresh completes, preventing a temporary disappearance of the pinned section.
- Chromium obtains each page's current browser owner directly through `TabInterface`, removing repeated global browser/tab scans from host placement while still following ownership changes after detachment. Browser focus removes a second activation after `Show()` already activates the host, and ordinary tile resizes avoid a duplicate host-state update while owned zoom transitions retain reconciliation.
- The sidebar clock wakes every minute when seconds are hidden and every second when they are displayed.
- Event subscribers use one ordered writer per client with a maximum of 128 queued/in-flight events. A stalled reader no longer accumulates an unbounded task per event; overflow or failure closes only that connection, cancels the socket, and unregisters the subscriber. Initial snapshots use the same ordered queue.
- Organize view no longer polls at 60 Hz while idle. Its autoscroll timer starts for a held drag and stops on mouse release, hidden/occluded/minimized state, detachment, or dismantling. Late callbacks cannot restart a dismantled view, and an active timer does not spawn another task on every pointer event.
- Initial monitor policy no longer schedules global native discovery immediately before startup's explicit discovery pass. Display-change discovery and its settled recovery pass remain intact. Configuration reload already gates live discovery until readiness; normal persistence coalesces checkpoints and writes through the existing background writer.
- Setup checks readiness every 100 ms for the first 10 seconds of a requested automatic browser launch, removing the previous up-to-one-second handoff delay. It then returns to the existing one-second cadence if permissions remain pending. One timer is retained; launch, failure, cancellation, and closure end the fast cadence. Every launch still validates the request, signed package, service, and live helper.

Deterministic regressions cover early inventory, readiness during a suspended trailing pass, pin preservation, missing and late layout replies, retry exhaustion, newer work arriving during the final attempt, and reconnection. The signed-browser layout fixture also checks repeated visibility changes for stable native window identities and exact frames. The final package passed the regression suites and installed runtime checks below.

### Final installed results

The final signed app is installed in `/Applications/WinMux Browser Alpha.app`. Three complete helper/browser restarts used the original profile, normal Start Workspace action, and no diagnostic feature or field-trial command-line overrides. The first two restored the native pin selection; the third restored browser Group 2. Each restored all **11 original browser surfaces**, reached acknowledged managed geometry, and remained settled for the rest of its 20-second observation, with **zero layout timeouts**.

| Full process restart | Helper ready observed | Complete managed geometry observed |
| --- | ---: | ---: |
| Native pin, first launch after installation | 1.10 s | 4.90 s |
| Native pin, repeat launch | 0.88 s | 4.58 s |
| Browser group selected | 0.82 s | 4.50 s |

Times start immediately before dispatching the Start button action and end after the completed read-only observation. They include UI dispatch and polling overhead and are upper observation bounds. These are process-cold restarts with OS disk caches retained, not a clean-profile, reboot, page-content, or input-readiness benchmark. Previously the reproduced fault left all browser pages unmanaged beyond 30 seconds, with requests remaining queued for minutes in another trace.

With compilation and validation fixtures stopped, the final installed switching runs produced:

| Workload | Samples | Command median / p95 | Matching geometry median / p95 | Frame drift / missed matches |
| --- | ---: | ---: | ---: | ---: |
| Groups 1, 2, Recovered | 30 | 22.5 / 34.4 ms | 89.6 / 114.2 ms | 0 / 0 |
| Native pin ↔ browser surface | 20 | 25.5 / 44.2 ms | 82.4 / 127.4 ms | 0 / 0 |

All **1,034 observed browser frames** in the group-switch trace matched their stable expected geometry; there were no intermediate scaled or displaced managed browser frames. The mixed run restored the native window to its exact original bounds and restored selection. Final idle helper CPU averaged **0.79% of one core over 10 seconds**, compared with the original 25.3% observation. This is a short single-process observation with the workload and limitations described above, not whole-browser energy or memory qualification.

The probes now anchor geometry to inventory-reported host IDs and separately retain auxiliary Chromium windows. They reject added, removed, unavailable, reassigned, or replaced surfaces outside the timed polling loop. One validation run initially misclassified an auxiliary 258×22 Chromium window as a managed page; its position matches Chromium's status-bubble placement, but its window class was not captured. The actual managed host stayed at its expected frame. Another fixture run queried a bound socket before it accepted connections. Both failed evidence sets are retained. Regressions now cover auxiliary-window accounting, missing/replaced/drifting hosts, and bounded read-only startup readiness. Connection failures during the actual recovery test still fail immediately.

Final verification:

- **1,096 automated tests passed**: 930 optimized app tests, 107 native tests (96 WorkspaceCore and 11 BridgeCore), and 59 browser/tooling tests.
- The exact signed package passed **65 browser protocol/navigation outcomes** and **93 outcomes including native controls and 20 repeated exact-frame switches**. Isolated services were removed and the existing setup process remained unchanged.
- The real managed-workspace lost-reply fixture passed with one timeout, automatic recovery observed 2.55 seconds after fixture startup, no reconnect, unchanged host identity, and 19 stable WindowServer snapshots over two seconds. This timing includes fixture startup; it is not the watchdog deadline itself.
- All **615 native source hashes**, **28 engine overlay hashes**, and build-configuration provenance match the actual worktree. The package manifest digest is `4f5977d00885454b2ab36b6051b2898c36013bd787f370be3fe34a0d22767dfc`. Nested signatures and the installed binaries were verified. The engine manifest records parent commit `27cd99f1` plus dirty source hashes; it does not claim the later audit commit was already built.
- All original **12 surface identities**, assignments, availability, selection, projects, native window identities, pins, complete surface tree, and configuration bytes match the pre-audit state. The workspace-name set is unchanged despite serialization order. The closed-tab history additionally records two diagnostic blank tabs created and then removed during earlier investigation; no original tab was removed.
- The previous app, native state, and browser profile were backed up before replacement. The final workspace remains running with the original native pin selected.

The alpha engine still enables `DCHECK` diagnostics and expensive debug assertions despite optimized compilation. This audit makes no performance claim from disabling those checks or from an untested release configuration.

### Local evidence

Evidence is retained under the main checkout's ignored `.local/performance-audit` directory: `evidence/app-tests-release.log`, `evidence/native-tests.log`, `evidence/tool-tests.log`, `engine-headless/result.json`, `engine-window-controls/result.json`, `evidence/switch-before.json`, `evidence/switch-animation-before.json`, `switch-after-final/results.json`, `evidence/mixed-switch-after-20/results.json`, `evidence/resources-before-clean.json`, `evidence/resources-after-settings-closed.json`, and `evidence/browser-restart-observations.json`. The invalid initial after-run remains separately labeled `switch-after/results.json` for diagnosis and must not be used in comparisons.

Second-pass startup evidence includes `second-pass/startup-before-1/observations.json`, `second-pass/startup-trace-1/browser-phases.log`, `second-pass/startup-scheduler/chromium-trace.json`, and the compact `second-pass/startup-scheduler/trace-analysis.json`. The trace analyzer is `second-pass/analyze_startup_trace.py`; build dependency evidence is `second-pass/fieldtrial-build-dependents.json`.

Final qualification evidence is under `second-pass/final`: `startup-summary.json`, the three `cold-*/observations.json` traces, `normal-launch-flags.json`, `switch-groups/results.json`, `switch-groups/frame-audit.json`, `switch-mixed/results.json`, `resources-idle.json`, `session-comparison.json`, `source-verification.json`, `engine-headless/result.json`, `engine-window-controls/result.json`, `layout-watchdog/result.json`, and `rollout/install.json`. The auxiliary-window and startup-socket fixture failures are retained in explicitly named sibling directories. Final suite logs are `second-pass/app-tests-shipping.log`, `second-pass/native-tests-shipping.log`, and `second-pass/tool-tests-shipping.log`.
