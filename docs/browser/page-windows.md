# Native page windows

The browser workspace presents each Chromium page in its own native window.
WinMux's Swift surface tree owns placement, grouping, selection and split sizes.
A stack shares a rectangle: selecting another page hides one window and shows
another. Regrouping does not move WebContents between hosts or change the page's
native window ID. Native app windows can occupy the same workspace and groups.

## Controls

Each visible managed page has a continuous rounded frame and a 44-point native
AppKit header. Six-point outer insets separate neighboring pages. Close sits at
the leading edge, followed by navigation and an inset address/search field;
extensions, a window-actions menu and a move grip sit at the trailing
edge. New-page and sizing actions are available in the menu. The address field
highlights while editing. Narrow windows move secondary controls into that menu
instead of squeezing the address field. The address field supports local development addresses. Cmd+L
focuses it while the managed browser is foreground; a configured WinMux binding
takes precedence. Escape restores the current URL and returns focus to the page.

Browser headers, WinMux window controls and the sidebar follow macOS light/dark
appearance by default, including changes while the workspace is running. The
shared neutral surface uses a hairline border and monochrome controls; hover and
keyboard focus provide emphasis. Appearance settings retain explicit solid color
presets and custom colors, with matching light or dark text for contrast. Choose
**Follow macOS** (`solid-chrome-color = 'system'`) to return to automatic colors.

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

## Implementation

Protocol 4 adds typed navigation actions and an optional URL payload alongside
legacy focus/close operations. Inventory carries navigation/loading state,
managed-host status, native window identity and focus. Epoch and revision checks
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

Unit coverage checks page/host separation, stack visibility, address
normalization, protocol negotiation, navigation state, stale-request handling,
resize minimums, fractional-pixel conservation and resize persistence. An
isolated signed headless harness exercises the real engine's host identities,
layout, navigation, actions and reconnection. Passing these checks does not
qualify physical input, extension compatibility, display transitions, fullscreen,
or long-running daily use.

Build the pinned engine with `browser/tools/build_alpha.py` and create a fresh
signed package with `browser/tools/package_alpha.py`, as described in
[browser/README.md](../../browser/README.md). Use Workspace Setup to stop the old
workspace, then quit that workspace's browser instance before activating a package
with the new UI. Quitting releases Chromium's profile lock so the new engine can
restore the same pages. Existing active workspace
services and profiles must not be replaced while running.
