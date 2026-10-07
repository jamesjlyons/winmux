# Spaces and independent page windows

The browser workspace uses the original fork’s **Spaces → Views**
interface for both web pages and Mac app windows. The top selector changes Spaces;
icons and swipes offer quick navigation, and Organize shows all Spaces together.
Settings retain the original simplified navigation.

Every web page keeps its own Chromium window and profile identity. Stacks share
space and select one visible window; splits show multiple windows at once.
Viewing or moving a page does not move its WebContents into another host.

## Automatic tiling

Independent pages and tiled Mac windows share the active View's layout. New
pages opened after startup enter the active View, including when Chromium sends
a complete inventory instead of a delta. Unknown pages in the first restored
inventory still go to Recovered; saved assignments stay intact.

Selecting a View restores its last available page or Mac window and gives it
input focus. Views containing only browser pages select a page immediately;
empty Views clear the old selection. Late focus reports and layout replies
cannot bring a hidden page back over the active View.

When independent windows cannot fit in one horizontal row, WinMux uses rows and
columns while respecting each owner's minimum size. If the display cannot fit
every window, it retains multiple visible tiles and puts overflow in temporary
stacks. Switching items selects the visible member of its stack. These temporary
arrangements leave saved splits, stacks, and View assignments intact and expand
again as space becomes available. Explicit tab stacks keep their chosen layout.

Browser layouts retry a stale request after a newer inventory arrives, so an
inventory update during a window placement cannot leave automatic tiling idle.

## Sidebar actions

Mixed rows use the same icons, spacing, hover/search feedback and activation rules
as native rows. A tab-stack header includes its window count and app icons.
Right-click a window or stack and choose **Move to → Space → View**, or **New
View**. Moving a stack retains its order, selected page and split proportions.
Unavailable owners prevent a whole-stack move before any membership changes.

Drag a window or stack from the sidebar to another View or its creation row.
The sidebar shows a destination preview and stays expanded throughout the drag;
Organize scrolls at its edges. Releasing outside a destination or pressing Escape
cancels. Individual tiled windows can also use the existing stack/split/swap drop
zones. Floating Mac windows retain their original behavior.

The interface uses Spaces and Views. Existing `project`/`workspace` commands and
TOML keys remain compatibility aliases. The browser CLI uses its explicit
`--socket` endpoint. Session version 6 stores ordinary and pinned Views together;
protocol 11 enables the integrated Chromium toolbar.

## Fresh organization with retained browser data

Fresh browser-workspace state starts in the Default Space with an automatically
named View, a compact rail that expands on hover, and neutral chrome that follows
macOS Light/Dark Mode. Option–J/K selects items; Option–Space changes layout.
There is no forced persistent Browser View.

To reset WinMux organization while retaining the browser profile:

1. Use **Stop Workspace** from the package currently managing the daily workspace.
2. Quit that browser normally so Chromium saves its pages and releases its profile.
3. Run `python3 browser/tools/reset_workspace_layout.py` from this checkout.
4. Start Workspace from the new signed package. It reuses the daily Chromium
   profile and adopts its restored pages into the fresh active View.

The reset utility requires stopped native management and the marked daily data
root. It archives the entire `daily/native-state` directory under
`layout-archives/<timestamp>/native-state`, including settings, session and backup.
Its `archive.json` records the prior package path. It never copies or resets
`daily/browser-profile`, and imports no standalone configuration or session.

For recovery, stop the workspace and quit its browser, archive the new native
state separately, then move the saved `native-state` directory back under `daily`.
Start the prior package recorded in `archive.json`. Do not replace state while its
workspace is running.

[Native page controls](page-windows.md) · [Workspace activation](workspace-setup.md) ·
[Integration validation and recovery record](fork-integration-validation.md)
