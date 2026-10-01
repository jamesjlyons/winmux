# WinMux Browser implementation

This directory implements the independent parts of **Milestone 0** of the
[approved plan](../docs/browser/approved-plan.md). The optimized Chromium control
and a signed alpha with native blocking now build and launch. The Milestone 0 exit gate remains unmet, and the native WinMux
model has not been migrated.

Implemented and exercised:

- A release-built Swift helper control plane and Objective-C++ client using
  asynchronous XPC. macOS checks the peer's Apple signing anchor, team and exact
  identifier in both directions. Negotiation and connection epochs reject
  unsupported versions, duplicate and stale probes.
- A native Rust blocker with a C ABI, pinned adblock-rust, bundled and hashed
  EasyList/EasyPrivacy, network exceptions, per-call site control, declarative
  cosmetic queries, bounded DOM-token deltas, and one bundled replacement.
- Pinned Chromium/depot_tools metadata, optimized browser-only build settings,
  storage checks, and a guarded checkout/build command.
- A trace evaluator that distinguishes activation, frame presentation and
  input readiness. It cannot qualify transport-only results or a daily driver.

The helper currently exposes only negotiation and a transport probe. It does
not manage windows, advertise a fake inventory, or start the original WinMux
runtime. The Chromium bridge and private alpha packaging compile against the
full checkout. Real bundled-helper enrollment, authenticated exchange and restart
have passed. Network interception and initial renderer cosmetics now pass a
local browser/control comparison. Required-extension and performance
qualification remain pending.
Neither the C ABI probe nor the helper probe is a browser substitute.

## Run the component proofs

From the repository root:

```sh
cargo fetch --locked --manifest-path browser/blocking/Cargo.toml
python3 browser/tools/test_blocking.py
python3 browser/tools/test_native_bridge.py
python3 -m unittest discover -s browser/tests -v
```

The native proof needs an Apple Development identity in the keychain. Set
`BROWSER_SIGNING_IDENTITY` to the certificate's SHA-1 fingerprint to select an
exact identity when more than one team is available. It builds in
`.local/browser/native-build`, creates a temporary per-user LaunchAgent, and
removes it afterward. It refuses to replace an already registered alpha helper.
It does not install apps, register SMAppService, request Accessibility, read
browser profiles or change the running WinMux. No ad-hoc signing fallback is
accepted for the product; an ad-hoc binary is used only as a rejection test.

The blocker proof compiles and tests the actual C++/Rust ABI using the bundled
lists, then measures 3 × 40,000 request decisions with four concurrent threads.
The results are a microbenchmark, not measured browser overhead. JSON/log
outputs are saved under `.local/browser/`.

## Build the pinned upstream control

Choose an APFS build location with at least 200 GiB free. This is this project's
working-space reserve for source, optimized artifacts and comparisons, not a
published Chromium minimum. Nothing is deleted to create space.

```sh
python3 browser/tools/chromium.py preflight --root /path/to/apfs/winmux-engine
python3 browser/tools/chromium.py fetch --root /path/to/apfs/winmux-engine
python3 browser/tools/chromium.py build-control --root /path/to/apfs/winmux-engine
```

On machines with less memory, pass `--jobs 4` to `build-control` to bound local
compiler concurrency. The chosen limit is recorded in the build manifest; it
does not change the browser's optimized build settings or qualification targets.
The pinned tool wrapper bootstraps its hermetic Python runtime when necessary.
The build configuration uses Apple's linker for native arm64 because the pinned
LLVM linker cannot parse the Xcode 27 SDK's `arm64e.x1` TAPI targets. Keep this
setting identical for later alpha comparisons.

The fetch is intentionally separate from the preflight. Both mutations repeat
their resource gate. Existing dirty or differently pinned checkouts are refused.
The pinned depot_tools updater is disabled; GN/Ninja and compiler dependencies
come through Chromium DEPS. Sandbox, site isolation and normal profile/extension
behavior remain enabled. The control build is not branded or installed as the alpha.

## Build and package the private alpha

After the control build completes:

```sh
python3 browser/tools/build_alpha.py --root /path/to/apfs/winmux-engine --jobs 4
source .local/browser/signing.env
python3 browser/tools/package_alpha.py --root /path/to/apfs/winmux-engine \
  --output .local/browser/packages/new-alpha
```

`build_alpha.py` archives the completed control with an APFS clone at
`out/WinMuxControlBaseline`, then retains `out/WinMuxControl` as its working cache
to preserve Siso's path-sensitive dependency state. It accepts only the pinned
checkout, a verified prefix of the owned patch series, and known overlay files.
Unknown edits are refused. The pinned Rust blocker and hashed filter snapshots
are built into a separate native library and bundled inside Chromium Framework.
The manifest distinguishes the resulting alpha from the archived control.

The packager requires a successful alpha manifest, an exact certificate SHA-1
in `BROWSER_SIGNING_IDENTITY`, and `BROWSER_SIGNING_TEAM`. It refuses to overwrite
an existing package directory and retains Chromium's nested signing policies.
The resulting app is a private Apple Development build, not a notarized release.
Use a separate test profile with `--user-data-dir`; enroll the packaged helper
explicitly with `--winmux-register-helper`. An optional absolute
`--winmux-bridge-report` path records transport status without browsing data.

Native helper and eventual browser identities are respectively
`com.jameslyons.winmux.browser.alpha.workspace` and
`com.jameslyons.winmux.browser.alpha`. The bundled LaunchAgent plist belongs in
`Contents/Library/LaunchAgents/`, and its executable belongs in
`Contents/Helpers/`. `HelperRegistration` wraps SMAppService; enrollment and
permission attribution still require the actual signed browser package.

## Qualification

See [the current evidence and blockers](../docs/browser/milestone-0-status.md).
Each measurement must retain the build, rules and extension versions. The
interaction evaluator accepts a shared monotonic clock, six distinct focus
stages, visible-selection timestamps, real presentation/input evidence and
1,000 interactions per switch category across multiple runs:

```sh
python3 browser/tools/qualify_interactions.py /path/to/interaction-trace.json
```

Its scope is interaction latency only. Startup, memory/energy, frame pacing,
browser benchmarks, essential extensions, physical input, recovery and soak
tests are separate gates in the approved plan. No measurement report is generated
from the synthetic evaluator fixtures.
