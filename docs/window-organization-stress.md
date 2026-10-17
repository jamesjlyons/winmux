# Window creation, movement and tab drag investigation

2026-10-16, following restart-restoration commit `8fd0be2c`.

## Confirmed and fixed

### Selected tabs had no split target in their own stack

Both sidebar tab drags and shared tab-strip drags excluded the moving surface
from their targets, then accepted only currently visible surfaces. When the
moving tab was selected, its siblings were hidden, leaving no target over the
stack's content. The four split hover zones disappeared. Two regression tests
failed at target resolution before the fix, for browser and native tabs.

Drag target planning now selects a remaining sibling in a temporary layout
plan. It retains the actual stack allocation, saved organization and owner
selection until release. Commit checks that same plan against current ownership
and geometry. A closed sibling cannot receive a stale drop. Nested arrangements
remain intact when lifted out of a surrounding stack.

### Sidebar group drags could not preview or commit content drops

The sidebar driver only dispatched `.surface` payloads to the content resolver.
A `.group` payload could move through sidebar destinations but never produced
split or stack feedback over content. It now dispatches the complete group
through the shared-pane resolver and revalidates every member at release.

## Stress coverage

- Three seeds, 600 operations each: create, close, move individual native
  windows, move groups, stack, horizontal/vertical split, reorder, and serialize
  checkpoints across three WinMux Spaces. Membership, uniqueness, owner bindings,
  valid frames, visibility and snapshot validation are checked after every step.
- 90 interleaved arrivals per placement mode: new view, tile, stack native,
  float native. Each arrival retains its captured Space after focus switches to
  another Space. New-view arrivals remain independent.
- 120 mixed native/browser split, rejoin and reorder cycles using all four edge
  zones, alternating sidebar-style leaf drops and shared tab-strip drops.
- Nested arrangement extraction, complete sidebar group drops, stale reorder
  rejection and target closure between preview and commit.

These are controller/model stress tests. They do not claim thousands of live
mouse gestures or interactions with the user's daily windows.

## Native-tab compatibility gap (initial investigation)

A subsequent first-stage implementation adds stable native-group ownership and
sidebar tab counts. See [native tab groups](native-tab-groups.md) for the current
behavior, validation, and remaining first-group discovery limitation. The findings
below record the original reproduction.

[Ghostty documents](https://ghostty.org/docs/help/macos-tiling-wms) that its macOS
native tabs are represented as windows in the window-management API. A read-only
inspection of the running Ghostty instance found one enumerated AX window with
two native tab buttons.

An isolated AppKit fixture then reproduced the underlying identity transition:

1. Three independent windows are all present in `AXWindows`.
2. Two are combined into an `NSWindowTabGroup`. Only the selected tab remains in
   `AXWindows`; the inactive tab's cached AX element still returns its valid,
   original CGWindowID.
3. Switching native tabs reverses which window is enumerated. The AX tab-group
   element compares equal with `CFEqual` across the switch, and its buttons retain
   their observed identities.
4. Detaching restores both independent window entries. The unrelated third
   window remains enumerated throughout.

`MacApp.refreshAndGetAliveWindowIds` intentionally retains cached AX windows with
valid IDs, including windows outside the current macOS desktop. Consequently,
inactive native tabs can remain as independent WinMux windows; a newly selected
native tab can enter ordinary arrival placement. This explains duplicate entries
and the potential to assign tabs of one native window to different WinMux Spaces.

Removing every window missing from `AXWindows` would lose legitimate windows on
other macOS desktops and confuse temporary AX failures with closure. A complete
fix needs native tab-group ownership: one durable WinMux surface per native group,
tracking its selected AX window, real detach/close events, pins and saved placement.
The fixture's stable AX group identity is a useful signal, but hash equality alone
is not a production identity contract. No speculative native-tab suppression or
Ghostty configuration change was applied.

Synthetic fixture sources and observations are in
[`artifacts/window-organization-stress`](../artifacts/window-organization-stress).
The fixture uses an accessory process, no activation, and only changes its own
windows. Its requested off-screen positions can be constrained onto a display by
AppKit; the subsequent native-tab fixture overrides that constraint to keep its
windows off screen. This original fixture exits after its five stages. The probe only
reads window IDs, tab metadata and enumeration membership, not terminal text.

Reproduce on an unlocked macOS console with Accessibility access:

```sh
python3 artifacts/window-organization-stress/run-native-tabs.py --output .local/native-tabs-new-run
```

The verified runner passed 14 observations covering grouping, two switches and
detachment, while checking the independent third window throughout. Output paths
must be new; the runner has startup and process deadlines and cleans up its own
fixture process.

## Validation

The final optimized app suite passed all 1,319 tests with zero failures, including
the new stress and drag regressions. The WorkspaceCore and BridgeCore suites
passed all 246 tests. The native-tab fixture passed all of its assertions.

The missing selected-tab targets were reproduced with failing tests before the
fix. Testing also exposed the case where a whole inner stack is lifted out of an
outer stack; target planning now handles that case, and its regression passes
both in isolation and in the final optimized suite.

Logs: `.local/window-drag-repro.log`, `.local/window-organization-stress.log`,
`.local/window-drag-nested.log`, `.local/window-organization-release-tests.log`,
`.local/window-organization-core-tests.log`, `.local/window-drag-nested-stack.log`,
`.local/window-organization-release-final.log`, `.local/native-tabs-verification.log`.

The installed app and daily workspace state were not replaced. The previously
packaged Alpha from `8fd0be2c` does not include these new drag fixes.
