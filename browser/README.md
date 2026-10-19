# WinMux Browser

The development workspace uses **Spaces containing Views**. A View contains a
page, an app window, or a split/stack arrangement. Pinning saves that arrangement
and its launch descriptors. WorkspaceCore owns organization and layout;
Chromium owns page windows, navigation, profiles, and extensions.

Protocol 11 integrates a compact toolbar in each Chromium window, without a
singleton tab row. Only explicit WinMux stacks show stack tabs. Chromium owns
address editing and autocomplete; the page menu retains Keep Active, site
blocking, and Privacy Settings. Earlier protocol peers temporarily retain their
existing controls while native interaction qualification remains open.

Each Space chooses **Shared** or a named browser profile in **Space → Manage
Space → Browser Profile**. Same-profile moves preserve the live page;
cross-profile moves reopen the current URL and close the original only after
all replacements are available. Changing the setting alone leaves existing
pages and pins unchanged. Private pages retain a distinct profile boundary.

Use **Option–Command–T** from any app to create a page. Each Space has an ordered
pin shelf. Closed pinned members retain their saved launch destinations and
layout slots across restarts; ordinary restart restoration does not open closed
pages. **New View** creates an intentional empty View.

Workspace Setup asks before enabling background component, extension, or filter
updates. New profiles use Kagi, local blank pages, and blocked third-party cookies.
Full uBlock Origin is bundled in every profile. The page menu exposes its
dashboard and site toggle; its popup, logger, and element picker remain available
through the extension button. Existing site exceptions are imported once.
The lifecycle policy protects active work while freezing and discarding eligible
older background pages.

The [simplification implementation record](../docs/simplification-plan.md) tracks
current verification and remaining work. The release and performance records
below describe earlier builds and do not qualify the integrated toolbar.

The [October 4 draft candidate guide](../docs/browser/alpha-release-2026-10-04.md)
covers installation, first launch, testing on another Mac, and rollback. The app
is **arm64-only**, Apple Development signed, and **not notarized**. Its binaries
target macOS 13 or later; live testing recorded here used macOS 27.0.1 on an M1 Pro.
That minimum target does not establish compatibility across all macOS versions.

The latest [performance audit](../docs/browser/performance-audit.md) passed 1,096
automated tests and recorded no frame drift across 50 Group/native-pin switches.
Median matching geometry was observed by 82–90 ms; three full helper/browser
restarts restored managed geometry within 4.50–4.90 seconds. These observations
used existing data and warm OS caches, and do not measure page load or input readiness.
Broader extension compatibility, physical input, display changes, and long-running
daily use still need qualification.

[Spaces, Views, and shared moves](../docs/browser/fork-interface.md) ·
[Page controls and pins](../docs/browser/page-windows.md) ·
[Workspace Setup](../docs/browser/workspace-setup.md)

## Components and build tools

Implemented and exercised:

- An optimized Swift helper and Objective-C++ client using
  asynchronous XPC. macOS checks the peer's Apple signing anchor, team and exact
  identifier in both directions. Authenticated inventory, owner actions, layout
  acknowledgements, and connection recovery coordinate browser and native windows.
- Explicit Workspace Setup with separate data, Accessibility approval, managed
  helper registration, and reversible handoff from standalone WinMux.
- Full uBlock Origin 1.75.0 (the Helium distribution), bundled as a restricted
  component extension with checksum-verified resources, offline filter lists,
  scriptlets, procedural cosmetics, and existing WinMux site controls. Background
  filter requests require the saved filter-update consent. The former native
  Rust blocker remains an inactive compatibility layer for the existing patch
  series; it does not filter requests or inject cosmetics.
- Pinned Chromium/depot_tools metadata, optimized browser-only build settings,
  storage checks, and a guarded checkout/build command.
- A trace evaluator that distinguishes activation, frame presentation and
  input readiness. It cannot qualify transport-only results or a daily driver.

The component proofs below exercise blocking and transport in isolation. They
complement the integrated browser checks recorded in the performance audit;
neither a C ABI probe nor a transport probe establishes browser qualification.

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

The legacy blocker proof compiles and tests the C++/Rust ABI using the bundled
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

After `build_alpha.py` has preserved the completed upstream output, create a
separately signed control for comparisons without rebuilding that archive:

```sh
source .local/browser/signing.env
python3 browser/tools/package_control.py --root /path/to/apfs/winmux-engine \
  --output .local/browser/packages/new-control
```

This copies `out/WinMuxControlBaseline`, applies separate control identities,
and uses the same generated Chromium signing policy and certificate as the
alpha. It refuses stale pins/arguments, downstream artifacts, existing output
directories and destinations inside the archive (including parent symlinks).
The report retains before/after hashes of the original executable, framework
and manifest. Use a separate control profile; signing and launch checks alone
are not a performance comparison.

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
Unknown edits are refused. The pinned uBlock archive is prepared without network access, recorded in the
build manifest, and bundled inside the signed Chromium Framework during
packaging. The legacy Rust library is retained for ABI compatibility.
The manifest distinguishes the resulting alpha from the archived control.

Configuration changes require `build_alpha.py --allow-configuration-change`
on each build whose `args.gn` differs from the original control. The archive stays
unchanged; the alpha manifest records both argument hashes and
`configuration_changed_from_control`. Such builds are no longer a matched
configuration performance comparison with the archived control. The flag does
not bypass source ownership, revision, or archive validation.

The browser enables H.264/AAC with `proprietary_codecs = true` and
`ffmpeg_branding = "Chrome"`, while retaining unbranded Chromium. These codecs
are required for MP4 and Media Source video on sites such as Twitter/X. Existing
builds that omitted them need an engine rebuild and a new package; changing the
native helper or a runtime preference does not add codec support.

Check actual decoding in the signed package with the pinned Chromium fixtures:

```sh
python3 browser/tools/test_browser_media.py \
  --app '/path/to/WinMux Browser Alpha.app' \
  --chromium-source /path/to/apfs/winmux-engine/chromium/src \
  --output .local/browser/new-media-check
```

This creates a fresh profile and loopback fixture server, checks codec support,
and requires MP4 H.264/AAC, Media Source H.264/AAC, and WebM VP9/Opus playback to
finish with decoded audio and video frames. It leaves existing sessions alone.

For a bounded background-video return check (Node 22 or newer):

```sh
node browser/tools/test_browser_media_return.mjs \
  --app '/path/to/staged/WinMux Browser Alpha.app' \
  --chromium-source /path/to/apfs/winmux-engine/chromium/src \
  --output .local/browser/new-media-return-check
```

Each codec must resume decoded frames after a ten-second hidden interval, two
five-second freezes, and an actual WebContents discard. The fixture verifies
freeze/resume events, suspended page timers, preserved session storage, and
`document.wasDiscarded` on reload. Unexpected renderer crashes or fatal browser
logs fail the run. Chromium's internal diagnostic page is enabled only in the
fresh test profile. The default is headless. Add `--headed` to exercise the same
transitions in a temporary native browser window; this also records the window
bounds and requires foreground page visibility before playback verification.
Neither mode covers managed workspace switching, automatic aging, native
presentation timing, or authenticated Twitter/X.

For a crash on another Mac, keep `Collect-WinMux-Diagnostics.command` and
`collect_browser_diagnostics.pl` from `browser/tools` together and run the
command there. It uses macOS's system Perl and saves a JSON report on Desktop.
The browser can stay open. The report includes build fingerprints and up to
20 recent Crashpad summaries with process identity, exception codes, and bounded
ARM64 stack offsets. Raw dumps, stack memory, page URLs, and profile data stay
on that Mac; nothing is uploaded. `--app` selects a nonstandard installation and
`--output` chooses a new report path. Absence of a dump does not rule out a killed,
hung, or site-error tab. Parser regressions run with
`python3 -B -m unittest discover -s browser/tests -p test_crash_diagnostics.py -v`.

Video fullscreen needs a visible macOS check in addition to headless decoding:

```sh
python3 -B browser/tools/test_browser_video_fullscreen.py \
  --app '/path/to/staged/WinMux Browser Alpha.app' \
  --chromium-source /path/to/apfs/winmux-engine/chromium/src \
  --output .local/browser/new-video-fullscreen-check
```

Run on an unlocked console with Accessibility/input access already available.
The fixture uses a fresh profile, a UUID test helper service, and native input
scoped to its browser PID. It checks MP4, Media Source and WebM playback through
repeated fullscreen entry/exit in standalone, stacked and split page windows,
including Escape, the native green button, nested video fullscreen, ownership
release and closing a fullscreen page. Window identity, restored geometry,
fullscreen events, playback samples and browser stderr are retained in the
output directory. For an archived baseline, `--helper-override` accepts a rebuilt
diagnostic helper that is copied and signed separately; the baseline package
is preserved. A successful headless media check does not establish fullscreen
correctness.

Integrated page windows suppress Chromium's horizontal tab strip. Their macOS
fullscreen path skips its separate native tab overlay, whose zero height would
abort Chromium. Host presentation changes are fenced before fullscreen entry
and restored after Chromium's immersive teardown, including deferred workspace
ownership changes.

Check the integrated browser menu in a signed package with a fresh test profile:

```sh
python3 -B browser/tools/test_browser_page_menu.py \
  --app '/path/to/WinMux Browser Alpha.app' --output .local/browser/new-page-menu-check
```

This visible test clicks the menu in standalone, stacked, split, released, and
readopted windows. It verifies both check commands and the Privacy Settings
sheet, restores the test settings, and removes its temporary helper. Run native
input fixtures one at a time on an unlocked console with Accessibility access.
Page commands must stay below Chromium's unbounded menu-command range; a compile
assertion prevents the command-ID collision that previously crashed this menu.

The packager requires a successful alpha manifest, an exact certificate SHA-1
in `BROWSER_SIGNING_IDENTITY`, and `BROWSER_SIGNING_TEAM`. It refuses to overwrite
an existing package directory and retains Chromium's nested signing policies.
The resulting app is a private Apple Development build, not a notarized release.
The Views Trial starts its workspace automatically on launch, without an
ordinary browser window. On first launch, setup requests Accessibility and
background-item approval if needed, then opens the managed browser. Existing
trial workspaces retain their saved profiles and state.

For the integrated alpha, use the application's **Workspace Setup…** menu
and [Start/Stop workflow](../docs/browser/workspace-setup.md). It creates its own
profile and native state. Stop the old workspace and quit its browser before
changing packages; keep the new app at its installed path while management is active.

Transport-only diagnostics can use a separate test profile with `--user-data-dir`
and explicit `--winmux-register-helper` enrollment. An optional absolute
`--winmux-bridge-report` path records transport status without browsing data;
this is separate from the managed workspace's helper service.

Native helper and browser identities are respectively
`com.jameslyons.winmux.browser.alpha.workspace` and
`com.jameslyons.winmux.browser.alpha`. The bundled LaunchAgent plist belongs in
`Contents/Library/LaunchAgents/`, and its executable belongs in
`Contents/Helpers/`. `HelperRegistration` wraps SMAppService; enrollment and
permission attribution still require the actual signed browser package.

## Observe the running native helper

The read-only macOS collector requires a PID, exact executable and verified
package manifest. It samples only that process and refuses to overwrite an
existing report. It does not start apps, query accounts or inspect profiles.

```sh
python3 browser/tools/measure_helper.py --pid HELPER_PID \
  --executable '/path/to/WinMux Browser Alpha.app/Contents/Helpers/WinMux Workspace.app/Contents/MacOS/WinMuxWorkspaceHelper' \
  --package-manifest /path/to/winmux-package-manifest.json \
  --output .local/browser/new-helper-observation.json
```

The default is five minutes after a 30-second settling delay. CPU uses elapsed
kernel counters as a percentage of one core; physical footprint is distinct
from resident size. Changed process identity, sleep, counter regression and
incomplete sampling invalidate the series. A valid observation still does not
qualify Milestone 0 or represent a full browser/control comparison.

## Record benchmark conditions without accessibility polling

Build the standalone read-only recorder before a benchmark session:

```sh
xcrun swiftc -O -warnings-as-errors -parse-as-library -swift-version 6 \
  browser/tools/observe_environment.swift -o .local/browser/observe-environment
.local/browser/observe-environment --pid BROWSER_PID \
  --executable '/path/to/Browser.app/Contents/MacOS/Chromium' \
  --seconds 600 --interval 2 --output .local/browser/new-environment.jsonl
python3 browser/tools/check_environment.py .local/browser/new-environment.jsonl
```

It never activates apps, sends input, reads windows/AX/browser content, or changes
power settings. It checks the exact process path/start identity, observes app
activation and sleep notifications, and periodically records power, thermal
state and display modes. The output is created exclusively and streamed, so an
interrupted recording remains incomplete. Unknown values and interruptions are
flagged; a consistent environment record never qualifies a benchmark by itself.
Correlate it with the entire benchmark interval and separate provenance/workload
evidence. Application foreground is not proof of the selected tab's visibility,
and display mode refresh is not a measurement of actual frame cadence.

## Qualification

The [stability and performance test plan](../docs/browser/stability-test-plan.md)
defines crash capture, video/feed stress, lifecycle and recovery coverage,
long-running qualification, and release gates. It includes the October 9 crash
triage and distinguishes existing fixtures from the remaining harness work.
The [bounded RC6 results](../docs/browser/stability-results-2026-10-09.md)
record the reproduced renderer assertion, switching measurements, recovery
checks, and outstanding coverage gaps, with commands for the new feed and
failure-injection fixtures.
The [bounded fix verification](../docs/browser/stability-fixes-2026-10-09.md)
records the renderer, switching, and helper-recovery fixes and their reruns on
the signed stability-fixes RC5 candidate. Long-duration qualification is deferred.

For tab creation, build and sign the candidate first, then run the isolated
fixture on an unlocked console with native workspace ownership free:

```sh
python3 browser/tools/test_browser_tab_speed.py \
  --app '/path/to/WinMux Browser Alpha.app' \
  --output .local/browser/new-tab-speed --runs 3 --samples 100 --require-targets
```

Each run opens 100 blank tabs and 100 copies of a primed local URL. The fixture
uses one persistent native keyboard probe and Chromium compositor callbacks,
correlated to each creation operation. The candidate gate requires complete
samples, at least 95% warm-window hits, and input and presentation p95 at most
100 ms for both categories. Cached favicon delivery to helper inventory must
have p95 at most 50 ms. This does not qualify rendered sidebar icon timing or
the complete WinMux command/discovery pipeline; measure those in the app too.
The report retains median/p95 stage timings, idle CPU and summed browser process
footprints. Compare footprints across baseline and candidate runs to report
incremental memory; these sums are not unique physical pages.

Run the baseline with its verified signed package and `--helper-override` pointing
to the current helper executable. It is copied and signed inside the fixture;
the original package is preserved. An instrumented candidate can also be run
with `--disable-warming` to isolate the prepared-window contribution. Neither
comparison alone establishes the complete before/after improvement. The fixture
creates a fresh profile and test service, uses loopback pages, and cleans them
up without altering an installed browser or existing workspace.

For opt-in app tracing, launch WinMux with `WINMUX_TRACE_TABS=1` and the browser
with `--winmux-trace-tabs`. `WINMUX_TAB_TIMING` events contain operation IDs and
monotonic microsecond timestamps, without page URLs.

Check session persistence separately on the same signed package:

```sh
python3 browser/tools/test_browser_tab_sessions.py \
  --app '/path/to/WinMux Browser Alpha.app' \
  --output .local/browser/new-tab-sessions
```

This fixture keeps a consumed URL window open, allows its spare to replenish,
then quits and restarts the synthetic profile. It requires exactly the two user
surfaces to restore with their original identities. Run fixtures that use native
keyboard input one at a time so they do not compete for foreground focus.

For an isolated live check of dedicated pins, pinned splits, Space switching,
and resident page wake-up, use a newly signed package with native workspace
ownership free and the current macOS console unlocked:

```sh
python3 browser/tools/test_browser_switch_speed.py \
  --app '/path/to/WinMux Browser Alpha.app' --output .local/browser/new-switch-run
```

The fixture refuses a locked or inactive console before starting. It uses fresh
loopback pages and an explicitly scoped native app. It waits for every page to
load and establishes initial keyboard focus before measuring; setup focus retries
are recorded separately, and every measured switch issues one command. Individual
pins and the grouped pin are explicitly assigned to different Spaces. It waits
for real lifecycle freezing, sends F13 only to its browser process, and records
command responses, destination keyboard acknowledgements, and animation callbacks
matched to the same input sequence. Timings include probe overhead; animation callbacks do not establish
compositor presentation. A separate environment recording captures thermal state,
power mode, foreground changes, and display configuration throughout measurement.
If the preceding switch's inventory is still arriving, the fixture records its
background-state settling wait separately before starting the next sample.
The script never stops an existing workspace and does
not qualify the full interaction workload. `surface pin` and `surface unpin`
also expose pinning through the normal local command interface; `surface list`
includes desktop identity and browser lifecycle without page titles or URLs.
`--failure-hold-seconds 120` briefly retains a failed isolated fixture for UI
diagnosis before cleanup; it does not retry or count a failed timing sample.

See the [current performance audit](../docs/browser/performance-audit.md),
[integration validation](../docs/browser/fork-integration-validation.md), and
[original qualification plan](../docs/browser/approved-plan.md). The
[Milestone 0 record](../docs/browser/milestone-0-status.md) retains earlier component
evidence and benchmark limits.
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

## Unified Alpha (2026-10-06)

The Alpha now includes the complete Views Trial through `a2d79459`: independent
views by default, explicit split/stack grouping, reusable Space browser profiles
and transactional cross-profile moves, temporary Incognito Spaces, native window
controls, current favicons, direct permission-aware launch, profile-picker
suppression, browser-exit shutdown, branding, and 1Password host discovery.

The Alpha retains its existing application identity and workspace data directory.
`WinMuxWorkspaceViews` retains compatibility with Trial launchers without selecting
the Trial's separate data directory. New configurations use
`new-item-placement = 'new-view'`. Existing configuration files are preserved;
legacy arrival settings are translated by the parser without changing sidebar
presentation. New tabs and ordinary app windows start separately by default.
A pin gets a dedicated View; pinning an existing arrangement keeps
its layout. Browser profiles are never copied between the Alpha and Trial.

Protocol 8 combines the formerly divergent Alpha/Trial version-6 features.
Profile dispatch requires version 7 or newer; privacy/lifecycle controls require
version 8. The dedicated pin-desktop model preserves closed-member layouts and
uses the Trial's transactional profile move before changing a cross-Space pin.
Private Spaces cannot be pinned or saved in regular restart metadata.

The privacy defaults, background page policy, private first-run directory repair,
and bounded filter-download crash fix remain enabled. Automatic launch preserves
saved background-service consent. Developer ID packaging support is included;
Apple Development-signed packages remain unnotarized and do not establish
1Password desktop linking. See [the certificate investigation](../docs/browser/onepassword-desktop-link.md).

### ChatGPT desktop connection

WinMux uses a separate browser data directory. ChatGPT's desktop installer
registers `com.openai.codexextension` under Chrome and Chromium, so Chromium's
normal profile-local lookup cannot find it in WinMux. Patch 0026 extends the
existing 1Password discovery fallback to this exact host name. It reads the
installed registration in place, preserves explicit registrations and the
user-level-host policy, and retains Chromium's manifest/origin validation.

The discovery helper passes 16 tests covering both desktop apps, precedence,
policy, removal, and unrelated hosts. This does not establish full ChatGPT
desktop compatibility: WinMux is not among the browsers listed in
[OpenAI's extension setup guide](https://learn.chatgpt.com/docs/chrome-extension).
See [the connection repair evidence](../docs/browser/evidence/2026-10-08-chatgpt-native-messaging.json)
for the current-profile repair and verification limits.

## Full uBlock qualification

The bundled extension and local bridge live in `browser/ublock`; its source,
license, and modification notice ship inside the signed framework. The browser
loads it only from framework resources. It uses the component MV2 exception;
ordinary extensions do not gain MV2 or privileged API access. Native filtering
and the previous EasyList updater are inactive, so there is one filtering owner.

Run the isolated component check against a newly staged signed package:

```sh
node browser/tools/test_browser_ublock.mjs \
  --app '/path/to/WinMux Browser Alpha.app' \
  --output /path/to/new-ublock-check
```

This uses fresh profiles and local fixtures to check offline initialization,
exception migration, network and cosmetic filtering, procedural rules, scriptlets,
persistence, and filter-update consent. It never changes the daily profile.
The native page-menu fixture additionally exercises the WinMux site control.
Patch 0034 reads the bundled manifest on Chromium's extension file runner and
registers it back on the UI thread, cancelling the reply when the profile shuts
down. This also covers Space profiles created after browser startup, when UI
thread file reads are forbidden and would abort the entire browser.

Run `test_browser_inventory.py` against the same signed package to exercise
new Work and Personal profiles, returning to an existing profile, tab creation,
and helper reconnection. It also requires a uBlock background page in all three
regular profiles. Repeat with `--resume-profiles-from` pointing to that successful
fixture to verify saved profile data and identity after restart. The standalone
uBlock check above covers filtering and startup, but does not create Space profiles.

For a browser-only update, `package_alpha.py --workspace-app /path/to/WinMux\ Workspace.app`
can preserve an existing Apple-signed workspace helper. Its signature and identity
are verified, and its separate binary provenance is recorded instead of claiming
that it was built from the current native sources. The entire signed helper and
its configuration are checked byte-for-byte; this path does not claim a fresh
configuration-parser validation. `--icon` can reuse the installed ICNS artwork.

The bridge's migration, command ordering, stale-navigation handling, consent, and
context isolation can also be checked without launching macOS applications:

```sh
node --experimental-vm-modules --test browser/tests/test_ublock_bridge.mjs
```
