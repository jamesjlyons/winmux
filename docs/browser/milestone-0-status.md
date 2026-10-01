# Milestone 0 implementation status

**Performance qualification is deferred by the user. Chromium and a signed alpha
with authenticated helper communication and native request/cosmetic blocking
build and launch. Proceed directly to tab/native-window integration. Extension
compatibility is accepted for this phase.**
On October 1 the user asked to "move on to the winmux tab and window integration,
we can optimize perfomance after that right?" This changes the implementation
order: remaining baseline/qualification work no longer blocks Milestones 1–2.
No unperformed performance checks are marked passed. A later `speedometer-3`
control trial lost foreground and the batch stopped itself; its score is excluded,
and its isolated browser/server processes exited. Do not restart benchmarks.

Active implementation has moved to [tab and native-window integration](milestone-1-status.md).
Typed native sidebar selection, versioned surface persistence, and actual
Chromium tab/profile identity restoration are implemented and tested there.

The independent native components below are built and exercised. On October 1
the user explicitly accepted the extensions for
this phase ("move on from the extension testing. they're good"). Stop extension
testing and treat its remaining scenarios as deferred, not implementation
blockers. Preserve the observations below without claiming unperformed tests
passed; continue browser/workspace integration.

## Browser/helper connection recovery — 2026-10-01

- The browser now reconnects after XPC interruption, invalidation, rejected
  negotiation or timeout. Retries run on its serial background queue with
  1, 2, 4, 8, 16 and capped 30-second backoff. Each attempt keeps the exact
  Apple team/browser/helper signing checks, negotiates a fresh epoch and probes
  the helper before reporting authentication. Generation checks discard stale
  callbacks and prevent duplicate failures from scheduling duplicate retries.
- The four-job optimized build and Personal Team packaging succeeded. The new
  verified staging package is
  `.local/browser/packages/alpha-recovery-1/WinMux Browser Alpha.app`.
  It has **not** replaced the installed `alpha-blocking-1` browser or its open
  compatibility session. Helper enrollment remains explicit, and the browser's
  conventional tab strip remains available.
- A separate signed, headless Chromium process authenticated, invalidated only
  its own connection through an opt-in diagnostic, and authenticated again on
  generation 2. It then stayed authenticated for **17.04 seconds**, beyond both
  negotiation timers. The enrolled helper's process identity was unchanged;
  only the test browser was stopped. No signed-in browser UI was inspected.
- The C++ state-machine probe passes stale reply, duplicate error, old timer,
  capped backoff and backoff-reset checks. All 35 existing Python checks pass.
  This proves client-connection recovery in the actual signed browser; actual
  helper crash/restart and prolonged service outage remain untested. It does
  not qualify latency, UI behavior or native-window management.

[Recovery result, source hashes and package provenance](evidence/2026-10-01-browser-recovery.json).
Reproduce with `browser/tools/test_browser_recovery.py`; it requires a new
profile/output directory and verifies the staged package and existing helper
identity before running. This recovery checkpoint predates the active
[native surface integration](milestone-1-status.md).

## Initial control startup and tab-presentation trace — 2026-10-01

- A fresh synthetic profile in the signed upstream control produced Chromium's
  own startup and tab-presentation trace events. Its single **Lukewarm** launch
  reported browser first paint at **857.073 ms**, first contentful paint at
  **931.501 ms** and nonempty paint at **1006.933 ms**. These markers do not
  establish usable or input-ready completion.
- Sixteen switches reported successful presentation of saved frames:
  **51.044–66.987 ms**, median **57.914 ms**. The native recording brackets that
  switching interval with continuous control foreground, AC power, nominal
  thermal state and a stable 60 Hz external display. The full recording also
  includes the expected pre-foreground startup period, which its checker flags.
- AX was inspected between switches; a synthetic input echo was confirmed once
  before switching, not timed per switch. The existing alpha remained running
  in the background. These observations are a development baseline, not the
  input-ready p95/p99 gate, a startup distribution or a matched alpha comparison.
  The isolated control process has exited; existing profiles were preserved.

[Trace events, synthetic fixture and environment evidence](evidence/2026-10-01-control-timing.json).
The earlier Speedometer runs used the laptop's 120 Hz display, so future paired
measurements must establish matching display conditions afresh.

## Initial paired browser baselines — 2026-10-01

- A loopback runner now serves the pinned local Speedometer 3.1 assets and
  exports the original completion callback's full metrics automatically. All
  suites and ten iterations use upstream timing defaults. Native observation
  ends when the result arrives; no accessibility inspection occurs during a run.
- Four trials ran in control/alpha/alpha/control order, each with a fresh test
  profile, the same launch flags and a 1500 × 863 page viewport. Package
  signatures, Chromium revision, GN arguments and signing identity match the
  intended control/alpha comparison. Sandbox and site isolation were preserved.
- The first pair scored **control 4.1363; alpha 4.1740** (alpha +0.91%). The alpha
  repeat scored **4.1695**. These three trials recorded consistent foreground,
  display, AC power and nominal thermal conditions. The final control scored
  3.9653 but is **excluded**: its display mode became unavailable and the browser
  lost foreground focus. There is no accepted repeated-control comparison yet.
- The benchmark removes its focused iframe before its completion callback;
  all four raw exports record `hasFocus=false` at that boundary. The analyzer
  distinguishes this known boundary from focus/visibility interruption events.
  It retains the raw warning, and still rejects the native focus/display failure.
- Fresh blank-tab snapshots after at least 30 seconds reported **445.81 MiB
  alpha versus 422.72 MiB control**, a **23.09 MiB** difference, using Apple's
  physical-footprint accounting for each browser and its descendants. This is
  one snapshot per browser, excluding the separate helper and reparented crash
  handlers; it is not unique-memory, peak-memory or full-workload qualification.
- These are preliminary baselines on the 16 GiB development Mac, with other
  desktop apps running and no user extensions in the measurement profiles.
  They show no slowdown in the valid first pair, but do not establish the 5%
  repeatability gate. Startup, switching, longer memory/CPU observations and
  the representative mixed workload remain open. Extension testing stays deferred.
- Thirty-five Python checks pass, including interval coverage, transient focus
  interruptions, invalid scores and asset identity. Swift 6 compilation with
  warnings as errors and both measured packages' deep/strict signature checks pass.

[Baseline report and raw evidence](evidence/2026-10-01-browser-baselines.json).
Reproduce with `speedometer_fixture.py`, `observe_environment.swift` and
`summarize_speedometer.py` under `browser/tools`. The first fixture attempt was
discarded after a directory-URL serving bug and display change; the corrected
runner successfully served all suites. The remaining control repeat and UI
timing work require available, stable display/foreground conditions.

## Restart checks and benchmark environment recorder — 2026-10-01

- After the user deferred further 1Password testing, the signed alpha quit
  cleanly and reopened the same `alpha-compatibility` profile with
  `--restore-last-session`. All seven test tabs returned. Readwise's saved-page
  toolbar and one existing highlight returned; Cosmos's authenticated private
  collection picker remained available without a login prompt. No new Cosmos
  save was submitted in this restart check. The browser authenticated with the
  existing helper again. This covers a clean restart, not crash/update recovery.
- A standalone Swift recorder now streams process identity, app-foreground
  observations, activation/sleep events, AC/Low Power Mode, thermal state and
  display modes. It never reads AX/windows/browser content, activates an app or
  changes system settings. Its checker flags missing data and interrupted or
  inconsistent conditions; it never qualifies a benchmark or milestone.
- Swift 6 compilation with warnings as errors passed. Twenty-eight Python
  tests pass. A real five-second recording of an agent-owned `/bin/sleep`
  process correctly failed the foreground condition, rejected the wrong
  executable before creating output and refused to overwrite prior evidence.
  This validates recorder plumbing, not browser performance. The app-foreground
  observation still needs correlation with the full benchmark interval and
  separate evidence for tab visibility, background workload and repeatability.

[Restart evidence](evidence/2026-10-01-extension-restart.json) and
[environment recorder proof](evidence/2026-10-01-environment-recorder.json).

## Preliminary helper resource observation — 2026-10-01

- A read-only collector observed the already enrolled transport helper for
  300.003 seconds after a 15-second settling period, sampling every five seconds.
  Its physical footprint stayed at **3,981,816 bytes (3.80 MiB)**. Kernel CPU
  counters showed no increase during the window. Apple's `footprint` utility
  independently reported the same byte count.
- This is one transport-only helper on the 16 GiB development Mac. It does not
  qualify the full workspace workload, browser process tree, startup, switching,
  energy, or integration overhead against the control. No app UI was operated
  by the collector, and it did not read browser profiles or process arguments.
- The collector converts Mach CPU ticks using the system timebase (125/3 here).
  A short self-process cross-check agreed with Python's process CPU clock within
  0.023%. It rejects process replacement, counter regression, system sleep,
  excessive sample gaps and incomplete windows. Nineteen Python tests pass,
  including six resource-measurement checks.

[Raw samples, package provenance and validation](evidence/2026-10-01-helper-resources.json).

## Required extension functionality accepted for this phase — 2026-10-01

- The verified `alpha-blocking-1` package is also installed at
  `/Applications/WinMux Browser Alpha.app`. It passed deep/strict verification
  after copying. Existing WinMux and its profiles were not replaced.
- A separate `alpha-compatibility` profile has the official Chrome Web Store
  extensions installed through their normal permission prompts. The Extensions
  UI confirms all three are enabled: 1Password **8.12.38.34**, Readwise Highlighter
  **0.18.3**, and Save to Cosmos **6.15.3**. Their onboarding/login UI renders.
  Developer mode is off; no repackaged or sideloaded extension was used.
- The user reported sign-in to all three extensions, then confirmed sign-in to
  1Password for Mac **8.12.38**. Its signature and notarized Gatekeeper assessment
  passed previously. The browser extension shows its unlocked account UI. Its
  supported Mac-app connection remains unverified: Add Browser was disabled at
  the earlier check. The user explicitly deferred further 1Password testing on
  October 1 and asked to move on. Treat this as deferred acceptance, not a blocker
  for continued implementation; do not repeat the pending setup request.
  Automatic approval review had rejected a full native-app window read because
  it could expose private entries; no credentials were extracted.
- Readwise saved the public Chromium project page through its toolbar, created
  a highlight and retained it after a page reload. Cosmos saved that page and
  its public logo image to an existing private collection, including the native
  image context-menu action. Both saves showed confirmation. Account details,
  private collection names and saved-document identifiers are excluded from
  committed evidence.
- Further extension scenarios are deferred by the user's acceptance above.
  Matched browser performance reports remain open.

[Extension installation evidence and exact versions](evidence/2026-10-01-extension-installation.json).
[Partial functional results](evidence/2026-10-01-extension-functionality.json).
The open browser uses `--user-data-dir` pointing to
`.local/browser/profiles/alpha-compatibility` in this worktree; launching the app
without that argument opens its separate default alpha profile.

## Signed control and benchmark export smoke test — 2026-10-01

- `package_control.py` signs a copy of the archived upstream build with separate
  control identifiers and the same Personal Team identity/upstream signing
  policy as the alpha. `signed-control-2` passed deep/strict and exact-identity
  verification. Original executable, framework and manifest hashes remained
  unchanged. The packager refuses output inside the archive, including symlink
  aliases, as well as stale pins/configuration or downstream components.
- The control launched a separate empty `control-benchmark` profile, rendered
  Speedometer 3.1, completed its 10-iteration suite, exported its full JSON and
  quit cleanly. The displayed score was **3.89 ± 0.13**. This is only a benchmark
  execution/export smoke test: other applications were running, accessibility
  was inspected during the run, uninterrupted foreground focus was not recorded,
  and required extensions were absent. There is no matched alpha run, regression
  conclusion or performance acceptance claim.
- Twenty-three Python tests pass, including four new control packaging checks.

[Package provenance and smoke-test limitations](evidence/2026-10-01-signed-control.json).

## Native browser blocking proof — 2026-10-01

- The signed `alpha-blocking-1` package passed all seven live-page checks:
  normal requests/content work; direct ad requests, redirects and worker requests
  are blocked; initial cosmetic matches and later nodes matching the same
  selector are hidden. Server-side counts confirm no blocked target was fetched.
- The identical fixture in the preserved upstream control fetched all three ad
  targets and left both placeholders visible. Both runs used fresh, separate
  profiles and mapped test domains to a loopback-only server. No ad-domain
  traffic or synthetic product filter rules were used.
- Request decisions run in Chromium's network service. Pinned EasyList and
  EasyPrivacy are embedded in the native Rust library, verified before building,
  and compiled on a background sequence before requests resume. Renderer
  cosmetic queries use document-scoped Mojo, derive the URL in the browser,
  evaluate rules off its UI thread, and apply declarative user-origin CSS.
  Sandbox and site-isolation settings remain unchanged; network sandbox and
  renderer seatbelt arguments were observed in the live processes.
- The blocker ships as a separately signed library inside Chromium Framework.
  Static Rust linkage exceeded Apple's compact-unwind personality limit; the
  dynamic library links and runs in the browser and sandboxed child processes.
  The entire package passed deep/strict signature verification and exact identity
  checks. The actual browser also authenticated with the previously enrolled
  `alpha-transport-3` helper; registration was not repeated for this package.
- Thirteen Python tests, five Rust tests, Rust formatting and Clippy pass. The
  build wrapper now accepts only a verified prefix of the owned patch series,
  and packaging checks all patch, overlay, native-blocker and artifact hashes.
- This completes the **small request/cosmetic integration proof**, not the full
  blocking feature set. Newly introduced DOM tokens, profile/site switches,
  replacements/rewrites, WebSocket interception and rule updates remain pending.
  Browser performance reports remain open. The user subsequently accepted
  extension compatibility for this phase and deferred the remaining scenarios,
  including 1Password Mac-app integration.

[Signed blocker and upstream-control comparison evidence](evidence/2026-10-01-browser-blocking.json).
Reproduce with `browser/tools/blocking_fixture.py`; its source documents the
loopback mapping. The current verified app is
`.local/browser/packages/alpha-blocking-1/WinMux Browser Alpha.app`.

## Chromium build and signed alpha — 2026-10-01

- The pinned optimized upstream build completed all 56,885 actions in
  6 h 34 m 30.55 s of active build time. The manifest records four compiler jobs,
  the pinned source/tools, Apple linker, and this Mac's hardware. The browser
  launched with a separate `control-smoke` profile and rendered an HTTPS page.
- The untouched control output is archived at
  `/Users/james/Documents/Codex/winmux/.local/browser-engine/chromium/src/out/WinMuxControlBaseline`.
  The original output path is now the alpha's working build cache. Siso records
  output-directory paths, so cloning to a different working directory caused a
  broad rebuild; that attempt was stopped. Keeping the existing cache reduced
  the first successful alpha link/build to six actions and 34.31 seconds.
- The downstream overlay connects the actual browser process to the native
  helper through asynchronous, mutually authenticated XPC. It attempts helper
  enrollment only with `--winmux-register-helper`, and only a correctly signed
  alpha bundle can connect. The conventional tab strip remains available while
  the helper is still a transport proof without a workspace organizer.
- The alpha packager embeds the Swift helper and its SMAppService LaunchAgent,
  applies separate alpha identifiers, and uses Chromium's generated per-process
  signing options and entitlements. The package passed `codesign --deep --strict`
  and exact Apple-anchor/team/identifier checks. Personal Team signing is for
  local development; this package is not notarized.
- The signed browser launched with a separate `alpha-transport-smoke` profile.
  SMAppService enrolled and launched its packaged helper. The actual Chromium
  process negotiated and exchanged the authenticated asynchronous probe, then
  repeated it after a clean restart without the enrollment flag. A same-team
  probe with the wrong signing identifier was rejected by the registered helper.
  The signed browser rendered a local fixture and accepted keyboard/button input.
  Request blocking and renderer cosmetics were verified in the later checkpoint
  above. Extension compatibility was subsequently accepted by the user for this
  phase; browser performance reports remain pending.
- Thirteen Python tests pass, including protection of unrelated Chromium edits,
  resumable owned patches, exclusion of concurrent builds/packages, and rejection
  of failed/stale build provenance.

[Completed control-build and launch evidence](evidence/2026-10-01-chromium-control.json).
[Signed browser/helper integration evidence](evidence/2026-10-01-alpha-transport.json).
Build/package logs and private alpha artifacts are under `.local/browser/`.

## Resume on a second Mac — 2026-09-30

- Recovered `9318ca3060e581bdd48136de1f6dc856feeaaeca` from the pushed
  `codex/chromium-browser` branch and verified the full approved plan's checksum.
- Active worktree: `/Users/james/.codex/worktrees/chromium-browser/winmux`.
- Engine directory: `/Users/james/Documents/Codex/winmux/.local/browser-engine`.
- APFS preflight passed with 364.32 GiB free; the earlier storage blocker is
  resolved on this computer. The pinned Chromium source, dependencies and hooks
  completed. GN generated the optimized control build and four-job local
  compilation is running; no completed browser artifact is claimed yet.
- Hardware: `MacBookPro18,1`, arm64, 16 GiB RAM, 10 logical CPUs; macOS 27.0.1,
  Xcode 27.0, Swift 6.4, and locally installed Rust 1.97.1.
- All 19 existing automated tests passed here (10 Python, 4 Swift, 5 Rust).
  The C++ blocker probe passed, the Objective-C++ bridge probe compiled, the
  helper plist validated, and Rust formatting/Clippy checks passed.
- Xcode automatic signing created an Apple Development certificate for the
  selected Personal Team (`F7QMMNZWXX`). The public certificate's team and SHA-1
  fingerprint were verified, and the exact identity is saved in the ignored
  `.local/browser/signing.env`. After Keychain authorization, the Xcode test app
  built and its signature verified with the expected team. The signed native
  XPC process proof passed all five cases, including the duplicate/stale-message
  checks inside the authorized exchange, and all four Swift tests passed again.
  The temporary LaunchAgent was removed. Browser integration and signed alpha
  packaging remain pending.
- The build command now accepts `--jobs 4` to bound local compiler concurrency
  and records the limit and hardware in the completed build manifest. This Mac
  is a separate test environment from the plan's 36 GiB M3 Pro; its component
  results do not qualify browser performance on either machine.
- The first GN invocation exposed a missing depot_tools Python bootstrap:
  `DEPOT_TOOLS_UPDATE=0` also skips that automatic initialization. The build
  wrapper now runs upstream `ensure_bootstrap` when needed without updating the
  pinned tool revision. The resumed GN invocation succeeded and compilation
  started. The 10 Python checks still pass after this correction.
- The pinned LLVM linker rejected the Xcode 27 SDK's `arm64e.x1` TAPI targets.
  The native arm64 configuration now uses upstream-supported Apple's linker
  (`use_lld = false`); compilation resumed past the failing link. Later alpha
  comparisons must use the same linker setting.
- Overnight monitoring on October 1 found closed-lid and maintenance sleep
  interruptions despite the build's idle-sleep assertion. A temporary
  `caffeinate -s -w <build-process-pid>` assertion was attached to the live build
  on AC power. `pmset` confirmed `PreventSystemSleep`, and compilation continued
  through the follow-up check. The assertion releases when the build exits;
  no persistent power settings were changed. This is not a completed build.

[Local component evidence](evidence/2026-09-30-local-components.json) and
[Personal Team signed XPC evidence](evidence/2026-09-30-native-bridge.json).
Current download/compiler logs are under `.local/browser/` in the active worktree.
To repeat the signed proof on this Mac, run
`source .local/browser/signing.env` followed by
`python3 browser/tools/test_native_bridge.py` from that worktree.

The remaining sections preserve the original September 19 checkpoint.

## Checkout and environment

- Isolated worktree: `/Users/jameslyons/.codex/worktrees/87a9/winmux`.
- Branch: `codex/chromium-browser`.
- Starting commit: `ff1fdd70bb4769e925e7e84196a1e35423ccad65`.
- Saved checkout remains clean on `main` at that same commit. Existing WinMux
  binaries, configuration, sessions, and browser profiles were not changed.
- Complete approved plan: [approved-plan.md](approved-plan.md), 627 lines,
  SHA-256 `1cb27a24132b7eea8c4827dc3632bb88b2270a2abc3146a41340a7f8e2d08c16`.
- Live hardware: `Mac15,6`, 36 GiB RAM, 12 logical CPUs, arm64.
- macOS 27.0 (26A428), Xcode 27.0 (27A266a), Apple Swift 6.4, Rust 1.97.1.
- Apple Development signing was available and used for the native process proof.

## Built and verified

### Native control plane

The standalone helper builds in release mode and exposes a small Objective-C
protocol to an Objective-C++ probe. Both sides enforce Apple's code-signing
requirement at the XPC connection, including team and exact process identity.
There is no PID-only authentication and no synchronous XPC call.

Four Swift tests passed. The real signed-process test passed these cases:

1. Authorized client exchanges asynchronous messages with the helper.
2. Duplicate sequence and stale epoch messages are rejected.
3. A same-team client with the wrong signing identifier is rejected by XPC.
4. An ad-hoc client fails closed before opening the connection.
5. A subsequent healthy client still works after rejection.
6. The client rejects a same-team helper with the wrong signing identifier.

The temporary LaunchAgent is removed after the test. The helper intentionally
does not start AX window management while the original WinMux is running.
SMAppService registration code and the bundled LaunchAgent plist compile, but
registration inside the final browser package is **not verified**.

[Raw native evidence and source hashes](evidence/2026-09-19-native-bridge.json).

### Built-in blocker component

The release Rust static library uses pinned `adblock-rust 0.13.3` with a locked
dependency graph. It is linked into and exercised from a real C++ executable.
The repository bundles compressed, checksum-pinned EasyList and EasyPrivacy
snapshots with attribution and license text. Rule text is compiled outside
request evaluation; queries perform no disk/network/XPC work.

Five Rust tests and the native ABI probe passed: network matches/exceptions,
per-site disable, request types, cosmetic selectors and dynamic token deltas,
cosmetic exceptions, malformed-input handling, bundled-only replacements,
continued use of the prior instance after a rejected replacement, and concurrent
queries. The only replacement resource currently bundled is `empty.js`.

Measured with full lists plus deterministic synthetic test rules, four concurrent
threads, 40,000 requests per run, three runs:

| Run | p95 evaluation | p99 evaluation |
|---|---:|---:|
| 1 | 0.031958 ms | 0.053041 ms |
| 2 | 0.031625 ms | 0.054416 ms |
| 3 | 0.031792 ms | 0.054334 ms |

Initial compilation measured 50.285 ms. These are **native adapter
microbenchmarks on the development machine**, not added latency measured in
Chromium, not a concurrent live-page workload, and not milestone acceptance.
There is no network-service hook or renderer applying these cosmetics yet.
Procedural cosmetics, additional bundled scriptlets, updating rules, persistent
profile/site exceptions, and the blocking toolbar remain pending.

[Raw blocker evidence, list hashes and source hashes](evidence/2026-09-19-blocking.json).

### Build and qualification tools

The upstream control configuration pins Chromium Mac stable `153.0.8010.53`
(`792bf6722e73a45aa9e47c163b9901bdc17f3230`) and depot_tools
`0306e4682b4ac35287c726fa35a983157a625902`. GN uses an optimized, non-component
arm64 build and retains symbols, sandboxing and site isolation. Fetch/build
commands reject insufficient storage, non-APFS volumes, and unrelated/dirty
checkouts. These commands have not completed an upstream fetch/build.

The trace evaluator preserves six distinct focus stages and visible selection.
It requires 1,000 interactions per switch category across multiple runs, build
provenance, enabled required extensions/blocking, and labeled presentation/input
evidence. It evaluates supplied traces; it does not collect or independently
authenticate that evidence. Its fixtures are unit tests, never performance
measurements. Its successful result can qualify only the covered interaction
metrics, never the whole milestone or daily driver.

Ten Python tests passed (build safety and qualification), Rust formatting and
Clippy passed, and the bundled plist passed `plutil`. No native WinMux production
files were changed, so the existing native application's suite was not rerun.

## Open Milestone 0 gates

| Required deliverable | Current state |
|---|---|
| Isolated checkout | Complete |
| Reproducible optimized Chromium build | Complete on the second Mac; immutable control archive retained |
| Separately built native helper | Control plane built; existing workspace runtime not integrated |
| Signed top-level app and embedded helper | Private alpha packaged; full signature verification passed |
| Authenticated helper communication | Signed exchange, clean browser restart, wrong-client rejection and client-connection recovery verified; actual helper crash recovery remains open |
| Direct Chromium rendering | Control and signed alpha launch; performance not qualified |
| Required extension installation, authentication, usage, profiles, updates, restart | Accepted by user for this phase; recorded partial checks stand, remaining scenarios deferred |
| 1Password Mac-app / Touch ID integration | Deferred by user; browser account unlocked and desktop sign-in reported; does not block implementation |
| Network interception and rendered cosmetic proof | Signed browser and untouched control comparison passed |
| Switching, startup, memory, energy and browser benchmark baseline | Preliminary helper resources, browser footprint, Speedometer pair and control presentation/startup trace recorded; repeated matched comparison and input-ready/longer resource reports pending |

## Historical storage blocker — resolved on the second Mac

[The final preflight](evidence/2026-09-19-preflight.json) found **113.21 GiB free**
on APFS. The first observation was approximately 108 GiB; available space changed
during the session. The fetch gate is **200 GiB**, a conservative project reserve
for source, optimized outputs and comparison artifacts, not an upstream published
minimum. No full Chromium download was started and no user files were removed.

Continue when an APFS build location with enough space is available. Re-run
preflight, fetch the pinned source/dependencies, build the unmodified optimized
control, then implement the downstream Chromium hooks against that checkout.
The native bridge must be integrated into the browser process and blocking into
the native request/renderer paths before packaging the separate alpha.

Only after that package exists should extension installation/login, 1Password
approval, physical input and browser performance be requested or qualified.
Do not advance to the broad workspace-model migration on these component results.

## Current authoritative references

- [Chromium macOS build instructions](https://chromium.googlesource.com/chromium/src/+/main/docs/mac_build_instructions.md)
- [Chromium Mac stable release metadata](https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=1)
- [Apple XPC peer signing requirements](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
- [Apple bundled LaunchAgent registration](https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:))
- [adblock-rust](https://github.com/brave/adblock-rust)
- [EasyList licensing](https://easylist.to/pages/licence.html)
- [1Password additional-browser requirements](https://support.1password.com/additional-browsers/)

Context7 was unavailable in this task. Upstream source/docs and Apple docs through
Sosumi were used; the compiler and signed process proof checked the Apple APIs.
