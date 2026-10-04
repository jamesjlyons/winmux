# Native page windows

The browser workspace presents each Chromium page in its own native window.
WinMux's Swift surface tree owns placement, grouping, selection and split sizes.
A stack shares a rectangle: selecting another page hides one window and shows
another. Regrouping does not move WebContents between hosts or change the page's
native window ID. Native app windows can occupy the same workspace and groups.

## Controls

Each visible managed page has a continuous rounded frame and a 28-point native
AppKit header. Four-point outer insets and a one-point frame separate neighboring
pages. AppKit's standard red, yellow and green window controls sit at the leading
edge, followed by compact navigation and a flat address/search field. A full-height
move grip sits beside the address field, followed by the window-actions menu.
Navigation, menu and drag icons use 13-point SF Symbols, sized alongside the
native window buttons.
The address field caps at 540 points so spare header space remains draggable.
The grip reserves 56 points when space allows and stays at least 24 points wide
in narrow panes. At the smallest widths, the actions button moves into the drag
area's context menu. Extensions, new-page and sizing actions are available there. The
address field gains a background on hover and a focus outline while editing.
Red closes the page, yellow minimizes its native window to the Dock, and green
enters fullscreen. Option-click green to zoom. Selecting a minimized page in the
sidebar restores it. Minimize, fullscreen and zoom preserve its group and stack;
normal tiling resumes when the page returns. Fullscreen and zoom use Chromium’s
conventional native controls until the page returns to its tiled position. Narrow windows move secondary controls into
that menu instead of squeezing the address field. The address field supports local development addresses. Cmd+L
focuses it while the managed browser is foreground; a configured WinMux binding
takes precedence. Escape restores the current URL and returns focus to the page.

Browser headers, WinMux window controls and the sidebar follow macOS light/dark
appearance by default, including changes while the workspace is running. The
shared neutral surface uses a hairline border and monochrome navigation controls.
The traffic lights use AppKit's native colors for the focused page and inactive
appearance for other pages; hover and keyboard focus provide emphasis. Appearance settings retain explicit solid color
presets and custom colors, with matching light or dark text for contrast. Choose
**Follow macOS** (`solid-chrome-color = 'system'`) to return to automatic colors.

The system browser frame uses AppKit's native titlebar material, blended within
the page backing, with one faint half-point outline. The header
uses that same backing without a duplicate material, border or corner separator. Explicit solid color presets
and custom colors remain opaque. Material activity follows page selection because
the helper panels do not become the browser's key window. Managed Chromium windows
omit the broad system shadow; releasing management restores each window's original
shadow. Small stretchable material masks keep rounded corners stable during resize.

Extensions opens Chromium's real extension menu when extensions are installed;
otherwise it opens the extension manager. Chromium still owns extension APIs,
permissions, menus and extension popups. Managed extension bubbles anchor to the
page window because Chromium's conventional toolbar is hidden.

Drag header whitespace or the trailing move grip to move a page with its controls.
WinMux previews the same drop zones as native windows: left/right and top/bottom
create splits, the top strip creates a stack, and the center swaps positions.
Release outside a destination or press Escape to restore the planned position.
Cross-workspace directional splits and stacks are supported; center swaps stay
within one workspace. A dragged page's native host identity remains stable.

Use the window-actions menu or `resize width +40` / `resize height -40` commands
to adjust split proportions. Native Chromium edge resizing also updates the shared
split on release. Sizes respect page/app minimums and persist with the workspace.
Pages in a stack must first be split to allocate independent space.

New pages created by Chromium shortcuts, page links, or extensions are detached
into independent native hosts, then adopted by the Swift workspace. Closing a
page is acknowledged only when the engine inventory confirms its removal.


## New tabs and pinned pages

Use **Option–Command–T** from any app to open a browser page in the current
regular group, including when every browser window is closed. **New Tab** in the sidebar
and its context menu provide the same action. The global shortcut is editable
under Settings → Shortcuts → Browser. Chromium keeps its usual **Command–T**;
the global default avoids taking that shortcut from other apps. The CLI action
is `browser-new-tab`.

Each Space has one pinned group above its regular groups. It uses icon-only
tiles, with cached website favicons and native app icons. Right-click a page and
choose **Pin Tab**, or an app window and choose **Pin App**; dragging an item into
the icon area also pins it. The item moves into the pinned group. Selecting its
icon activates that group's saved layout. Expanded tiles wrap across the sidebar;
compact mode uses one column, with scrolling after three rows.

Closing a page leaves its pin available. Clicking the closed pin opens its saved
URL in the original browser profile. The saved destination is the URL at pin
time; subsequent navigation does not change where it reopens. An app pin focuses
the app's last used window, or launches the app if none remain. One app launcher
is kept per Space. **Unpin** keeps the current window or page open and moves it
to the last regular group. Icons can be reordered by dragging and moved to
another Space from their context menu. New tabs and ordinary app windows created
while the pinned group is active go to that Space's last regular group.

Pins, order and layouts persist across restarts. Existing browser pins migrate
into their Space's pinned group without reopening closed pages. Empty pinned
groups stay hidden; regular group numbering is unchanged. Pinned groups cannot
be renamed, deleted or reordered with the regular groups.

## Implementation

Protocol 5 adds an authenticated browser-level page-creation request with an
optional source page and the exact created page identity in its reply. It can
create a page from the loaded browser profile when no windows remain. Protocol 4
adds typed navigation actions and an optional URL payload alongside
legacy focus/close operations. Inventory carries navigation/loading state,
managed-host status, native window identity and focus. Native minimize, fullscreen
and workspace zoom state suspend the live tile plan while preserving durable
page membership. AppKit lifecycle notifications update this state independently
of navigation. Epoch and revision checks
reject stale requests; a navigation request rejected before dispatch may retry
once against newer inventory. Dispatch acknowledgement is distinct from page
load or input readiness.

The Chromium patch retains normal BrowserWindow and extension controllers while
suppressing their tabstrip, toolbar, bookmarks and titlebar controls in managed
mode. A stable host mapping is keyed by complete persistent page identity,
including its profile. Stopping the workspace or losing the bridge restores
ordinary Chromium controls on retained windows; it does not close pages.

Swift header and pass-through backing panels use the ordinary window layer and
are ordered above and below their exact Chromium page host. During a drag, their
frames follow the observed native host at display refresh; temporary owner layouts
never enter the saved tree. Managed Chromium titlebar movement is disabled and
its original movement flags are restored when WinMux releases management. A shared geometry
calculation includes header, frame and gutters in layout minimums. The backing
never receives mouse or keyboard input. This integrates their visual frame while
retaining the separate Chromium host and helper-owned AppKit controls. They take keyboard focus for address editing and accessible
controls, and layout acknowledgements preserve that focus.

## Validation scope

The [2026-10-01 evidence](evidence/2026-10-01-native-page-windows.json) records
the successful signed engine build, 761 app tests, 52 native package tests,
35 packaging checks, and all 46 engine outcomes with stable reconnection.

The [2026-10-02 traffic-light evidence](evidence/2026-10-02-native-window-controls.json)
records 855 app tests, 84 native package tests, 39 tooling checks, and a verified
signed package. An isolated visible browser passed 74 engine outcomes, including
Dock minimize/restoration, fullscreen, native zoom and retained page/window
identity through peer layout changes. Headless navigation and bridge recovery
passed all 46 outcomes separately. Native clicks on the production header
dispatch close, minimize and fullscreen without changing the helper window.
The final local restart retained the saved profile and adopted all seven restored
pages, with one browser and one workspace helper running. A startup regression
checks that restored conventional hosts receive at least a 160×120-point managed
body before Chromium validates the complete layout. Local `surface list` output
reports observed host state and the last layout request/reply for diagnosis.

Unit coverage checks page/host separation, stack visibility, address
normalization, protocol negotiation, navigation state, stale-request handling,
resize minimums, fractional-pixel conservation and resize persistence. An
isolated signed headless harness exercises the real engine's host identities,
layout, navigation, actions and reconnection. Passing these checks does not
qualify extension compatibility, multi-display transitions or long-running daily
use. The traffic-light evidence adds native control dispatch and isolated window
transitions; broader Space and daily browsing behavior remain outside this scope.

Build the pinned engine with `browser/tools/build_alpha.py` and create a fresh
signed package with `browser/tools/package_alpha.py`, as described in
[browser/README.md](../../browser/README.md). Use Workspace Setup to stop the old
workspace, then quit that workspace's browser instance before activating a package
with the new UI. Quitting releases Chromium's profile lock so the new engine can
restore the same pages. Existing active workspace
services and profiles must not be replaced while running.
