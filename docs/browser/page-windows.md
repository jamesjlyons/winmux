# Native page windows

The browser workspace presents each Chromium page in its own native window.
WinMux's Swift surface tree owns placement, grouping, selection and split sizes.
A stack shares a rectangle: selecting another page hides one window and shows
another. Regrouping does not move WebContents between hosts or change the page's
native window ID. Native app windows can occupy the same workspace and groups.

## Controls

Each visible managed page has a 38-point native AppKit toolbar with Back,
Forward, Reload/Stop, an address/search field, Extensions, New Page, Close, and a
resize grip. The address field supports local development addresses. Cmd+L
focuses it while the managed browser is foreground; a configured WinMux binding
takes precedence. Escape restores the current URL and returns focus to the page.

Extensions opens Chromium's real extension menu when extensions are installed;
otherwise it opens the extension manager. Chromium still owns extension APIs,
permissions, menus and extension popups. Managed extension bubbles anchor to the
page window because Chromium's conventional toolbar is hidden.

Drag the toolbar's resize grip to adjust the nearest horizontal/vertical split,
or use its context menu, keyboard arrows, VoiceOver actions, or the existing
`resize width +40` / `resize height -40` commands. Split proportions persist with
the workspace and respect page/app minimum sizes. Pages in a stack must first be
split to allocate independent space. Native Chromium border dragging has not been
connected to the shared resize model; use WinMux's grip or resize command.

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

Swift toolbar panels use the ordinary window layer and are ordered relative to
their page host. They take keyboard focus for address editing and accessible
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
