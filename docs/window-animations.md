# Native window animations

Native tiled windows animate when their layout changes, including native panes in
shared browser layouts. The defaults are:

```toml
animations.enabled = true
animations.duration-ms = 180
```

`duration-ms` controls the spring's approximate settling time, in milliseconds
(0–1000). Zero or `enabled = false` makes frame changes immediate. macOS Reduce
Motion also disables animation. Configuration changes take effect on reload.

Startup, workspace parking/restoration, tab reveals, direct mouse manipulation,
and moves to another monitor are immediate. Chromium-owned browser hosts continue
to use their existing layout protocol and do not use this AX animation path.

## How it works

The approach comes from studying [Dinky's Animator](https://github.com/mikker/Dinky/blob/58fff86a89c48d1b2dcc21f87d3709266d0b0d0c/Sources/dinky/Animator.swift)
and [FrameApplier](https://github.com/mikker/Dinky/blob/58fff86a89c48d1b2dcc21f87d3709266d0b0d0c/Sources/dinky/FrameApplier.swift).
Dinky drives spring-interpolated real window frames through Accessibility on
per-app queues, then performs a verified write at arrival. This does not require
capturing windows or disabling SIP.

WinMux uses its existing macOS 13-compatible display driver and per-app AX run
loops, with an analytic critically damped spring. A new target preserves the
current position and velocity. Superseded queued writes are cancelled, including
between individual AX calls. Intermediate writes avoid frame readback; arrival
uses the normal frame correction and minimum-size observation path. The tree
keeps destination frames while tab chrome uses the presentation frames.

An active animation consumes its own geometry notifications so they do not create
layout/drag feedback. Direct frame writes, hiding, closing, native fullscreen,
minimization and disabling WinMux cancel pending motion. A timer also advances
the animation if display callbacks stop, and final AX completion is time-bounded.

## Verification

`WindowFrameAnimationTest` covers convergence at 30/60/120/144 Hz, rate independence,
retargeting continuity, repeated targets, adjacent tile alignment, stalled clocks,
fractional final targets, AX coordinate conventions, transport cancellation,
monitor clamping and configuration validation. `WindowFrameUpdateTest` covers the
final verified writer.

For live verification, open two resizable native windows in a tiled View, change
their split with keyboard commands, and issue another move before the first one
finishes. Check a native stack's tab chrome, workspace changes during movement,
mouse drag interruption, an app with minimum-size constraints, and Reduce Motion.
Browser-owned hosts should retain their existing immediate placement behavior.
