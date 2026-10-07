# Native page windows

The browser workspace presents each Chromium page in its own native window.
WinMux's Swift surface tree owns placement, grouping, selection and split sizes.
A stack shares a rectangle: selecting another page hides one window and shows
another. Regrouping does not move WebContents between hosts or change the page's
native window ID. Native app windows can occupy the same workspace and groups.

## Controls

Each visible managed page has a continuous rounded frame and a 36-point native
AppKit header. Four-point outer insets and a one-point frame separate neighboring
pages. AppKit's standard red, yellow and green window controls sit at the leading
edge, followed by compact navigation and a 26-point rounded address/search field.
Pinned extension icons, Extensions, Downloads and the window-actions menu follow
the field. A full-height move grip stays at the far-right edge.
Navigation, menu and drag icons use 13-point SF Symbols, sized alongside the
native window buttons.
The address field expands to fill available space. The grip keeps a 24-point target
with a five-point trailing inset at every width. At the smallest widths, secondary
buttons move into the drag area's context menu. Extensions, Downloads, new-page
and sizing actions remain available there. The
address field gains a background on hover and a focus outline while editing.
Red closes the page, yellow minimizes its native window to the Dock, and green
enters fullscreen. Option-click green to zoom. Selecting a minimized page in the
sidebar restores it. Minimize, fullscreen and zoom preserve its group and stack;
normal tiling resumes when the page returns. Fullscreen and zoom use Chromium’s
conventional native controls until the page returns to its tiled position. Narrow windows move secondary controls into
that menu instead of squeezing the address field. The address field supports local development addresses. Cmd+L
focuses it and selects all text while the managed browser is foreground; a
configured WinMux binding takes precedence. Clicking the field initially selects
the address; subsequent clicks position the caret. Standard select/copy/paste/cut
and undo/redo shortcuts work while editing. Return navigates or searches using the
profile's search provider. Escape restores the current URL and returns focus to
the page. Command-R, Command-T, Command-W and Command-Shift-J remain available
while editing for reload, new page, close page and downloads respectively.

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

The puzzle-piece Extensions button opens Chromium's real extension menu when extensions are installed;
otherwise it opens the extension manager. Chromium still owns extension APIs,
permissions, menus and extension popups. Managed extension bubbles anchor to the
page window because Chromium's conventional toolbar is hidden. Pin extensions in
that menu to display their icons in the native header; right-click an icon to
unpin it. Pin order and persistence belong to the Chromium profile. Policy-pinned
extensions and incognito windows cannot change pins. Narrow panes hide overflowing
pins, which remain accessible from the Extensions menu.

All toolbar icons are monochrome, including extension artwork. Active downloads
use a filled icon with stronger neutral contrast instead of an accent color.
Downloads opens Chromium's recent-download bubble, or its downloads page when
there are no recent items. Active transfers emphasize the button and show their
count in its tooltip and accessibility label. The bubble anchors beneath the
managed page header. Pinned icons and native downloads require bridge protocol 9;
older engines retain the Extensions menu and open the downloads page.

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

Each Space has one ordered pin shelf above its regular Groups. Right-click a
page and choose **Pin Tab**, or an app window and choose **Pin App**; dragging
into the shelf also pins it. Each independent pin gets a full desktop. Pinning
a member of an existing split or stack preserves its outermost explicit group,
without including unrelated root siblings. **Pin Group** in a Group's menu keeps
the whole Group together. Group tiles combine member icons and show a count.

An app pin binds the exact selected native window. Two windows of the same app
can have separate pins. Closing a member retains its launch descriptor and layout
slot. A browser member reopens the URL saved at pin time in its original profile.
An app member launches its saved app and binds only a newly created window; it
does not restore an arbitrary document or adopt another existing window.

Selecting a partially open group focuses its remembered live member. Use
**Reopen Closed Items** to restore the missing members. Selecting a completely
closed pin reopens its saved members. Reopening a partial group preserves live
focus. **Unpin** converts the desktop to a regular Group, retaining its live
contents, layout, and former position when available. Icons can be reordered
and moved between Spaces. New ordinary pages and app windows go to the Space's
last regular Group while a pin is selected.

Session version 5 saves the shelf order, desktop identities, member launch
descriptors, and complete layout templates, including closed slots. Versions
2–4 remain readable. Legacy pins migrate without opening closed pages.

## Privacy and background pages

Workspace Setup saves three separate choices before starting Chromium:
component updates, extension updates, and daily ad/tracker filter updates.
All are off until enabled. Direct browser launches read the same bootstrap file
before constructing services. Telemetry uploads, crash uploads, search
suggestions, and network prediction remain disabled. New tabs are local blank
pages. New profiles default to Kagi; **Privacy Settings** changes the search URL
used by both the native address field and Chromium. Third-party cookies are
blocked by default, with Chromium's ordinary site exceptions available in Settings.

The page menu shows the site's blocked-request count and a per-profile blocking
switch. Filtering uses bundled rules offline. Consented daily updates compile
before replacing the current rules, retain a previous valid cache, and cannot
install executable replacement resources. Dynamic cosmetic filtering receives
bounded DOM-token changes through an isolated, browser-authored collector.

The Performance Manager policy keeps twelve recent eligible background pages
warm. Older eligible pages freeze after two minutes and become discardable after
fifteen. An 8 GiB soft process-footprint budget or OS memory pressure can discard
older eligible pages sooner, one at a time. Visible/focused pages, media, calls,
capture, uploads, edited forms, before-unload handlers, DevTools, extension
protections, and **Keep Active** exclude pages from this policy. Every visible
split pane wakes on selection. Native apps are outside the policy.

The warm/frozen/Space switching targets of 50/100/150 ms require live browser
qualification; unit tests and blocker microbenchmarks do not establish them.

## Implementation

Protocol 6 adds privacy, search, site-blocking, and Keep Active actions, plus
lifecycle and blocking state in inventory. These actions are gated on the
negotiated version. Privacy changes acknowledge an atomic consent write before
updating displayed state. Protocol 5 adds a browser-level page-creation request with an
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
