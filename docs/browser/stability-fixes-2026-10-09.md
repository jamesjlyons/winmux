# Browser stability fixes — October 9, 2026

The three reproduced failures now pass the relevant bounded checks on the signed **stability-fixes RC5** candidate. The original report of the whole browser disappearing remains unreproduced. Long-duration qualification remains deferred.

The [original RC6 results](stability-results-2026-10-09.md) remain unchanged as the failure baseline. [Normalized follow-up evidence](evidence/2026-10-09-stability-fixes.json) records the accepted runs, intermediate failures, source hashes, and cleanup checks.

## Changes

**Renderer crash.** The preloaded omnibox WebUI could be marked visible even while its popup was closed. Resize and focus activity then accumulated presentation callbacks in a renderer with no presented popup, reaching the recorded callback-buffer assertion. The content view now starts hidden; the presenter reveals it before layout when opening and hides it when closing. The original build fails the closed-popup visibility regression, and the fixed build passes it.

Implementation: [hidden content lifecycle](../../browser/chromium/patches/0027-hidden-omnibox-content.patch) and [reveal before layout](../../browser/chromium/patches/0028-omnibox-reveal-before-layout.patch).

**35-page switching.** `surface focus` already updates selection and runs the light-session layout, sidebar, and persistence work. It now avoids scheduling a redundant full discovery pass after each focus command. Native-focus synchronization and the existing layout/focus fences remain in place. Tests cover browser selection, native destination placement, and accurate `surface focus selected` behavior.

Implementation: [SurfaceCommand](../../Sources/AppBundle/command/impl/SurfaceCommand.swift), [command regressions](../../Sources/AppBundleTests/command/SurfaceCommandTest.swift), and [session regressions](../../Sources/AppBundleTests/ui/SessionPerformanceTest.swift).

**Helper recovery.** launchd's default restart throttle accounted for the earlier recovery delay of about ten seconds. The production, managed, and validation launch agents now explicitly use a two-second throttle. Packaging records their hashes, and the recovery fixture reads the policy from the signed package rather than inventing its own interval.

Implementation: [launch policy](../../browser/native/com.jameslyons.winmux.browser.alpha.workspace.plist), [packaging](../../browser/tools/package_alpha.py), and [recovery fixture](../../browser/tools/test_browser_helper_recovery.py).

## Verification

| Check | Final result |
| --- | --- |
| Closed-popup lifecycle | Pass: 80 resize/focus cycles; closed popups stayed hidden and unfocused |
| Autocomplete | Pass: five native open/close cycles; each typed query verified through Accessibility |
| Video/feed/fullscreen | Pass: 108 feed actions, 27 fullscreen cycles, three native window cases; no unexpected renderer fatal error |
| Layout reply-loss recovery | Pass: original host and current geometry recovered |
| Helper restart, first run | Pass: **2.155 seconds**, same browser and surface identities, then 18 seconds stable |
| Helper restart, second run | Pass: **2.158 seconds**, same browser and surface identities, then 18 seconds stable |
| Native regression suite | **34 passed** |
| Browser tooling suite | **84 passed** |
| Build and package | Chromium build succeeded; package signature, bundled configuration, source and launch-agent hashes verified |

Two earlier full media replays of the same engine inputs also passed, each completing 108 feed actions, 27 fullscreen cycles, and three native cases. The final-package replay additionally verifies the changed helper focus path.

| Cohort | Measurement | Samples | Input-observation p95 | Unchanged limit |
| --- | --- | ---: | ---: | ---: |
| 35 pages, run 1 | Warm switch | 60 | **39.33 ms** | 50 ms |
| 35 pages, run 2 | Warm switch | 60 | **42.39 ms** | 50 ms |
| 35 pages, run 1 | Space switch | 60 | 39.54 ms | 150 ms |
| 35 pages, run 2 | Space switch | 60 | 43.41 ms | 150 ms |
| 20 pages | Warm switch | 60 | 49.77 ms | 50 ms |
| 20 pages | Space switch | 60 | 38.71 ms | 150 ms |
| 20 pages | Actual frozen return | 6 | 43.52 ms | 100 ms |

The original 35-page warm observation was 75.78 ms with 20 samples. The new runs enforce the speed gates with `--require-targets`. Timings include command and probe transport, and are not compositor presentation measurements. The 20-page warm result has little margin; these small sequential samples do not establish long-run percentiles. Web Lock freeze protection also passed.

## Retained diagnostic attempts

The renderer-only candidate still missed a repeated warm-switch gate at 52.27 ms, prompting the helper focus-path change. An intermediate optimization skipped native-focus synchronization and lost startup selection to the old native window; that optimization was removed. Its failed results remain in the evidence index.

The first final-candidate 35-page attempt completed page mapping but the environment observer rejected process identity before collecting latency samples. It is retained as an invalid measurement, separate from the two accepted runs. Observer errors now fail promptly and distinguish unavailable identity from executable mismatch; identity checks remain enforced.

The native test drivers were also corrected: the autocomplete sender stays alive until input is delivered, and fullscreen exit reveals auto-hidden controls with Tab before requiring a real Accessibility press on the exit button. Earlier driver failures are retained locally.

## Package, reproduction, and limits

Candidate: `.local/releases/browser-alpha-stability-fixes-2026-10-09-rc5/staging/WinMux Browser Alpha.app`.

Manifest SHA-256: `15dd4f50a910f7e82739ffd87eb7153a5db6a79bf13f28c76fcfd70d216ec439`.

Chromium remains pinned to `792bf6722e73a45aa9e47c163b9901bdc17f3230` (153.0.8010.53). This is a locally signed, non-notarized staged candidate. Existing unrelated native/sidebar edits were preserved and are fingerprinted in its manifest. Raw artifacts remain under `.local/browser-stability-fixes-2026-10-09/`.

Use fresh output directories with the [switching](../../browser/tools/test_browser_switch_speed.py), [media](../../browser/tools/test_browser_video_fullscreen.py), [popup](../../browser/tools/test_browser_failure_capture.mjs), and [helper](../../browser/tools/test_browser_helper_recovery.py) fixtures. The accepted settings were 35 pages with `--samples 60 --skip-freeze --require-targets`, 20 pages with `--samples 60 --require-targets`, media with `--cycles 3 --feed-cycles 6`, and popup with `--case popup-lifecycle`. Native-input fixtures require an unlocked console and exclusive native workspace ownership.

Helper process-death checks prove automatic transport/inventory recovery with an observe-only helper. Managed layout reply-loss recovery is a separate check. Authenticated Twitter/X playback, actual whole-browser disappearance, native hang-stack capture, sustained resource pressure, aged profiles, sleep/wake, multiple displays, and long-duration qualification remain outside this follow-up.

The daily workspace is ready again, its original browser path and browser surface identities are preserved, and no test executables remain running. The daily installation was not replaced. No long-duration tests were run.
