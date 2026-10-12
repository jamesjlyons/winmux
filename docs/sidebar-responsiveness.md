# Sidebar opening and closing — September 15, 2026

## October 11: swiping crowded Spaces

Continuous horizontal travel is now observed only by the pager offset modifier.
The sidebar still updates for discrete changes such as swipe direction, selection,
and settlement, but each input delta no longer recomputes page grouping, selection
inputs, or the row tree. Unused per-delta progress calculations were removed.

The vertical page list and arrangement children use lazy stacks. They mount nearby
rows as a Space enters the pager instead of building all windows and tabs at once.
Arrangement expansion state belongs to the sidebar so recycling offscreen rows
does not reset collapsed arrangements. Selection gets its complete displayed order
from the page data, preserving offscreen Shift/Command selections while excluding
closed, filtered, and collapsed rows as appropriate.

All **311 sidebar, shortcut, selection, and bootstrap tests passed**. The offscreen
AppKit/SwiftUI fixture mounted **14 of 200** separate rows and **13 of 200** children
in a single arrangement. Twenty horizontal offset updates caused **zero content
rebuilds** in the hosted offset fixture; the page moved the expected 100 points and
returned to its original position. Checks also cover scrolling to the last row,
retaining a 200-item selection across viewport changes, pruning removed rows, and
existing layout, drag, search, cancellation, and momentum behavior. These measure
rendered work and correctness, not live display frame pacing.

## October 11: hover scheduling and keyboard controls

Deliberate hover entry now expands synchronously in the delivered pointer event.
The zero-delay expansion dispatch and the sidebar's separate 60 Hz throttle have
been removed. Pointer movement is already coalesced by `PointerActivityCoalescer`
at the display refresh rate. Geometry changes still schedule one deferred hover
recheck, so stationary-pointer updates do not recurse into expansion.

Hover-triggered search activation waits for the opening animation interval before
activating the app and installing keyboard monitors. The task is cancelled when
the width changes or the view disappears, preventing stale activation after a
quick exit. Explicit keyboard search still arms and buffers typing immediately.
Opening an existing visible panel no longer refreshes all display panels first.

Settings → Shortcuts → Sidebar exposes these commands:

| Action | Command | Starter shortcut |
| --- | --- | --- |
| Cycle Auto-hide → Compact → Expanded → Auto-hide | `sidebar cycle` | Hyper–S (Control–Option–Shift–Command–S) |
| Show / hide | `sidebar toggle` | Option–Shift–S |
| Expand / collapse | `sidebar toggle-expanded` | Option–Shift–E |
| Show the compact rail (retain Expanded if selected) | `sidebar show` | Assign in Settings |
| Auto-hide, with edge hover available | `sidebar hide` | Assign in Settings |
| Keep expanded | `sidebar expand` | Assign in Settings |
| Keep the compact rail | `sidebar collapse` | Assign in Settings |
| Open sidebar search | `open-sidebar` | Control–F |

Visibility commands save the same app-wide setting as the sidebar menu and apply
to all displays. `toggle` switches visible modes to Auto-hide and Auto-hide to
Compact. `toggle-expanded` switches Expanded to Compact and other modes to
Expanded. Existing configurations retain their bindings; assign the new shortcuts
in Settings or add them to `[mode.main.binding]`. Requests are serialized across
config reloads. An explicit hide/collapse suppresses hover reopening until the
pointer leaves the activation region. Existing menus, dragging, and editor locks
remain in effect for ordinary hover transitions.

For a single shortcut through all three visibility modes, assign **Cycle Sidebar
Visibility** in Settings, or add `alt-ctrl-cmd-shift-s = 'sidebar cycle'` to
`[mode.main.binding]`. This is Hyper–S; a remapped Hyper key works as long as it
emits Control, Option, Shift, and Command together. The cycle starts from the saved
visibility mode, including when the pointer has temporarily expanded the sidebar.

Regression tests cover synchronous entry with a single final-width publication,
duplicate opens, close reversal, pointer suppression, every command/state pair,
rapid toggles, failed saves, and configuration round trips. These are controller
and configuration checks, not proof of frame pacing under every system load.
The release build and all 90 targeted tests passed. The duplicate-open fixture
reported zero publications and zero expansion notifications for 100 requests.

The follow-up input audit removed another source of repeated work. Search uses no
pointer-exit monitors because it intentionally survives pointer exit; rename
sessions install that monitor set once. Handing buffered command search to SwiftUI
updates callbacks without reactivating the app or recreating its keyboard event
tap. Command-open mouse unlocking now uses the existing coalesced pointer stream,
with the same 80 ms grace and one-point movement threshold. It no longer allocates
a separate monitor pair or queues delayed installers that can outlive a quick
open/close/open sequence.
All 297 sidebar and shortcut tests passed after this follow-up, including monitor
reuse, buffered-search handoff, unlock grace/distance, and rapid rearming checks.
With the cycle action added, all 299 tests passed, including Hyper shortcut
recording and six overlapping cycle requests completing two full visibility loops.

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

The initial optimization used bounded ease-out animations: 140 ms to open and 100 ms to close. The exit
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

## Faster opening and closing

Opening now uses a 50 ms ease-out animation, down from 140 ms. Closing uses a 40 ms
animation and matching finalization interval, down from 100 ms. The sidebar width,
workspace sections, and status content share the transition animation constants.
The hover-exit grace remains 40 ms, giving 80 ms of configured close intervals before
event-delivery and rendering overhead.

The measurements above describe the initial 140 ms opening / 100 ms closing build.
The final timing build was signed, installed, and WinMux Dev restarted. Tests were
skipped for these timing adjustments at the user's request. Screen-presentation
timing was not measured. The build log is `/tmp/winmux-closing-40ms-build.log`.
