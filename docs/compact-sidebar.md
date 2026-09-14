# Compact sidebar implementation and verification

The sidebar now responds to actual section width (panel width minus its content
insets): full at 176 points and above, narrow at 116–175, and minimal below 116.
This corresponds to expanded panel widths of 200+, 140–199, and 120–139.

- The collapsed rail fits down to 28 points. Outer padding scales with rail width;
  workspace badges, the creation button, project indicators and the optional clock
  fit the remaining space. Padding interpolates with section width during expansion
  so controls stay inside the visible rail throughout the transition. Compact drag
  targets use a highlight instead of showing expanded preview rows in the narrow rail.
- Right-click the sidebar background for Compact Mode and Auto-hide. Compact Mode
  controls whether the sidebar collapses; Auto-hide is available while Compact Mode
  is enabled and hides the resting rail. Both choices use the existing configuration
  settings, persist across launches, and refresh open Appearance settings.
- Window icons keep a fixed size. Narrow rows remove excess indentation, show one
  group icon, and omit secondary counts. Full titles remain in tooltips.
- Filters use a native menu when their inline controls would overflow. Narrow
  project footers use a native menu with creation, rename, color and delete actions.
- The clock uses a smaller time and simpler date layout when space is limited;
  its accessibility description retains the configured information.
- The trailing 8-point resize surface has a hover grip and horizontal resize
  cursor. Drag previews update the live config and panel model together; the
  existing layout refresh updates reserved space when always-expanded is on.
  Width is clamped to 120–480, above collapsed width, and within the target display
  (accounting for split browsing). Release writes once; Escape cancels; a double
  click resets to the configured default of 240.
- Project indicators retain color in the selected pill, have quieter inactive
  dots and a selected accessibility state. Hit areas remain 36 × 32 when expanded
  and use the available section width with 32-point height when collapsed.
  The dot track scrolls independently of sidebar project swipes. Selected projects
  scroll into view even after a prior mouse selection. The collapsed rail includes
  the active project even when there is only one.
- Sidebar swipes switch between existing projects. Creating a project by swiping
  past either end is off by default. Enable **Swipe to create projects** in
  **Settings → Appearance → Sidebar**, or set `swipe-to-create-projects = true`
  under `[workspace-sidebar]`. When disabled, edge swipes snap back without the
  creation preview or creation threshold haptic. The new-project button remains
  available.
- **Use menu bar style** in **Settings → Appearance → Sidebar** gives the sidebar
  clear Liquid Glass on macOS Tahoe and later, with adaptive foreground colors. It follows Light
  and Dark Mode and overrides only the sidebar's chrome. Set `menu-bar-style = true`
  under `[workspace-sidebar]`; the default is `false`. Turning it off restores the
  configured glass or solid style. Reduce Transparency uses an opaque system background.
  Earlier systems use ultra-thin material. Menu bar mode removes workspace cards and
  decorative outlines, uses compact menu typography and hover highlights, marks the
  active workspace with a checkmark, and replaces the large clock card with a small readout.

## Menu bar style verification

- Build and all 589 tests passed, including config defaults, legacy compatibility,
  invalid values, and toggling the setting without changing the saved chrome color.
- Generated 180 production-view fixtures across glass, solid, and menu bar styles,
  light/dark appearances, 1/3/12 projects, and widths from 28 to 240 points. Inspected
  menu bar style at expanded, narrow, and 28-point compact widths in both appearances.
- Rebuilt, signed, and launched WinMux Dev. Temporarily enabled the new material on
  the live compact sidebar, then restored the original config byte for byte.

## Verified on September 13, 2026

- Follow-up for the 28-point collapsed rail: 69 focused sidebar tests passed,
  including bounds checks throughout expansion from 28, 36, 40, 44, 60 and 120.
  Native renders cover 28, 36, 40, 44 and 60 collapsed widths and the existing
  expanded widths, with 1/12/128 workspace labels, 1/3/12 projects, both chrome
  styles and light/dark backdrops (120 images). WinMux Dev was rebuilt and
  relaunched with the user's current 28-point configuration; the live compact
  control fits and the configuration file remained unchanged.
- Unchanged baseline: `make build` and 559 tests passed with installed Swift 6.4.
- Updated app: all 564 tests passed, including five new width/config tests.
- Native production-view captures before and after at 240, 180, 140, 120 and 40
  points, with 1, 3 and 12 projects. Before captures demonstrate filter/footer
  overflow and clock truncation. The final renderer also covers solid and Liquid
  Glass with light/dark backdrops and starts at the last project to exercise
  overflow visibility.
- Live debug app: dragged 280 → 144; the development TOML recorded 144. Restarted,
  dragged to the 120 minimum, and double-clicked to reset to 240.
- Enabled always-expanded in the development config and dragged 240 → 180. The
  resulting tiled window frame began at x=188, matching 180 sidebar + 8 gap.
- Installed release configuration matches its backup. On release restart, WinMux
  removed the Browse workspace label; that entry alone was restored after checking
  there were no other differences. Development files and captures live under
  ignored `.local/`; runtime evidence is in `/tmp/winmux-*-*.log`.

To generate the visual matrix (without starting the window manager):

```sh
make build
.build/debug/winmux-marketing-renderer --sidebar-proof .local/sidebar-proofs
```

For a focused menu bar style pass at 28, 120 and 240 points over light/dark colored backdrops:

```sh
.build/debug/winmux-marketing-renderer --menu-bar-proof .local/tahoe-menu-bar-proofs
```

To run with a separate config:

```sh
WINMUX_CONFIG_PATH="$PWD/.local/winmux-dev.toml" make run
```

The development app disables the installed release manager on startup and
re-enables it on clean shutdown. It uses separate debug state. The probe and
rendered fixtures cannot establish real global navigation, multi-monitor ownership,
physical drag/drop alignment, sleep/reconnect behavior, or external trackpad
compatibility; those remain hands-on checks documented in
[trackpad-navigation.md](trackpad-navigation.md).

## Before a daily-use release

`project.yml` still declares the upstream release identity and Sparkle feed at
`ZimengXiong/winmux/releases/latest/download/appcast.xml`. Do not install a release
with that identity/feed as a personal fork. Give the packaged build a separate
bundle ID and disable both automatic and manual upstream update checks (or use a
fork-owned signed feed). Debug builds already omit Sparkle startup and the update
menu. No daily-use release has been installed by this work.
