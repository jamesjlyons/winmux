
<p align="left">
  <img src="resources/winmux-logo.svg" width="80" alt="WinMux logo">
</p>

# WinMux

<p align="left">A powerful sidebar-first window manager for macOS.</p>

## Changes in this fork

This fork of [WinMux](https://github.com/ZimengXiong/winmux) adds a more flexible sidebar,
easier ways to organize windows, trackpad gestures, and layout restoration when you restart
the app. Browser Alpha adds Chromium pages to the same workspace as Mac app windows.

### Browser Alpha

The October 4, 2026 draft candidate packages **WinMux Browser Alpha.app** for testing
on another Mac. See the [download, installation, and test guide](docs/browser/alpha-release-2026-10-04.md).

- **Browser pages and Mac windows together.** Organize both in Spaces and Groups,
  with independent page windows, native navigation controls, splits, stacks, and saved layouts.
- **New tabs from any app.** Press **Option–Command–T** to open a page in the current
  regular Group. The shortcut is editable in Settings → Shortcuts → Browser.
- **Pins for each Space.** Pin pages and apps into an icon group above the regular
  Groups. Pins, their order, and layouts survive restarts; a closed page pin reopens
  its saved URL, and an app pin focuses or launches its app.
- **Separate setup and data.** Workspace Setup starts the native helper and a separate
  browser profile. Stop Workspace restores native windows and leaves the browser open.

This candidate is **Apple silicon (arm64) only**, signed with Apple Development,
and **not notarized**. The binaries target macOS 13 or later; recorded live testing
used macOS 27.0.1 on an M1 Pro. Other Macs and macOS versions still need validation.

The latest audit passed **1,096 automated tests**. On that Mac, 50 Group/native-pin
switches showed no frame drift; median matching geometry was observed by 82–90 ms.
Three full helper/browser restarts restored managed geometry within 4.50–4.90 seconds.
These are observation bounds with existing data and warm OS caches, not page-load
or input-readiness measurements. See the [performance audit](docs/browser/performance-audit.md)
for results and limits, and [page controls and pins](docs/browser/page-windows.md)
for the interface.

### Sidebar

- **A smaller sidebar.** The compact sidebar now fits down to 28 points.
  Labels, buttons, icons, and the clock adjust to narrower widths.
- **Drag the edge to resize it.** Your width is saved when you let go. Press Escape to
  cancel or double-click the edge to reset. Windows make room when the sidebar stays expanded.
- **Change its behavior with a right-click.** Toggle Compact Mode and Auto-hide directly
  from the sidebar.
- **Choose a menu bar look.** An optional translucent style uses smaller controls and a
  simple clock. It follows your Mac's appearance and accessibility settings, with Liquid
  Glass on macOS 26 and later.
- **Open and close with less delay.** Hovering opens the sidebar immediately. Moving away
  closes it sooner, and moving back reverses the close. It stays open while you use a menu,
  edit a name, resize, or drag something.
- **Cleaner details.** Labels are lighter, spacing is tighter, and space indicators are
  evenly sized. The selected indicator is brighter, with its name shown directly above
  it on hover. The app also has a native monochrome menu bar icon.
- **More room in fullscreen.** Fullscreen windows and tab groups hide the sidebar and
  reclaim its space on that display. Leaving fullscreen brings it back.

[Sidebar guide](docs/compact-sidebar.md) · [Opening and closing changes](docs/sidebar-responsiveness.md)

### Organizing windows

- **Spaces → Groups → Windows.** Projects are now called Spaces, and Workspaces are
  called Groups. Your existing names and layouts carry over. CLI commands and config
  keys keep their old names so existing setups continue to work.
- **One menu for your spaces.** Switch, create, rename, color, or delete spaces from the
  menu at the top of the sidebar. Display filters live there too, replacing the duplicate
  controls that used to appear at the bottom.
- **See every space in Organize.** This replaces Browse Alongside with a column for each
  space. Drag windows or whole tab groups between them, or drop onto New Group. Search
  and display filters work across all columns, and dragging near an edge scrolls the view.
- **Drag spaces and groups into order.** Rearrange space dots or icons, including Default.
  Drag group headers or compact badges to reorder groups within a space. Groups move aside
  as you drag, with a small trackpad tick at each position. Your order survives a restart.
- **Give spaces their own icons.** Choose Icon… opens a searchable SF Symbols picker that
  works offline and supports the keyboard. Icons use the space's color and stay attached
  when you rename or reorder it. Use Default brings back the colored dot.

[Organize and reordering guide](docs/compact-sidebar.md) · [Space icons](docs/project-icons.md)

### Trackpad gestures

- **Swipe between tabs with three fingers.** Turn this on in Settings → Behavior → Trackpad.
  Swipe left for the next tab and right for the previous one, wrapping at either end.
  It acts on the focused tab group wherever your pointer is. You can reverse the direction.
- **Keep swiping without waiting.** Each swipe changes one tab. Lift your fingers and swipe
  again immediately; reversing direction can also reverse an ongoing two-window flip.
- **Fewer accidental actions.** Short or diagonal gestures are ignored. Tab gestures
  don't also switch sidebar spaces, and two-finger scrolling remains available.
- **Sidebar swipes follow your Mac's scroll direction.** Swiping past the first or last
  space creates another only if you enable **Swipe to create spaces**, which is off by default.

Three-finger navigation is off by default and uses a private macOS framework. The
[trackpad guide](docs/trackpad-navigation.md) explains setup, conflicts with macOS gestures,
status checks, and the hardware testing still needed.

### Restarting and permissions

- **Pick up where you left off.** Restarting WinMux restores the arrangement of windows
  that are still open: spaces, group order, displays, tiles, tabs, floating positions,
  and the selected window. This applies within the same Mac session; it doesn't reopen
  apps or documents after a reboot.
- **Recover from interruptions.** Layouts are saved as you work, with a backup if the
  latest save is damaged. Restoration handles windows that take longer to appear and
  disconnected displays, and leaves a group alone once you start changing it.
- **Save before quitting.** Normal quits and system termination save the final layout
  before cleanup. Force Quit uses the most recent saved checkpoint. Dev builds and
  separate config files keep their own sessions.
- **Fewer permission interruptions.** WinMux waits for Accessibility permission and
  continues when you grant it, without resetting access. Screen Recording is requested
  when you choose a feature that needs it, rather than on every launch.

[Session restoration and permissions](docs/restart-sessions.md)

### Performance

Several changes reduce the work WinMux does during everyday interactions:

- Moving or resizing a window updates the affected windows instead of scanning every app.
- Drag previews follow the display's refresh rate and avoid repeatedly copying the whole layout.
- Window placement and keyboard focus happen before sidebar and tab updates.
- Window titles load in the background, so one slow app doesn't hold up other title updates.
- Group lists and saved layouts skip repeated calculations and unnecessary updates.
- Saving layouts runs separately from the interface and avoids writing unchanged data.

The measurements and their limits are recorded in the [interaction notes](docs/performance-updates.md),
[model and layout audit](docs/performance-deep-dive.md), [follow-up audit](docs/performance-follow-up.md),
and [focus notes](docs/focus-performance.md).

### Development builds and testing

- **Use the pinned Swift compiler.** `.swift-version` selects Swift 6.4.0 for local
  builds and CI through Swiftly 1.2 or later. Swift 6.2.4 crashes while serializing the settings
  view's `isolated deinit`; the newer compiler preserves its actor-safe cleanup.
- **A separate WinMux Dev app.** It has its own name and saved state, with upstream
  automatic updates disabled. Signed updates keep a stable app identity to help preserve
  permissions. Installation checks the signature and prevents replacing a running copy.
- **Optimized builds by default.** The Dev build and test commands use compiler optimization
  for everyday use, with a Debug option for development. Packaging now includes the
  frameworks and resources needed to launch correctly.
- **More ways to check changes.** Added visual fixtures for sidebar sizes, appearances,
  and icons; trackpad, focus, and resize diagnostics; performance logging; an icon catalog
  generator; and regression tests for the new behavior.

To build standalone WinMux Dev, follow the [Dev setup](docs/restart-sessions.md).
It requires an Apple Development signing certificate. The Homebrew instructions below
install the original WinMux. See [Dev build performance](docs/app-speed.md) for the
build options and measurements.

---

https://github.com/user-attachments/assets/51983568-a168-494f-8ae3-5f50ca1efce1

## Highlights
### Spaces and groups
Spaces organize your contexts. Each group holds related windows, whether they belong to a project or an activity:

```text
Tap Five (Space)
├── Subdivide (Group)
│   └── Windows
└── Moment Notes (Group)
    └── Windows

Personal (Space)
└── Portfolio (Group)
    └── Windows
```

Switch spaces to change context, then select a group to bring its windows into view.
The sidebar calls the top level **Spaces** (formerly Projects) and the window groups
**Groups** (formerly Workspaces). Existing custom names and saved layouts are preserved.

Configuration keys and CLI commands retain their existing names for compatibility:
`project` commands and `project-labels` address Spaces; `workspace` commands and
`workspace-labels` address Groups.

### Sidebar
The sidebar is a more interactively-performant and useful alternative to [Sketchybar](https://github.com/felixkratz/sketchybar) and traditional window-manager menu bar dropdowns for most everyday tasks. It makes your spaces, groups, and windows visible on the desktop.

You can drag windows in and out of the sidebar from and to the current group. You can rearrange windows across groups using the sidebar, including tab groups.

By default the sidebar rests as a compact rail and expands when hovered. To hide the rail
completely until the pointer reaches the left display edge, enable auto-hide. On macOS 26 and
newer, native Liquid Glass is enabled by default. Choose an opaque solid color for greater
contrast across the sidebar, tab groups, and switcher:

```toml
[workspace-sidebar]
    auto-hide = true
    chrome-style = 'solid'
    solid-chrome-color = 'lavender' # Choose any color shown in Appearance, including custom.
```

For a flat, translucent macOS menu bar look, enable **Settings → Appearance → Sidebar →
Use menu bar style**, or set `menu-bar-style = true` under `[workspace-sidebar]`.
On macOS Tahoe and later, the sidebar uses clear Liquid Glass with a light contrast
wash, compact menu typography, borderless controls, and a small clock readout. It follows
Light and Dark Mode and honors Reduce Transparency. Earlier systems use ultra-thin
material. Turning it off restores the selected chrome style. Tab groups and the switcher
continue to use the Chrome setting.

To keep the full sidebar visible, reserve its expanded width when laying out tiled windows:

```toml
[workspace-sidebar]
    always-expanded = true
    width = 240
```

`auto-hide` works with both compact and expanded modes. With both options enabled, the full
sidebar appears at the left display edge and hides when the pointer leaves, without reserving
space for it. With auto-hide off, `gaps.outer.left` remains the spacing between the sticky
sidebar and tiled windows, and monitor selection controls which displays reserve sidebar space.

The sidebar clock can be configured independently:

```toml
[workspace-sidebar]
    show-clock = true
    show-seconds = true
    show-date = true
    show-weekday = true
```

`show-clock` hides the entire clock card. The other settings independently control seconds,
the month and day, and the weekday; for example, `show-date = false` with
`show-weekday = true` leaves a weekday-only calendar label in the expanded sidebar.

### Window and sidebar spacing

The `[gaps]` settings control the visible borders around tiled windows. `inner.horizontal`
and `inner.vertical` set the space between neighboring windows. The outer gaps set the space
at each display edge; when the sidebar is enabled, `outer.left` is the space between the
sidebar and the tiled windows. Any of these values can be reduced or set to zero independently.

For borderless tiling, including no border beside the sidebar:

```toml
[gaps]
    inner.horizontal = 0
    inner.vertical = 0
    outer.left = 0
    outer.bottom = 0
    outer.top = 0
    outer.right = 0
```
### Tab Groups
![](resources/screenshots/tab-groups.png)
Tab groups allow you to have many windows occupy the same footprint, similar to Yabai stacks but with browser-like tab behavior. This is useful when you want to have multiple pieces of reference information next to an editor, multiple tabs in different browser profiles, or, when you simply want multiple fullscreen views without the additional friction and overhead of creating a new group.

Unlike stack-only layouts, WinMux tab groups behave more intuitively like you would expect tabs to in browsers, and don't need a keyboard shortcut to activate. You can drag tabs from tab groups into another window's [intent zone](#managed-tiling-mode), or in between groups. You can also rearrange tab order within a tab group, and navigate through them with relative and absolute keybindings.

### Philosophy

#### Automatic tiling

WinMux tiles newly discovered windows by default. To keep their existing macOS size and position while still using WinMux's sidebar, groups, and manual layout commands, disable automatic tiling:

```toml
automatically-tile-new-windows = false
```

This applies to windows discovered when WinMux starts and windows opened later. You can still tile an individual floating window with `winmux layout tiling` or the configured `layout floating tiling` shortcut.

While dragging a window by its title bar, shake it horizontally to toggle between floating and tiling. The gesture requires several deliberate direction changes in quick succession, and does not activate during resize, sidebar, tab-strip, or tab-group drags. Disable it with:

```toml
enable-shake-to-toggle-tiling = false
```

#### Groups
Each space keeps at least one group available. Empty groups may be cleaned up automatically; configured persistent groups remain available.

### Multi-Monitors
Monitors share spaces and groups. Each monitor can independently browse spaces and select a group to view.

Monitors cannot show the same group at the same time. They can show different groups from the same space.

#### App Launching
WinMux supports single-modifer keybindings (e.g. triggering an action on press of `⌘`)

I highly recommend that you configure the apps you use every day to be launch with Left/Right Option+Command, or similar shortcuts, otherwise it might be hard to launch common things into the current group (and instead, take you to the other group where the app is currently active). Here is some of the apps that I have keybinded:

```toml
[mode.main.binding-tap]
    left-alt = 'exec-and-forget /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --profile-directory="Default"'
    right-cmd = 'exec-and-forget /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --profile-directory="Profile 1"'

[mode.main.binding]
    # Disable the native "Hide App" shortcut.
    cmd-h = []

    cmd-d = 'exec-and-forget osascript ~/Documents/scripts/launchTerminalWindow.scpt'
    cmd-e = 'exec-and-forget osascript ~/Documents/scripts/launchFinderWindow.scpt'
```

```applescript
# ~/Documents/scripts/launchTerminalWindow.scpt
tell application "cmux"
    if it is running
        tell application "System Events" to tell process "cmux"
            click menu item "New Window" of menu "File" of menu bar 1
        end tell
    else
        activate
    end if
end tell

# ~/Documents/scripts/launchFinderWindow.scpt
tell application "Finder"
    if it is running
        tell application "System Events" to tell process "Finder"
            click menu item "New Finder Window" of menu "File" of menu bar 1
        end tell
    else
        activate
    end if
end tell

```

## Installation

### Browser Alpha from this fork

Use the [Browser Alpha release guide](docs/browser/alpha-release-2026-10-04.md) for
the draft candidate, checksum, permissions, smoke tests, and rollback. It uses
its own browser profile and native state; the standalone migration below does
not apply to Workspace Setup.

For the standalone development app, use the
[signed Dev build and restart-session workflow](docs/restart-sessions.md).
It installs **WinMux Dev** separately and preserves its signing identity across rebuilds.

### Original WinMux from upstream

These Homebrew commands install [the original WinMux](https://github.com/ZimengXiong/winmux),
not this fork's Browser Alpha or WinMux Dev:

```shell
brew tap ZimengXiong/homebrew https://github.com/ZimengXiong/homebrew
brew trust ZimengXiong/homebrew
brew install --cask winmux
```

Or download a binary from [upstream releases](https://github.com/ZimengXiong/winmux/releases)
and follow its installation instructions. The original WinMux checks GitHub Releases
for signed updates and offers **Check for Updates…** in its menu bar. This is separate
from the Browser Alpha candidate.

## Migrating standalone WinMux
### From AeroSpace
If `~/.config/winmux/winmux.toml` already exists, WinMux uses it as-is.

If you have an AeroSpace config but no WinMux config yet, WinMux creates one for you on first launch. It copies over your AeroSpace shortcuts/key mapping and fills in the rest with WinMux defaults, including the sidebar and window tabs.

You do not need to edit anything to get started. After import, WinMux uses `~/.config/winmux/winmux.toml` and leaves your AeroSpace config alone.

If neither exists, WinMux creates a new WinMux config with the bundled defaults.

## Credits
[Aerospace](https://github.com/nikitabobko/AeroSpace)
