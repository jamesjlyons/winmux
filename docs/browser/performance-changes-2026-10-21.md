# Performance changes — October 21, 2026

This pass follows an audit of the installed alpha (`browser-alpha-2026-10-20`)
across the engine overlay, the workspace helper, the app integration and the
build configuration. The engine was rebuilt with the new configuration on
October 21–22 and packaged as `.local/releases/browser-alpha-official-2026-10-21`,
which is the installed daily package. The rebuild also replaced the project's
V8 patch (`v8-patches/0001-no-allocation-profiler-positions.patch`): it had
used a DEBUG-only assert-scope query that does not compile in official builds,
and now keys on `Script::has_line_ends()` instead.

## Engine build configuration

The installed engine was built with `dcheck_always_on = true`,
`is_official_build = false` and no profile-guided optimization. Non-official
Chromium builds default to compiled-in debug assertions; the renderer crash
reproduced on October 9 was one of them firing. `browser/chromium/args.gn` now
sets:

- `dcheck_always_on = false`
- `is_official_build = true`
- `chrome_pgo_phase = 2`
- `use_thin_lto = false` (official builds default ThinLTO on, which needs lld;
  `use_lld = false` remains required by the Xcode 27 SDK)

PGO reads the pinned mac-arm profile, and the official build also expects V8's
builtins profiles. `browser/tools/chromium.py` now writes
`checkout_pgo_profiles = True` and `checkout_v8_builtins_pgo_profiles = True`
into the gclient spec, the existing engine's `.gclient` was updated to match,
and both were fetched for the current checkout with:

```sh
cd .local/browser-engine/chromium
PATH="$PATH:$PWD/../depot_tools" python3 src/tools/update_pgo_profiles.py \
  --target=mac-arm update --gs-url-base=chromium-optimization-profiles/pgo_profiles
cd src/v8 && python3 tools/builtins-pgo/download_profiles.py download \
  --depot-tools ../../../depot_tools
```

Rebuild with `build_alpha.py --allow-configuration-change`; the manifest records
`configuration_changed_from_control`, so the archived control is no longer a
matched-configuration comparison.

## Browser-driven uBlock exchange

The bundled bridge (`browser/ublock/winmux.js`) polled the native exchange
every second and republished the whole inventory whenever a blocked-request
counter moved. It now runs the exchange from uBlock's own throttled badge
updates (about 0.7 s per tab while requests are being blocked), from the
browser's `onCommand` event for site toggles and saved consent changes, and
from a 60-second fallback interval. An idle profile exchanges nothing. The
native side no longer treats a changed blocked count as an inventory change;
the page menu reads that count live. Consent saves wake the exchange through
`NotifyUBlockConfigurationChanged`.

## Inventory rebuilds only changed pages

`browser_inventory.cc` rebuilt and compared the record of every page on any
event. Observers now mark the page, host or profile they concern, and `Update`
rebuilds only those records while reusing the rest. Structural changes (pages,
hosts, selection, layout) still publish on the next task; metadata (title,
loading, favicon, lifecycle, counters) coalesces over a 30 ms trailing window.
Actions keep their synchronous refresh before dispatch. Privacy state is read
once per profile per update, and the extension icon cache hashes pixels instead
of copying them into its key. Peers with the integrated toolbar (protocol 11)
no longer receive `pinned_extensions` or `active_downloads`, and the browser
does not observe toolbar badge changes for them; Chromium's own toolbar shows
both. Earlier peers keep those fields.

## Display-paced glides with stepped resizes

Page glides ran on a 120 Hz wall-clock timer and called `SetBounds` on every
tick. Each resize relayouts and rasters the page. The ticker now runs on a
`CADisplayLink` for the main screen (macOS 14 and later; a timer at the screen's
refresh rate otherwise). The position still moves every frame; the size advances
in at most about six steps of at least 24 px, and arrival applies the exact
target. Tune `kResizeSteps` and `kMinimumResizeStep` in `host_layout.cc`.

Every managed page window carries a Liquid Glass toolbar material, which the
GPU recomposites whenever the window moves or resizes. To compare an opaque
toolbar, set `defaults write com.jameslyons.winmux.browser.alpha.workspace
WinMuxOpaqueToolbar -bool true` (or `WINMUX_OPAQUE_TOOLBAR=1`) before Start
Workspace; the launcher then passes `--disable-features=GlassFrame`.

## Standard preloading

`net.network_prediction_options` moves from never (2) to standard (1), so
Chromium preconnects and resolves DNS for origins learned from the profile's own
history and honors page-declared speculation rules. No prediction service is
contacted; search suggestions stay off.

## App: titles no longer checkpoint the session

A page-title update bumped `persistenceRevision` through `savedViews`, which made
the restart checkpoint capture the whole frozen world and write the session file
about once per second while any page loaded. Titles are now excluded from that
decision (every capture copies live titles anyway). The organization reconcile
keys on `layoutEpoch` rather than the interaction revision, so metadata deltas
no longer re-reconcile every Space, and a metadata-only message refreshes pin
artwork instead of re-running pin and desktop migration. Arrival ordering sorts
only unplaced pages, `SurfaceID` is `Comparable` without string formatting, and
a click only queries the WindowServer window list when a visible page host
contains the point. `testBrowserTitleInventoryDoesNotCheckpointButMembershipDoes`
covers the persistence rule.

## Not changed

- The helper validates each inventory message twice (endpoint and main actor).
- Animation ticks still refresh every tab strip.
- No measurement is recorded here. Compare against
  [the October audit](performance-audit.md) after rebuilding.
