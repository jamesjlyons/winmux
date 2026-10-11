# Bounded browser stability results — October 9, 2026

Follow-up: the [stability fixes and bounded reruns](stability-fixes-2026-10-09.md) address the three reproduced failures below. This page preserves the original failing run.

**The latest staged RC6 candidate fails the bounded stability gate.** A renderer assertion reproduced twice during the combined video/feed/window workload. The 35-page warm-switch observation also missed its speed target, and automatic helper recovery narrowly exceeded the proposed ten-second budget. The main browser survived both unexpected renderer failures; the user's reported whole-browser disappearance remains unexplained.

This run covers the short failure-capture, media, window/lifecycle, and performance work from the [test plan](stability-test-plan.md). Long-duration qualification was deferred at the user's request. These results do not qualify RC6 for daily use.

## Package and evidence

- Tested app: `.local/releases/browser-alpha-stabilized-2026-10-09-rc6/staging/WinMux Browser Alpha.app`.
- Package manifest SHA-256: `db723b4754f105b9393a6de194056321940ac99e6f721fb7541d6cfab7db7439`.
- Chromium: `153.0.8010.53`, pinned source revision `792bf6722e73a45aa9e47c163b9901bdc17f3230`.
- Tests used disposable profiles and uniquely scoped fixture services. Package signatures and manifest hashes were checked before execution.
- [Normalized evidence](evidence/2026-10-09-stability-short-tests.json) records outcomes, limitations, and hashes of raw result files. Raw logs, journals, dumps, and profiles remain locally under `.local/browser-stability-2026-10-09-run1/`; they are not committed or uploaded.

## Findings requiring follow-up

**Repeatable renderer crash.** Both visible feed/fullscreen runs logged:

```text
third_party/blink/renderer/platform/widget/compositing/layer_tree_view.cc:554
DCHECK failed: callbacks.size() <= cc::PresentationTimeCallbackBuffer::kMaxBufferSize (61 vs. 60).
```

The failed renderer identifies `chrome://omnibox-popup.top-chrome` as its loaded origin. The stack includes `blink::LayerTreeView::AddCallback`, `AddPresentationCallback`, and `ReportTimeSwapPromise`. The first run's dump is attributed to renderer PID 18526; the second log reports PID 22420. This supports a repeated callback-buffer assertion in the internal omnibox renderer, without establishing why the callbacks accumulate or whether the issue is specific to this fork.

The first run completed 108 feed actions, 27 video-fullscreen cycles across standalone/stack/split layouts, and three native fullscreen/release/close cases before the final log check rejected it. The replay added immediate fatal detection and a timestamped action journal. It stopped after 106 completed feed actions and 18 fullscreen samples, during split-layout feed step 34 with a focus action in progress. Both main browser processes were alive before fixture cleanup and then exited normally.

Evidence: [first result](../../.local/browser-stability-2026-10-09-run1/video-feed-fullscreen/result.json), [replay result](../../.local/browser-stability-2026-10-09-run1/video-feed-replay/result.json), [replay journal](../../.local/browser-stability-2026-10-09-run1/video-feed-replay/actions.jsonl), [retained dump metadata](../../.local/browser-stability-2026-10-09-run1/unexpected-renderer-crash/metadata.json), and [crash stack](../../.local/browser-stability-2026-10-09-run1/unexpected-renderer-crash/crash-stack.txt).

**Warm switching misses the 35-page target.** Its observed input p95 was **75.78 ms**, against 50 ms. The 20-page cohort met the sampled input targets. These timings are probe-based upper bounds, including observation overhead; they are not compositor presentation measurements. The sample counts are sufficient to flag this run's target miss, not to establish a stable population percentile.

**Helper recovery narrowly misses the budget.** Automatic XPC-demand relaunch and reauthentication took **10.145 seconds**, exceeding the proposed ten-second limit. The fixture completed the same-browser/same-surface checks and eighteen seconds of stable observation before its final budget assertion failed. This was an observe-only helper; restoration of managed native layouts after helper death is not established by this case. The earlier attempt hit a harness race from a redundant `launchctl kickstart -k`; it is retained as an invalid timing attempt, not counted as a product crash. The runner now relies on automatic relaunch and retains functional success separately from budget success.

## Coverage and outcomes

| Area | Outcome | Bounded evidence |
| --- | --- | --- |
| Failure attribution | Partial | Injected browser and renderer crashes produced correctly attributed local dumps. Renderer failure left the browser responsive; injected GPU failure produced a replacement GPU process. |
| Hang capture/recovery | Partial | Injected JavaScript loop detected in 2.501 seconds; browser survived and renderer recovered. JavaScript CPU samples retained. Native `/usr/bin/sample` timed out, so native hang-stack capture is still unproven. |
| Codec playback | Pass | MP4 H.264/AAC, Media Source H.264/AAC, and WebM VP9/Opus each decoded 82 video frames plus audio and reached the end. These are short pinned clips. |
| Feed and media transitions | Fail | Same unexpected renderer assertion in both runs. Playback/geometry success cannot override the crash. |
| Inventory, private/named profiles, restart | Pass | Isolated navigation/profile checks, cookie separation, history/persistence checks, and URL-free startup restoration. |
| Window controls and page menus | Pass | Native controls and five menu cases completed. Combined fullscreen workload remains failed because of the renderer crash. |
| Session restoration | Pass | Two expected user surfaces restored; unused prepared window excluded. This is controlled restart coverage, not full crash-session recovery. |
| Layout watchdog | Pass | One injected lost layout reply recovered the original host and latest geometry. |
| Lifecycle and network | Pass within scope | Five real policy-frozen returns in the 20-page run; Web Lock protection retained. Separate explicit CDP freeze/thaw retained a draft; offline/online and cancelled stalled navigation recovered. Three simulated pressure-notification cycles stayed responsive. |
| Helper death/recovery | Fail budget | Automatic recovery observed at 10.145 seconds; functional identity/inventory checks completed. |
| Switching | Mixed | 20-page input observations passed; 35-page warm p95 failed. See sample counts below. |
| Filter updates | Pass | Eight cases: fresh, exact 5 MiB limit, oversized first/second, malformed second, HTTP error, disabled, and recent cache. |
| Public sites | Blocked/incomplete | Twitter/X returned `net::ERR_HTTP_RESPONSE_CODE_FAILURE`. YouTube homepage loaded, but no playing video was observed. No authenticated feed playback was exercised. |
| Tooling regression suite | Pass | All 84 Python tests passed. Modified Python files parsed; Node runner syntax and patch whitespace checked. |

The original public-site result's `passed: true` recorded browser survival only. It is **not** a site-coverage pass; the normalized evidence marks X blocked. The runner has since been corrected to return blocked/failure for navigation errors. Likewise, the switching fixture's top-level `passed` is functional success; its separate `input_observation_targets` contains the failed 35-page speed gate. Raw evidence has been preserved unchanged.

| Cohort | Measurement | Samples | Observed input p95 | Target | Result |
| --- | --- | ---: | ---: | ---: | --- |
| 20 pages | Warm switch | 60 | 40.19 ms | 50 ms | Pass |
| 20 pages | Space switch | 60 | 35.68 ms | 150 ms | Pass |
| 20 pages | Actual frozen return | 5 | 96.39 ms | 100 ms | Pass, small sample |
| 35 pages | Warm switch | 20 | 75.78 ms | 50 ms | Fail |
| 35 pages | Space switch | 20 | 36.50 ms | 150 ms | Pass |

The 35-page run deliberately skipped the freeze wait. Neither run reaches the plan's 1,000-interaction qualification requirement. New-tab speed, sustained frame-drop rates, whole-process resource budgets, and compositor presentation latency were not requalified in this run.

## Reproducibility and remaining scope

The [fullscreen runner](../../browser/tools/test_browser_video_fullscreen.py) now supports `--feed-cycles` for deterministic seeking, pause/resume, source replacement, detach/reattach, playback-rate changes, and recycled/scrolled players. Fatal checks and the action journal preserve the failure phase. The [failure-capture runner](../../browser/tools/test_browser_failure_capture.mjs) adds disposable browser/renderer/GPU failure, JavaScript hang, network/lifecycle, and public-site cases. The [helper recovery runner](../../browser/tools/test_browser_helper_recovery.py) kills only its unique disposable helper service and checks automatic reconnection.

Use a fresh output directory for each replay, with the signed app above and the matching source tree:

```sh
python3 -B browser/tools/test_browser_video_fullscreen.py \
  --app '/path/to/signed/WinMux Browser Alpha.app' \
  --chromium-source '/path/to/pinned/chromium/src' \
  --output .local/browser/stability-feed-replay-NEW \
  --feed-cycles 6

node browser/tools/test_browser_failure_capture.mjs \
  --app '/path/to/signed/WinMux Browser Alpha.app' \
  --output .local/browser/stability-hang-NEW \
  --case renderer-hang

python3 -B browser/tools/test_browser_helper_recovery.py \
  --app '/path/to/signed/WinMux Browser Alpha.app' \
  --output .local/browser/stability-helper-NEW
```

The Node runner requires Node 22+ with built-in WebSocket; this run used the bundled Node 24.19.0 runtime. Visible fixtures require an unlocked console, input permissions, and exclusive native workspace ownership. Do not overlap native-input fixtures.

Next investigation should reduce the recorded omnibox callback failure, establish a matched upstream control, and capture an actual daily-use browser disappearance before assigning it the same cause. Native hang sampling still needs repair. OS-level memory-pressure escalation/clearance, sustained reclaim cadence, aged profiles, the installed extension set, authenticated Twitter/X video, sleep/wake, and multiple displays remain unqualified. Eight-hour, 24-hour, and 72-hour workloads were explicitly deferred.

The normal workspace was restored after exclusive fixtures, every pre-existing browser surface identity was retained, and no fixture processes remained at the final cleanup check. The daily installed browser was not replaced. No engine fix or release deployment was performed during this test run.
