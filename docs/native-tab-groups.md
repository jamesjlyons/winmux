# Native tab groups in the sidebar

2026-10-16. Implements the first stage of the native-tab sidebar proposal: a
single window row with a tab count. Expanded native-tab controls are deferred.

## Behavior

An observed native tab group owns one WinMux window object and one stable surface.
The selected AppKit window number can change without replacing that surface, its
layout slot, Space, or pin. The sidebar shows the selected title and a `2 tabs`
badge. Dragging, tiling and pinning act on that single owner. The close action invokes the owning app's native close button.

The detector compares retained native AX tab-group objects with `CFEqual`. It
does not infer membership from window titles, matching rectangles, or a window
being off screen. Separate native groups with identical titles remain separate.

Selection changes invalidate cached titles and geometry and cancel queued frame
and focus jobs. Queued operations retain the native group identity, so detaching
the window that was selected when a job was queued cannot redirect the job to the
detached window. Group transfers are planned together before physical IDs change.
Incomplete selection observations hold the owners and reject stale AX operations.

A confirmed detached member receives its source Space as the arrival destination.
Native tab closes retain the owner while another known member survives. Explicit
project deletion closes the native group's remaining tabs, waiting for each close
and respecting save prompts. The owning application determines whether its native close button closes the
active tab or the entire window.

Native tab-bar observers request app-local reconciliation. Individual metadata
reads have short timeouts and inspection has a bounded budget. Failed reads do
not constitute a detach. Cached windows on other macOS desktops remain protected.

## Restart matching

Snapshots additionally store observed native member IDs and the complete tab-title
list when available. Member IDs are scoped to the same boot and process launch.
After relaunch, a whole-group title descriptor can restore placement only if it
is unique in both the saved records and current candidates. Identical or missing
descriptors remain unmatched rather than assigning the group to a guessed Space.
WinMux does not recreate terminal sessions; the owning application restores them.

## Compatibility boundary

Membership is learned from positive native tab-bar observations. If previously
tracked independent windows are combined into a **brand-new** native group whose
bar was not exposed before, AppKit does not directly identify every hidden member.
An older cached entry can remain independent until that tab is selected and the
shared AX group identity is observed. Likewise, when the selected tab closes and
the only survivor has never been observed, a disappearing tab bar may prevent
WinMux from proving that the newly exposed window is the same group. This case is not silently merged by title
or invisibility. It remains an open compatibility edge, particularly for apps
that hide their tab bar when only one tab exists.

The live fixture begins with native groups already formed. It verifies additions
to those groups, but does not claim to solve that first-group ambiguity. Expanded
per-tab actions and native tab reordering/detachment from the WinMux sidebar are
also outside this first stage. Those operations remain in the owning app.

## Validation

- Regression tests cover stable surfaces and membership across 180 moves among
  three Spaces, pin retention, title invalidation, two groups with identical
  titles, native tab transfer, confirmed detach, close-to-single-tab transitions,
  queued-operation routing, and conservative restart matching.
- The production detector is compiled directly into an isolated live probe. An
  accessory AppKit fixture creates off-screen windows and exercises eight stages:
  two independent native groups, selection changes, a new tab, selected-tab close,
  detach, a group closing, close-to-single-tab, and final closure. All 31 samples
  and stage assertions passed. Group identities remain stable throughout.
- A read-only observation of the running Ghostty instance reported one logical
  window with two native tabs. No terminal text was logged and no app state was
  changed.
- The optimized app suite passed all 1,332 tests. After the final close-cancellation
  and hidden-tab geometry-event guards, all 165 focused checks passed against the
  current shared workspace. A concurrent focus-handling edit required one rebuild
  because its tests arrived after the previous module had compiled.

Logs: `.local/native-tab-release-final.log`,
`.local/native-tab-final-focused-retry.log`, `.local/native-tab-fixture-final.log`.
Fixture observations and assertions are saved in `artifacts/native-tab-groups/`.

Run the fixture on an unlocked macOS console with Accessibility permission:

```sh
python3 artifacts/native-tab-groups/run.py --output .local/native-tab-new-run
```

Output directories must be new. The runner bounds subprocess lifetimes and cleans
up its own fixture. It exercises the production detector, not the entire running
WinMux desktop. Model tests cover Space and pin ownership. Neither the installed
app nor the earlier Alpha package was replaced by this work.

Related investigation: [window organization stress](window-organization-stress.md).
Upstream explanation: [Ghostty's native tab compatibility notes](https://ghostty.org/docs/help/macos-tiling-wms).
