# Browser stability and performance test plan

Make video playback, ordinary browsing, and WinMux page windows reliable under sustained use. The immediate reported failure is **the whole browser disappearing**, particularly while watching videos or browsing Twitter/X. First identify the terminating process and capture its failure; then reproduce it with controlled workloads and require stability and speed gates before release.

This is the test program and initial investigation as of October 9, 2026. The reported browsing crash remains undiagnosed. Passing short fixtures does not qualify a browser for daily use.

The [October 9 bounded RC6 run](stability-results-2026-10-09.md) reproduced an unexpected renderer crash twice and missed the 35-page warm-switch target. Long-duration work remains deferred.
The subsequent [fix verification](stability-fixes-2026-10-09.md) records passing bounded reruns for that renderer failure, 35-page switching, and helper recovery.

## Findings that determine priority

- The active Chromium process was running `.local/page-menu-fix/package/WinMux Browser Alpha.app`. Its executable and bundled helper matched that package's manifest. The October 9 stabilized candidate is a separate package; the running package's lifecycle policy hash differs from the current checkout. Test the actual running build and the candidate separately before attributing an improvement to a fix.
- Local Crashpad storage contained 16 dumps: 14 browser-process reports and two renderer reports. **All 14 browser reports contain a test-service flag.** The latest, October 8 at 21:59:46 Pacific, resolves to `ShouldEnableCommand` in the saved-tab-group menu, consistent with the documented menu command collision. These reports cannot be counted as the user's daily-use crashes. Attribution of the renderer reports is unresolved.
- Earlier test dumps include zero-sized native-window assertions, shutdown access violations, a filter-download size assertion, preference registration failures, and a locked shortcuts database. Include those failure paths in regression coverage; a shared exception address alone is insufficient to group root causes.
- The October 9 stabilization record describes an excessive page-discard cadence under pressure, followed by fixes requiring a five-second cooldown and fresh memory metrics. Its short follow-up did not exercise another pressure-driven reclaim. A 35-page workload exceeded the existing 8 GiB browser footprint guard. Sustained media plus lifecycle activity needs direct coverage.
- The latest recorded new-tab input p95 was **222.73 ms for blank pages and 259.64 ms for cached pages**, above the 100 ms goal. The successful 20-page switching observations did not establish compositor presentation latency or 35-page residency.
- The current checkout's lifecycle policy test, four fullscreen fixture tests, and five interaction-evaluator tests passed during this investigation. Those ten checks validate policy and test infrastructure, not live browser stability.

Sources: [local triage evidence](evidence/2026-10-09-stability-investigation.json), [stabilization record](evidence/2026-10-09-stabilization.json), [menu crash record](evidence/2026-10-08-page-menu-fix.json), and [existing browser test instructions](../../browser/README.md).

## First establish dependable failure capture

Create an isolated runner that records an immutable package manifest, Chromium revision, overlay and helper hashes, build flags, matching debug symbols, macOS version, hardware, display modes, power state, extension versions, and filter versions. Track each process by PID **and launch identity**, including the browser, GPU, renderers, network utility, and workspace helper. Keep a separate identity for the test run and each action.

Record browser termination status, helper exit/disconnect events, renderer crashes, GPU restarts, and window inventory. Distinguish browser exit, deliberate quit, helper loss, hidden/unmanaged windows, renderer failure, and a hung browser. A visible disappearance is the symptom; process and window evidence must establish which happened.

Use a bounded local event journal with the last 60 seconds of actions, tab lifecycle states, fullscreen transitions, memory/CPU samples, and browser/helper logs. Preserve it immediately on failure. Keep URLs, page text, and credentials out of normal breadcrumbs; store raw dumps locally with restricted access. Preserve the existing no-upload behavior. The current privacy patch changes crash-reporting settings, but dumps still exist: verify local capture experimentally rather than assuming that a running Crashpad handler proves coverage.

Before trusting the runner, deliberately crash one disposable browser, crash one disposable renderer, and stall a disposable page. Verify the right process, dump, timeout, and preceding action survive each failure. Distinguish these injected incidents from unexpected failures. Check for late crashes during test teardown as well as during the workload.

An independent observer must detect loss of the browser even if the page-side script or helper also dies. For a suspected hang, retain timed thread samples and process state before terminating only the fixture. Start with a five-second local input/heartbeat timeout; hidden and intentionally frozen pages have different heartbeat expectations. Ordinary network loading must not look like a browser hang.

**Exit condition:** every injected failure is detected and produces a useful, correctly attributed evidence bundle. Do this before long unattended runs.

## Workload matrix

Use deterministic local fixtures for reproducible failures, then repeat representative workflows on real sites. Test browser content within the actual WinMux toolbar, sidebar, window ownership, and workspace pipeline. A page controlled entirely through browser automation misses native focus and window bugs.

| Area | Workload | Required observations |
| --- | --- | --- |
| Basic browsing | Address entry and autocomplete, navigation redirects, back/forward, reload/stop, new/duplicate/close/reopen tabs, find, text selection, clipboard, zoom, downloads, upload cancellation, PDF, print preview, popups, permissions, menus, DevTools | Correct destination and focus; stable tab/window identity; responsive input; no crash or unintended loss of state |
| Video and audio | MP4 H.264/AAC, Media Source playback, WebM VP9/Opus; muted autoplay and audible playback; seek, pause/resume, loop, source replacement, different rates, 720p/1080p/4K where supported; one and multiple players | Actual decoded frames and time advancement; audio continuity; decoder errors, dropped frames, buffering, GPU/CPU use; unsupported formats fail gracefully |
| Feed browsing | Local infinite feed with recycled video elements, lazy images, autoplay on visibility, source detach/reattach, rapid scrolling, embedded frames, and SPA history; Twitter/X as a separate real-site case | No browser exit, leaked players, accumulating surfaces, permanent blank content, or scroll/input stalls |
| Window transitions during media | Standalone, stack, split, floating, and pinned views; tab/Space switching; rapid resize and drag; minimize/restore; video fullscreen, native green-button fullscreen, Escape, Picture in Picture, close while entering/exiting fullscreen | Playback and input remain valid; exact host identities and expected restored geometry; no stale callbacks or orphan windows |
| Page lifetime | 1, 12, 13, 20, 35, and 50 pages, with 100 as a stress tier; background waits spanning two and fifteen minutes; return to warm, frozen, and discarded pages | Observe real lifecycle transitions, not elapsed time alone; protected media/forms/calls/uploads/Keep Active pages survive; eligible pages reclaim and recover correctly |
| Adverse network | Fixture-controlled slow responses, offline/online, DNS failures, dropped media segments, stalled downloads, redirects, and retry storms | Recoverable page errors; browser controls stay usable; cancellation/closure releases resources |
| Profiles and persistence | Shared, named, and private profiles; same- and cross-profile moves; private final-window close; repeated launch/quit; fixture browser crash and restore; update from a previous profile format | No profile crossing; no duplicate or missing saved tabs/pins/layouts; private-state behavior preserved; expected crash restoration documented |
| Extensions and blocking | Clean profile, normal blocker settings, actual supported extension set, individual isolation runs, native messaging, and filter updates while feeds play | No browser abort; correct media behavior; bounded CPU; failures attributed to a component rather than hidden by disabling it |
| Graphics and calls | Canvas/WebGL animation alongside video; WebRTC with synthetic camera/audio; screen capture on the test desktop; GPU restart in a disposable session | Browser and unrelated pages survive child-process failure; visible recovery; calls/capture prevent inappropriate lifecycle reclamation |
| Machine transitions | Lock/unlock, sleep/wake, battery/AC, audio-device changes, display connect/disconnect, 60/120 Hz and scaling changes | Correct focus/layout/audio recovery; no stale hosts; resumed inputs reach the selected page |

Use pairwise coverage for the broad matrix, plus exhaustive repetitions for **media × window transition × lifecycle state**, where the reported workload overlaps WinMux-specific code. Separate unsupported feature failures from crashes; document each supported capability explicitly.

Real-site runs use public content or a dedicated test account. Include Twitter/X video feeds, a long-form video site, a static article, an image-heavy site, an editor/form, and a web-call fixture. Record workload steps and network conditions. Do not post, message, purchase, or use personal account state as test data. If a site requires authentication or is unavailable, mark that case blocked; its synthetic equivalent does not silently pass it.

## The first focused reproduction

1. Preserve the running package identity and the staged candidate identity. Run both against the same fresh fixture and then a seeded, aged synthetic profile. Keep the user's daily browser session available.
2. Start with the existing MP4, Media Source, and WebM clips in visible, hardware-accelerated windows. Repeatedly scroll them into and out of view, seek, replace the source, switch tabs, and resize the window. Reproduce any reported Twitter/X sequence separately.
3. Repeat in a stack and split, entering/exiting video and native fullscreen, moving to another Space, minimizing, reopening, and closing during a transition. Use fixed action seeds and record the delay between actions. Complete 1,000 bounded media/window transition cycles per candidate across at least three runs.
4. Add 20 and 35-page cohorts, then allow real background freezing and discarding. Drive controlled memory pressure on a test machine and clear it. Verify at most one policy reclaim per interval, fresh metrics before another reclaim, no continued pressure-driven discards after pressure clears, and media/form protection. Keep ordinary aged-page discards distinct from pressure-driven ones.
5. On any unexpected exit, stop that case, preserve the process tree and failure bundle, and replay its exact seed. Reduce the action sequence until it becomes a small regression fixture. Compare current versus candidate; then vary one component at a time: managed versus standalone windows, blocker state, extensions, or hardware acceleration. Diagnostic variants narrow causes; release qualification still uses normal settings.

A matched upstream Chromium control helps determine whether a failure comes from the fork. Match revision, codecs, build configuration, and workload; the existing archived control has configuration differences, so it is not automatically a valid performance comparator. Diagnostic sanitizer builds can investigate lifetime faults, while timing gates use the signed optimized configuration intended for users.

## Run frequency and release gates

The durations and new thresholds below are initial acceptance budgets. Measure harness overhead and noise on each test host, fix the budgets before candidate comparison, and do not relax them to make a failing candidate pass.

| Stage | Execution | Gate |
| --- | --- | --- |
| Every change | Existing `make check`, applicable Chromium regressions, and checks for each minimized crash reproduction | All required tests pass; no excluded failing regression |
| Every signed candidate | Visible browsing/media/menu/fullscreen/session suite on an unlocked dedicated Mac; planned 30–60 minute smoke workload | Zero unexpected browser/helper/renderer crashes, GPU resets, input timeouts, lost tabs, wrong-profile moves, or layout corruption |
| Nightly qualification | Eight-hour mixed workload, at least 10,000 recorded actions, 20/35/50-page cohorts, fixed and varied seeds, memory-pressure and recovery scenarios | Complete evidence; zero unexpected failures; bounded resources; all lifecycle and recovery invariants pass |
| Release qualification | 24-hour mixed soak per required hardware/OS configuration, plus one 72-hour run on the primary daily-use configuration; dedicated real-site sessions | No unexpected crashes or unrecovered hangs; no state loss; speed and resource gates pass independently |
| After a fix | Replay the reduced case 100 consecutive times, restore it to the mixed suite, and repeat the affected qualification tiers | Failure eliminated on the candidate, with no new regression or test suppression |

Initially include the current M1 Pro/16 GB class, a newer Apple Silicon Mac, the oldest OS actually claimed as supported, and a current OS. Add single- and multiple-display runs, normal extensions, and power-state variants. A declared minimum macOS version needs qualification on that version or a narrower support claim. Run native input suites sequentially on each console, since concurrent fixtures compete for focus.

Intentional failure tests have separate gates: injected renderer/GPU failure must not terminate the browser or unrelated pages; helper loss must recover ownership and input; injected browser termination must restore the documented saved session. Start with a ten-second local recovery budget and record each stage. Network reload time is reported separately. A successful automatic restart does not erase an unexpected crash from the stability result.

Count completed sessions, actions, browser-hours, failures by process, and reproducible failure signatures. Retain failed and interrupted runs. Zero observed crashes is a release requirement for the defined workload, not proof that arbitrary browsing can never crash.

## Speed and resource acceptance

Measure at the beginning and end of long runs to expose degradation. Use at least 1,000 interactions per category across multiple runs for switching qualification, and the existing three runs of 100 blank plus 100 cached-page creations for new tabs. Record median, p95, p99, maximum, and missing/failed samples. Keep warm, frozen, discarded/reloaded, process-cold, and network-dependent cases separate.

| Measurement | Acceptance target | Evidence |
| --- | --- | --- |
| Warm page switching | Input-ready p95 ≤50 ms; p99 ≤100 ms | Native input received through actual WinMux action to destination keyboard acknowledgement; compositor presentation measured separately |
| Frozen page, native window, mixed view | Input-ready p95 ≤100 ms | Same correlated action chain; actual lifecycle state recorded |
| Space switching | Input-ready p95 ≤150 ms | Selected destination receives input and is presented correctly |
| Selection feedback | p95 within two display frames: ≤16.7 ms at 120 Hz or ≤33.3 ms at 60 Hz | Presented selection feedback |
| Blank and locally cached new tab | Input-ready and presentation p95 ≤100 ms each | Existing tab-speed instrumentation, plus full sidebar/shortcut discovery path |
| Sustained video | Initial target <1% dropped frames after startup for an individually specified 1080p60 fixture; no unexpected playback stall >1 second on local media | Decode counters plus playback time, audio and compositor evidence; keep seek/pause/fullscreen transition windows explicit |
| Long-run latency | Still meets absolute targets, with no >10% p95 degradation from the settled beginning of the same workload | Fixed page cohort, same action mix, paired runs; investigate noisy comparisons |
| Memory and process lifetime | No orphan fixture processes or accumulating windows/players; settled footprint after repeated open/close cycles stays within the predeclared budget | Per-process physical footprint and process count; initial leak tripwire is >max(10%, 100 MiB) growth between matched settled cohorts after a 30-minute warm-up |
| CPU and energy | Initial guard: no >10% sustained CPU or energy regression versus a matched control for fixed idle/playback workloads | Whole browser process tree and helper measured separately; thermal and power conditions retained |

The existing latency targets come from [`qualify_interactions.py`](../../browser/tools/qualify_interactions.py) and the [tab-speed fixture](../../browser/tools/test_browser_tab_speed.py). Video, long-run resource, and recovery budgets are proposed additions. Calibrate 4K, multiple streams, and high-tab-count stress tiers separately. The policy's 8 GiB threshold triggers reclamation; it is not an acceptable memory target for every workload.

An IPC reply, a matching window rectangle, and a `requestAnimationFrame` callback are different from a presented frame. Require a correlated compositor trace for presentation claims and an actual input probe for readiness. Faster geometry alone cannot pass the user-visible speed gate. Do not pool retry successes while dropping failed attempts or their latency.

## Reuse and implementation order

1. **Failure capture and attribution.** Add the run journal, process observer, bounded resource collection, symbol/archive retention, and injected-failure self-checks. Keep capture overhead measurable and uploads disabled.
2. **Media/feed fixture.** Extend `test_browser_media.py` and `test_browser_video_fullscreen.py` with a deterministic video feed, seeking/source churn, multiple streams, long playback, and a seeded action runner. Reuse the existing isolated profile, test service, and PID-scoped native input patterns.
3. **Lifecycle and stateful stress.** Compose inventory, window controls, session restoration, switching, and layout-watchdog fixtures. Add pressure escalation/clearance, child-process failure, helper recovery, aged profiles, and state invariants after every action. Existing `test_browser_recovery.py` invalidates an XPC connection; it does not simulate a helper crash.
4. **Performance and resource gate.** Extend `measure_helper.py` coverage to the whole browser process tree, use `observe_environment.swift`, and retain separate presentation/input measurements. Integrate them into a single machine-readable result with pass, fail, blocked, and incomplete states.
5. **Dedicated Mac qualification lane.** Add signed-package smoke checks and long-run jobs beyond the current unit-test CI. Serialize physical input, retain artifacts for every failure, and publish a compact result tied to the exact package hash. Every crash fix adds a permanent small regression and returns to the combined stress workload.

Useful existing starting commands, using a new output directory for every run:

```sh
make check

python3 -B browser/tools/test_browser_media.py \
  --app '/path/to/signed/WinMux Browser Alpha.app' \
  --chromium-source '/path/to/pinned/chromium/src' \
  --output .local/browser/stability-media-run-001

python3 -B browser/tools/test_browser_video_fullscreen.py \
  --app '/path/to/signed/WinMux Browser Alpha.app' \
  --chromium-source '/path/to/pinned/chromium/src' \
  --output .local/browser/stability-fullscreen-run-001

python3 -B browser/tools/test_browser_tab_speed.py \
  --app '/path/to/signed/WinMux Browser Alpha.app' \
  --output .local/browser/stability-tab-speed-run-001 \
  --runs 3 --samples 100 --require-targets
```

Visible fixtures require an unlocked console, the required Accessibility/input permissions, and available native workspace ownership. Run disruptive pressure, sleep/display, and injected-failure cases on a dedicated test desktop with synthetic profiles. Bounded feed, injected-failure, and helper-death fixtures are now implemented; see the [first run and replay commands](stability-results-2026-10-09.md). A unified long-run observer, soak workload, native hang-stack capture, full resource/presentation instrumentation, and qualification automation still need work.
