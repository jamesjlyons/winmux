# Browser page windows

The current development workspace uses **Spaces containing Views**. A View can
contain one browser page, one Mac app window, or an explicit split or stack.
WorkspaceCore owns arrangement, proportions, and intended selection. Chromium
owns each page, its native window, navigation, profile, and extensions.

Every page retains its own native host when moved or stacked. A stack selects
one pane; a pane can itself contain a split. Only explicit stacks show WinMux
stack tabs. A single page has a compact toolbar and content, with no singleton
tab row.

## Integrated controls

Protocol 11 places the toolbar inside the Chromium page window. Back, Forward,
Reload, the address field, extensions, downloads, and the browser menu use
Chromium's controls and popup anchors. The macOS window buttons remain in that
same window. The toolbar and page therefore move and resize together.

Cmd+L selects the address field. Return navigates or searches using the profile's
search provider. Chromium owns editing, autocomplete, accessibility, and ordinary
browser shortcuts. Search suggestions and network prediction remain disabled.
Private autocomplete admits typed navigation/search and open pages in the same
private profile; it does not query regular-profile saved history. Named regular
profiles retain separate history, cookies, passwords, and extensions.

The browser menu includes **Keep Active**, **Block Ads and Trackers on This Site**
with the observed blocked-request count, and **Privacy Settings**. Settings open
as a sheet on the page's window. Consent writes complete atomically before the
new settings are acknowledged; a failed save reports an error.

Chromium owns extension pinning, artwork, permissions, download state, and their
menus. WinMux sidebar appearance settings apply to WinMux chrome; the integrated
browser controls follow Chromium's appearance.

Native minimize, fullscreen, and zoom preserve View membership. Selecting a
minimized page restores it. The page stays tabless during native fullscreen and
zoom; ordinary tiling resumes afterward. Releasing workspace management restores
the window's conventional Chromium presentation and original native attributes.

## Organization and gestures

Drag the browser's native frame to preview shared split, stack, and swap targets.
Native app windows use the same organization path. Edge resizing changes shared
split proportions on release, respecting each owner's minimum size. The complete
browser frame, including its toolbar, is the owner's tile. Explicit stack headers
occupy separate shared layout space.

New pages created by Chromium shortcuts, links, or extensions receive independent
hosts. Arrivals follow their source and configured placement policy. Existing
saved arrangements are reconciled before layout or sidebar projection; sidebar
reads do not create Views or change selection.

Use **Option–Command–T** from any app, **New Tab** in the sidebar, or
`browser-new-tab` to create a page. **New View** creates an intentional empty View.
The global shortcut is editable in Settings → Shortcuts → Browser.

Each Space has an ordered pin shelf. Pinning a View saves its members, layout,
selection, profile identities, and launch descriptors. Closing a pinned member
retains its slot. **Reopen Closed Items** restores missing members without
replacing the live members. Unpinning keeps the live arrangement as an ordinary
View. A native app pin binds the selected window; reopening launches the saved
app and waits for a newly created window rather than adopting an arbitrary one.

Session version 6 stores ordinary and pinned Views in the same saved model.
Legacy checkpoints migrate with a recoverable version-specific backup. Restoring
ordinary membership does not automatically launch closed pages. Cross-profile
moves reopen the URL in the destination profile and commit the saved identity
only after the existing profile transaction succeeds.

## Privacy and background pages

Workspace Setup asks before enabling security component updates, extension
updates, and daily ad/tracker filter updates. Direct launches read the same
consent. New profiles use Kagi, local blank pages, and blocked third-party cookies;
Chromium Settings retains ordinary cookie exceptions.

Filtering uses bundled rules offline. Consented updates compile before replacing
the current rules and retain a previous valid cache. The Performance Manager
policy keeps twelve recent eligible background pages warm. Older eligible pages
can freeze after two minutes and become discardable after fifteen; memory
pressure can reclaim eligible pages sooner. Visible/focused pages, media, calls,
capture, uploads, edited forms, before-unload handlers, DevTools, extension
protections, and **Keep Active** exclude pages from this policy.

## Compatibility and qualification

Protocol 4–10 peers retain the older helper-owned AppKit toolbar/backing panels
until integrated-window qualification and their retirement are complete.
Protocol 3 retains conventional Chromium controls. Version negotiation occurs
before capability use; an integrated layout requires explicit native host
ownership. Address focus uses the same generation fence as page/native focus,
so a stale request cannot override a newer selection.

The integrated toolbar is a development implementation. Its Chromium build,
Swift regressions, and isolated bridge fixtures are recorded in the
[simplification plan](../simplification-plan.md). Live keyboard/accessibility,
menus, fullscreen, dragging, and multiple-display qualification remain required
before the old toolbar path can be removed. The October 4 Alpha/Trial guides and
[performance audit](performance-audit.md) describe earlier builds; their measured
results do not establish readiness of this integration.
