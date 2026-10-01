# Shared surface commands

The alpha helper's existing command socket accepts typed window/tab references:

```text
surface list
surface focus <surface-id>
surface close <surface-id>
surface move <surface-id> <workspace> [--focus-follows-surface]
```

`selected` can replace the surface ID. Native IDs have the form
`native:<uuid>`; browser IDs are `browser:<profile-uuid>:<tab-uuid>`.
`surface list` returns a JSON array containing `id`, `workspace`, `available`,
`selected`, and, for live native windows, `nativeWindowID`. It includes saved
references whose owner is temporarily unavailable. It does not expose page
content or titles. An unavailable or malformed explicit ID fails without
falling back to another window.

`focus` and `close` report successful dispatch, not completed input readiness or
closure. Native save prompts remain owned by the application. Browser placement
is removed only after an authoritative inventory removal; an issued close does
not write a tombstone. Moving a browser reference preserves its profile and tab
identity. Without the follow flag, a moved selection gives focus to a remaining
item in the source workspace. Browser workspace moves require protocol 3 and
explicit shared native management.

Existing `close`, `move-node-to-workspace`, `move-node-to-monitor` and
`move-node-to-project` dispatch to the selected browser tab when no explicit
native target was supplied. Existing numeric `--window-id` and native environment
targets retain their meaning. `--quit-if-last-window` is rejected for browser
tabs. Native-only resize, move, split, stack, swap, fullscreen, minimize and bulk
close commands reject an implicit browser selection, including a disconnected
one, rather than modifying the last native window. Mixed grouping and split
geometry remain available through the shared sidebar.

The alpha command socket is isolated from the standalone WinMux socket and
configuration. A CLI built from this branch can target it explicitly with
`winmux --socket /tmp/winmux-browser-<uid>-<state-hash>.sock surface list`.
The socket name derives from the activated state directory; the CLI does not
automatically select or enroll an alpha helper. Omitting `--socket` retains the
standalone endpoint. The installed standalone CLI remains unchanged. The
commands do not enroll the helper or replace a running native manager.
