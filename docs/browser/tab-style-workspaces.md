# Tab-style workspace trial

This opt-in experiment keeps one sidebar view per ordinary window or browser tab.
Selecting a view fills the usable desktop without entering macOS fullscreen. A
split or stack appears only after explicitly combining windows. Existing saved
arrangements retain their structure and proportions.

Enable it in the trial state's `winmux.toml`:

```toml
workspace-interaction-mode = 'views'
```

The default remains `tiling`. The Chromium bridge protocol and existing workspace
identities are unchanged: a regular workspace represents one sidebar view, and
an arrangement lives inside it.

For a complete app to try on another Mac, use the
[October 4 Views Trial](views-trial-2026-10-04.md). That package enables the model
automatically and keeps its profile and state separate from the daily alpha.
The developer fixture launcher below is only needed for scoped integration work.

## Trying the model

- A single window appears as one sidebar row. An arrangement has a disclosure
  arrow and its member rows. Clicking its header restores the last selection.
- Use **Combine with…** in a window's context menu, or drop it onto another view
  and choose Stack, Split Left/Right, or Split Above/Below. Escape dismisses the
  drop menu without changing the arrangement.
- The top and bottom edges of a row reorder a standalone view. Arrangement
  headers have a separate reorder handle. Drop feedback describes the action.
- **Separate into Own View** removes one member from an arrangement. It is
  disabled for a window that is already standalone.
- Pinned belongs to each Space. Each live pin displays independently by default;
  pins can be explicitly combined with other live pins. The left edge of a pin
  reorders it; dropping in its center offers the combination menu.
- New ordinary tabs opened while Pinned is active use a regular standalone view.
  Unpin also creates a standalone view. A pinned app or URL can still reopen from
  its pin. Reopening a closed member does not reconstruct its former combination.
- Floating windows, dialogs, and popups retain their existing behavior. Explicit
  native window rules and restored layouts take precedence over automatic arrival
  placement. Minimized and unavailable owners keep their reserved views.

## Isolated trial

Build a signed staged app using the existing packaging instructions. Then prepare
a new directory (the command deliberately refuses to overwrite one):

```sh
python3 browser/tools/workspace_views_trial.py prepare \
  --app '/absolute/path/to/package/WinMux Browser Alpha.app' \
  --output '/absolute/path/to/views-trial'
```

Preparation verifies the app signature and packaged helper digest, creates a
separate browser profile and workspace state, and builds a two-window native
fixture. It does not install or launch the candidate.

Open the generated **Start Trial.command** to try it. The trial refuses to start
while the usual workspace manager is running. Use that manager's **Stop
Workspace** action first, then start the trial. The trial helper manages only its
native fixture process; browser tabs use the separate profile and test service.
The staged helper may need its own Accessibility permission.

Open **Stop Trial.command** when finished, then start the usual workspace again.
Stopping removes only the unique trial service and its verified fixture/browser
processes. The separate trial profile and saved layout remain for another run.
The launcher never stops or replaces the daily manager.

## Validation

`WorkspaceViewsTest` covers standalone allocation, delayed and failed tab
creation, minimized reservations, explicit combination/separation, and Pinned.
`SelectedRootLayoutTests` covers hidden pin placement, resizing explicit splits,
stack navigation, whole-arrangement transfer, and snapshot compatibility.

Run `make check` for Debug and optimized Dev tests. Run the independent native
package with `swift test --package-path browser/native`. The actual SwiftUI sidebar
can be rendered without activating native management:

```sh
swift run -Xswiftc -DDEBUG winmux-marketing-renderer \
  --workspace-views-proof /absolute/path/to/sidebar-proof
```

That command produces expanded, narrow, and compact views in light and dark mode.
It is a layout proof, not an interactive native-management test.

This trial intentionally leaves broader search, recovery, and undo improvements
for a later pass after evaluating the core navigation model.
