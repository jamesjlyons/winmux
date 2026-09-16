# Trackpad tab navigation

## Using the feature

In **Settings → Behavior → Trackpad**, enable **Three-finger swipe to switch
tabs**. It is off by default. Swipe left for the next tab or right for the previous
tab in the focused group; either direction wraps. Pointer position and Natural
Scrolling do not change the target or direction. Reverse direction is optional.

```toml
[trackpad-navigation]
enabled = false
reverse-direction = false
```

Reserve three-finger horizontal swipes for WinMux: in macOS Trackpad settings,
use four fingers for desktop/full-screen switching and two for page navigation.
Turn off three-finger dragging in Accessibility → Pointer Control → Trackpad
Options. The settings section links to both panes; WinMux does not change them.
Public global event monitoring cannot suppress native gesture actions.

One deliberate swipe changes one tab as soon as the threshold is crossed. Lift
all fingers before another switch; there is no cooldown between swipes. Rapid
swipes advance from the latest selected tab, and a new swipe can reverse an
in-progress two-window flip. Windows outside a tab group and one-tab groups
do nothing. Two-window pairs use their existing flip behavior; Screen Recording
is not required to switch, and Reduce Motion disables the rotation as before.

## Implementation

- `PrivateApi/trackpad.m` contains the dynamically loaded MultitouchSupport ABI.
  The bridge retains devices, copies/validates contacts, unregisters callbacks
  before stopping, and protects callback/context lifetime with a short lock.
- `TrackpadInputBackend` processes values on a serial queue. Only begin, commit,
  cancel, and end events reach the main actor. A watchdog runs only while contacts
  are present. Device matching/termination notifications trigger rediscovery.
- `TrackpadSwipeRecognizer` requires three matching contact identities,
  8% horizontal travel, horizontal dominance of 1.8, and completion within 1.5 s.
  There is no minimum duration: a clean fast flick commits on its threshold frame.
  A 250 ms stream gap cancels. Contact changes, button presses, vertical/diagonal
  motion, and simultaneous trackpads reject the sequence until release.
- `TrackpadNavigationController` snapshots the focused group and checks the
  frontmost application synchronously. It shares destination resolution with
  `focus tab-next` and `focus tab-prev`. The tab-click path updates selection and
  requests native focus immediately, without an AX query or asynchronous task hop.
  For 500 ms after a switch, the specific windows in that burst may emit late
  native-focus notifications without rolling selection back. Another app, an
  explicit focus change, mouse press, or key press ends this grace period.
- Two-window flips reuse their snapshots and reverse from their displayed
  rotation angles. New requests cancel the old completion timer; cancelled native
  focus jobs also check for cancellation between AX operations.
- Config reload, disablement, shutdown, lock/sleep, and device changes invalidate
  queued work. Sidebar scrolling suppresses a three-finger-owned sequence and its
  tail, while a fresh two-finger scroll remains available.
- Settings and `winmux doctor` expose availability. Missing private symbols or
  malformed frames leave the rest of WinMux operational. An input-format failure
  remains disabled until the feature is toggled off and on.

The current settings are also queryable with
`winmux config --get trackpad-navigation --json` or individual keys such as
`trackpad-navigation.enabled`.

The private framework is undocumented; successful loading is not proof of gesture
reliability. Test on the actual hardware after macOS updates.

## Validation

Automated coverage includes fast flicks, rapid bursts and reversals, late native
focus, explicit input cancellation, recognizer rejection/latching, tab ordering/wrapping,
stale subscriptions, lifecycle failures, frontmost-app mismatch, settings edits,
and sidebar momentum. Run `swift test --filter 'Trackpad|FocusCommandTest'`, then
the full `swift test` suite and `make dev-build`.

Physical acceptance remains a separate requirement: repeat both directions over
Safari, a terminal, another app, and the sidebar. Test two-finger scrolling,
four-finger gestures, partial/diagonal swipes, dragging, multiple displays,
sleep/lock recovery, and Magic Trackpad reconnection. Require one switch per
accepted swipe and none for rejected input. Inspect the `Trackpad tab activation`
signpost alongside visible tab highlight and native focus; test timings alone do
not establish input-to-visible latency.

### Responsiveness update verified on September 15, 2026

- Full Swift suite: 715 tests, zero failures, including fast flicks, consecutive
  swipes, direction reversals, cross-app activation lag, and cancellation.
- Signed optimized WinMux Dev build installed and relaunched. Live Accessibility
  remains granted and trackpad input reports `Ready · 1 trackpad`.
- All 13 windows present before the update were restored. Configuration is
  unchanged: swipe navigation enabled, reverse direction disabled.
- Physical feel of the updated gestures awaits user confirmation. Screen Capture
  remains unavailable, so the interruptible rotation has not been visually tested
  on this installation.

### Initial implementation verified on September 15, 2026

- Full Swift suite: 708 tests, zero failures.
- Signed WinMux Dev build; live Accessibility permission granted.
- All 12 pre-existing windows preserved through installation/restart.
- Live Settings controls start detection (`Ready · 1 trackpad`), persist reverse
  direction, and stop detection. Final configuration is disabled, direction normal.
- Native bridge completed ten register/unregister/start/stop cycles without a
  crash. No touch frames were captured in that short check, so it is lifecycle
  evidence only.
- Physical swipes, screen presentation latency, sleep/lock, external trackpad
  reconnection, and multi-display gestures have not yet been verified.

## Historical feasibility baseline

The personal fork is on `codex/trackpad-navigation`, based on upstream `e0ad328e`.
Upstream was fetched on September 13, 2026 and had no newer commits.

## Baseline on this Mac

- macOS 26.6.2 (25G83), one 1512 × 982 built-in display.
- Xcode's installed Swift 6.4; the repository pins 6.2.4, which is not installed.
- Unchanged `make build` passed. All 559 baseline tests passed.
- Upstream's `.debug` copy omitted Sparkle.framework, causing a dyld launch failure.
  The makefile now copies the framework and resource bundles.
- After supplying that framework, the unchanged debug app launched, reported
  Accessibility and Screen Capture granted, switched workspace and returned to
  its starting workspace. Debug mode pauses the release server while running.
- Live config was copied to `.local/baseline/winmux.toml` and
  `.local/winmux-dev.toml`; these ignored files contain personal configuration.
  Debug state uses `WinMux-Debug` Application Support, separate from release state.

## Probe

```sh
mkdir -p .local
clang -fobjc-arc -Wall -Wextra -framework AppKit -framework ApplicationServices \
  script/gestures/probe.m -o .local/gesture-probe
.local/gesture-probe 180 > .local/gesture-probe.log 2>&1
```

The duration is in seconds (maximum 1800). This standalone prototype only logs
input; it never changes workspaces, sends events, or suppresses native actions.
It compares public global NSEvent monitoring with a dynamically loaded private
MultitouchSupport backend. The latter validates basic contact ranges and logs
three-finger centroid movement, direction, completion, foreground app identifier,
and the pointer's display captured when three contacts begin. Logs stay local.

On this Mac the process reported Accessibility and Input Monitoring granted and
found one 18 × 24 trackpad sensor. The private symbols resolved and monitoring
started. Device enumeration is **not proof of reliable gesture recognition**.
Two three-contact sequences were subsequently observed over Codex. Both were
predominantly vertical and were cancelled (dx/dy −0.002/0.046 and −0.015/−0.088).
This confirms incoming contact data, but deliberate left/right swipes over the
other apps and native gesture conflicts still require the hands-on matrix below.
The prototype is intentionally not linked into the window manager.

Public global NSEvent monitors cannot suppress delivery; replacing the existing
local scroll monitor would not provide exclusive three-finger handling. Apple
also does not promise global raw finger count through that monitor. The private
backend provides a possible source of raw contacts but has undocumented ABI,
contact-state and teardown behavior. It is acceptable to evaluate for a personal
build; shipping it requires observed data and explicit lifecycle hardening.

## Hands-on matrix before navigation integration

Over Safari, a terminal, and another application, repeat left/right three-finger
swipes, two-finger scrolling, short/diagonal gestures, and clicking or dragging.
Check for one completed diagnostic action per deliberate swipe and zero actions
for scrolling or rejected motion. Repeat over the sidebar and each display.
Record any native desktop switching, page navigation, or three-finger dragging.
Repeat with an external Magic Trackpad if used, and after sleep/disconnection.

Observed preferences (read only): built-in and Bluetooth
`TrackpadThreeFingerHorizSwipeGesture = 2`; built-in `TrackpadThreeFingerDrag = 0`.
These undocumented preference values are recorded without assuming their UI
meaning. Check System Settings → Trackpad → More Gestures, plus Accessibility →
Pointer Control → Trackpad Options. No system preferences were changed.

The original workspace/project navigation proposal has been superseded by the
focused-tab behavior above. The standalone probe remains diagnostic-only.

## Sources

- [Apple global event monitoring](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))
- [Apple trackpad gestures](https://support.apple.com/en-us/102482)
- [Private ABI reference](https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h)
- [Current private backend diagnostic example](https://github.com/SomeGuyNamedDaveIsTaken/macOSMiddleClick/blob/main/dump.c)
