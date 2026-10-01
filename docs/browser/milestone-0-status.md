# Milestone 0 implementation status

**Milestone 0 is incomplete. Chromium and a signed transport-proof alpha now build
and launch; full browser integration and compatibility qualification remain open.**
The independent native components below are built and exercised. Milestones 1–5
have not started, as required by the approved compatibility gate.

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
  Request blocking, renderer cosmetics, required extensions, and browser
  performance qualification are still pending.
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
| Authenticated helper communication | Signed browser and embedded helper exchange verified, including restart and wrong-client rejection |
| Direct Chromium rendering | Control and signed alpha launch; performance not qualified |
| Required extension installation, authentication, usage, profiles, updates, restart | Not tested |
| 1Password Mac-app / Touch ID integration | Not tested; user involvement needed once app is ready |
| Network interception and rendered cosmetic proof | Native engine exercised; Chromium paths pending |
| Switching, startup, memory, energy and browser benchmark baseline | Not measured |

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
