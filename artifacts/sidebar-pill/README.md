# Sidebar pill refinement

The expanded sidebar uses 32-point selection and hover surfaces within its existing
34-point rows, with 16-point corners. Moving and stationary selections share the
same shape, shadow strength and focus emphasis. Inactive labels use regular weight,
with an 8-point icon-to-label gap.

Arrangement headings use smaller text and an active dot. Their ordinary expanded
backgrounds are clear; compact grouping, drop feedback and display ownership
indicators remain available. Close controls appear for hovered rows and keyboard
search targets, with their width always reserved. Drag previews and batch-selection
outlines use the same capsule geometry; horizontal tab outlines retain their
existing appearance.

`sidebar-light.png` and `sidebar-dark.png` render production SwiftUI components in
isolated compositor windows. They show a full example sidebar and resting, hovered,
focused, remembered-selection, keyboard-target and batch-selection states. These
are fixed fixtures, not captures of the installed alpha or the user's windows.

Generate the previews:

```sh
swift build --product winmux-marketing-renderer
.build/debug/winmux-marketing-renderer --sidebar-pill-proof artifacts/sidebar-pill
```

The dark system sidebar uses a neutral `#111111` foundation, `#191919` hover,
`#1E1E1E` focused selection and a `#303030` outline. Remembered selections in other
stacks use a quieter `#1B1B1B` surface. Dark tab shadows give way to the outline;
titles brighten from `#A3A3A3` to `#EEEEEE` on hover or selection, while group
headings remain subdued. The light palette and row geometry are retained.
The light preview's decoded pixels are identical before and after the dark pass.
Custom background colors and material settings remain configurable. This pass
does not add activity metadata or alter pane chrome.

Search now highlights matching title substrings using the same Unicode-aware,
case-insensitive comparison as filtering. Repeated and overlapping matches merge
without changing the displayed spelling. App, project and arrangement context can
still match without marking unrelated title text. Filtering preserves row order,
stack identity, total arrangement counts and the actual focused window. The blue
keyboard outline identifies the result that Return will activate independently
of the active window's raised pill.

Removed rows fade over 90 ms; surviving rows reflow over 180 ms. Search temporarily
expands matching arrangements and restores their saved collapse state when cleared.
The disclosure chevron rotates with expansion; collapsing fades the children and
retains the active arrangement dot. Filtered groups keep transparent backgrounds.

Nearby selections use the critically damped spring. A change beyond five row heights,
or involving a partly/offscreen endpoint, crossfades over 120 ms. Geometry changes
to the same selected row follow layout directly rather than starting another spring.
Reduce Motion bypasses these transitions. Selection geometry stays in scroll-content
coordinates, so ordinary scroll offsets do not retarget the spring.

`filter-light.png` and `filter-dark.png` show all tabs, a collapsed arrangement, and
two filter results. `sidebar-interactions.mp4` records production arrangement rows,
filtering and selection components in both themes, using fixed fixture data and
annotation captions. It includes filtering a collapsed arrangement, restoring that
collapse, a nearby switch and distant switches. These specimens omit the full
sidebar shell. `filter-*ms.png` captures intermediate frames; the filename is a
requested capture delay, not a measured animation benchmark.

```sh
.build/debug/winmux-marketing-renderer --sidebar-filter-proof artifacts/sidebar-pill
.build/debug/winmux-marketing-renderer --sidebar-filter-video artifacts/sidebar-pill/sidebar-interactions.mp4
```

Validation: 248 sidebar, surface-interaction, multi-selection and chrome selection
tests pass, including six new search/motion regression tests. The lazy-list checks
mount 14 of 200 standalone tabs and 13 of 200 arrangement children; 20 continuous
swipe updates cause zero content rebuilds. Width fixtures cover 240, 190, 140 and
40 points in light and dark mode. Changes are built in the workspace; the installed
alpha is not replaced by these render commands.
