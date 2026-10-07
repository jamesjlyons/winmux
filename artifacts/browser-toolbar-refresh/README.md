# Browser toolbar refresh

The page header now provides Command-L address selection, first-click selection,
standard editing shortcuts (including Undo/Redo), Return navigation/search and
Escape cancellation. Reload, new-page, close and Downloads shortcuts remain
available during address entry.

The native header displays Chromium-owned pinned extension icons, a dedicated
Extensions menu and Downloads activity. Pinning persists in the browser profile;
right-click a pin to unpin it. Narrow layouts retain the actions in menus. The
24-point drag target stays five points from the right edge, and the URL field
uses the remaining width.

`after/toolbar-light.png` and `after/toolbar-dark.png` show production toolbar
components with fixed example extension icons and download activity. They are
component fixtures, not live extension/download screenshots; AppKit supplies the
traffic lights in real page windows.

Bridge protocol 9 carries the pinned extension inventory and download count.
Older engines retain the Extensions menu and a Downloads-page fallback.
Chromium owns extension permissions, pin preferences, popup content and download
management. Its hidden-toolbar download bubble is anchored to the managed page.

See `report.json` for final verification, source fingerprints and staged build.
