# Dwindle tiling

In **Settings → Behavior → New windows**, set **New pages and windows** to
**Tiling in current view**, then choose **Dwindle (Dinky-style)** under
**Tiling algorithm**. The equivalent configuration is:

```toml
new-item-placement = 'tile'
tiling-algorithm = 'dwindle'
```

`adaptive` remains the default. Changing algorithms affects future tiled
arrivals; it does not rearrange existing Views. Full-view arrivals still create
separate Views, and floating native windows keep their existing behavior.

Dwindle inserts beside the focused pane along its longer dimension: wide panes
split into left/right tiles, tall panes into top/bottom tiles. If the immediate
parent already uses that axis, the new item joins it after the focused pane.
Otherwise, the focused pane becomes a nested pair. Existing sibling proportions
are preserved, and a new pair divides the old pane's allocation evenly.

The shared tree supports browser pages, native windows, and mixed arrangements.
Explicit stacks remain whole when splitting. The **Add app windows to active
stack** arrival policy still adds native tabs to the active stack. Minimum-size
constraints, gaps, temporary overflow stacks, resizing, and saved layouts use
the existing layout engine. Browser restoration and explicit pin/placement
actions retain their saved or requested organization. Standalone native tiling
uses the same focused-pane insertion rule.

The insertion rule is based on [Dinky's Workspace implementation](https://github.com/mikker/Dinky/blob/58fff86a89c48d1b2dcc21f87d3709266d0b0d0c/Sources/DinkyLayout/Workspace.swift).
WinMux retains its own stack and minimum-size behavior; this does not add
Dinky's fixed-grid or accordion modes.
