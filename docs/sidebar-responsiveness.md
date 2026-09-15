# Sidebar opening and closing — September 15, 2026

## Causes

- Every pointer update inside an expanded sidebar called `expandSidebar`. That method
  posted another expansion notification and assigned the published expanded flag before
  checking whether the width had changed. In the baseline regression fixture, 100 requests
  to retain the same open width produced **100 model publications and 100 notifications**.
- `isWorkspaceSidebarExpanded` is controller bookkeeping. It is not part of the rendered
  sidebar snapshot, which uses `workspaceSidebarVisibleWidth`. Publishing the flag separately
  invalidated the view around the actual width update.
- Closing waited 160 ms, then animated for a separate interval. The collapse notification
  arrived before that wait, starting a separate pager-removal transition. Further pointer
  events could schedule another collapse while finalization was already pending.
- A 20-point exit margin and 30 Hz pointer coalescing delayed recognition of departure.
  Closing a menu also retained expansion for 750 ms, with a later recheck for a stationary cursor.

The baseline Time Profiler recording used eight command-driven open/close pairs in the live
Dev app. It contained 2,226 running main-thread samples, including 980 under hosting-view
layout and 336 under the expanded-flag setter. These are overlapping stack counts, not
independent costs or dropped-frame measurements.

## Changes

Expansion now cancels pending close work and returns immediately when the sidebar is already
at the requested open width. The bookkeeping flag no longer publishes. Width changes still
publish, and the view retains its normal model updates for content, configuration, and browsing.

Collapse uses one 40 ms exit grace period. Content stays intact during that grace period;
the collapse notification and width change start together after pointer and interaction-lock
checks. A pending finalization prevents another close from being scheduled. Reentry cancels
either stage and can reverse a close already in progress.

The sidebar uses bounded ease-out animations: 140 ms to open and 100 ms to close. The exit
margin is 6 points and pointer events are coalesced at up to 60 Hz, without an idle timer.
Menu-end grace is 120 ms, with one recheck 10 ms afterward so a stationary pointer still closes
the sidebar. Active menus, editors, resize gestures, and drag operations retain their locks.
The separate pager placeholder and its expansion/collapse state flags have been removed.
Reduce Motion disables the width animation and inherited child animations for that transaction.

| Configured timing | Before | After |
| --- | ---: | ---: |
| Hover-exit grace | 160 ms | 40 ms |
| Close animation/finalization interval | 80 ms | 100 ms |
| Combined close intervals, excluding event delivery/rendering | 240 ms | 140 ms |
| Pointer coalescing interval | 33.3 ms | 16.7 ms |
| Menu-end grace | 750 ms | 120 ms |

These are configured intervals, not measured screen-presentation latency. The old spring
response and its separate cleanup timer did not specify the same animation duration.

## Validation

The transition tests exercise duplicate open requests, unchanged rendered snapshots, exit
grace cancellation, repeated pointer activity during finalization, reentry during a close,
completion of a real scheduled close, and menu/editor locks. They assert state and work
counts; the asynchronous close fixture reports elapsed time without a brittle timing threshold.

- All **687 tests passed** in the optimized checkout, including eight new transition tests
  and the separate icon/Organize work already in progress.
- The 100-request fixture now produces **zero publications and zero expansion notifications**.
- The offscreen AppKit close fixture reached its final resting state in **157.2 ms**, including
  scheduler and test polling overhead. This measures controller completion, not screen presentation.
- `git diff --check` passed. Existing sidebar feature changes were preserved.
- The optimized Dev app was built, signed, installed, and left running. Strict signature
  verification passed; Accessibility remained granted. All 16 original window IDs and the
  configuration fingerprint matched after the restart and UI checks.
- Live command-driven opening/closing, the Space menu, menu dismissal with Escape, and
  closing the keyboard-opened sidebar with Escape passed. The resting rail retained its
  group and space controls. Physical hover presentation/frame pacing remains a separate
  check; the automated hover tests exercise the controller with an offscreen panel.

## Live command/profile comparison

Both accepted traces contain all 16 light sessions for eight open/close pairs on the same
LG UltraFine (3072 × 1728), with a 450 ms pause after each command. An initial updated trace
missed the first eight commands during profiler startup and is excluded. Its replacement
waited eight seconds for the profiler before starting. CPU sample counts below use the
interval from the first session start through 200 ms after the final session ends.

| Metric | Before | Updated |
| --- | ---: | ---: |
| CLI completion median, including process startup | 85.4 ms | 27.1 ms |
| Captured light sessions | 16 | 16 |
| Failed commands | 0 | 0 |
| Main-thread running samples in the command sequence | 2,191 | 2,765 |
| Samples under hosting-view layout, inclusive | 963 | 1,560 |
| Samples under the expanded-flag setter, inclusive | 336 | 0 |

Command acknowledgement improved in this small sequential sample, and the unnecessary
setter work disappeared. Rendering CPU did **not** improve in this comparison; it is not
evidence of a frame-rate or CPU-saving improvement. The changes target delayed transition
starts, duplicate state changes, and a shorter close grace period. The local builds also
include the separate icon/Organize work. System load and rendering caches can vary between
runs, so do not generalize these figures to every hover interaction.

## Reproduce

```sh
swift test --disable-sandbox -c release -Xswiftc -DDEBUG --filter WorkspaceSidebarTransitionTest
make dev-test
make dev-build VERSION=0.0.0
```

With Dev running, inspect hover entry, departure just outside the sidebar, quick reentry,
menu dismissal with a stationary pointer, keyboard opening/Escape, and an active drag/editor.
Use the same display, configuration, and app load for comparisons. `winmux open-sidebar`
toggles the command-driven path; it does not measure the hover-exit grace period.
`Sidebar width publication` signposts measure publication work, not the animation's completion.

Baseline evidence is local in `/tmp/winmux-sidebar-before.trace`,
`/tmp/winmux-sidebar-before-toggle.log`, and `/tmp/winmux-sidebar-baseline-test.log`.
Updated evidence is in `/tmp/winmux-sidebar-tests.log`, `/tmp/winmux-sidebar-build.log`,
`/tmp/winmux-sidebar-after-complete.trace`, `/tmp/winmux-sidebar-after-complete-toggle.log`,
and `/tmp/winmux-sidebar-complete-comparison.json`.
