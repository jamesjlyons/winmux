# Trackpad navigation feasibility

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
Physical samples and native gesture conflicts still require the hands-on matrix
below. The prototype is intentionally not linked into the window manager.

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

## Navigation follow-up after recognition passes

Keep a pure, tested recognizer separate from the backend and a main-actor
navigation adapter. Freeze the display and navigation target at gesture start.
Require exactly three stable contacts, deliberate horizontal displacement, and
one action only after valid completion. Reject button drags, touch-count changes,
short motion, cancellation, stale streams, and sleep/disconnection. Ordinary
scrolling must not enter this recognizer.

Default: left advances a workspace within the current project; right goes back.
Settings: opt-in enabled, target (workspaces/projects), reverse direction. Do not
add settings until physical feasibility is confirmed. Project navigation must
use sidebar ordering and remembered workspace selection. Resolve an existing
neighbor before activation: workspace-next and sidebar edge swipes can create
new items, so do not call them as unguarded fallbacks. Keep other-monitor ownership
rules. Arbitrate the sidebar's existing local scroll handler to avoid duplication.

An external gesture-to-command bridge remains an alternative if the private
backend proves unreliable; it still needs a bounded navigation entry point.

## Sources

- [Apple global event monitoring](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))
- [Apple trackpad gestures](https://support.apple.com/en-us/102482)
- [Private ABI reference](https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h)
- [Current private backend diagnostic example](https://github.com/SomeGuyNamedDaveIsTaken/macOSMiddleClick/blob/main/dump.c)
