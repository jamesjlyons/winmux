# Shared surface commands

The alpha helper's existing command socket accepts typed window/tab references:

```text
surface list
surface focus <surface-id>
surface close <surface-id>
surface move <surface-id> <workspace> [--focus-follows-surface]
surface group <surface-id> (<target-id>|next|prev) (stack|horizontal|vertical)
surface layout <surface-id> (stack|horizontal|vertical)
surface ungroup <surface-id>
surface reorder <surface-id> (earlier|later)
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

`group` combines two items in the same workspace. `next` and `prev` mean the
immediately adjacent leaf in shared sidebar order; they do not wrap or skip
unavailable owners. `layout` changes the nearest containing group. When the item
is at the root, it wraps the workspace's root items in one explicit container,
preserving nested groups and order. `ungroup` removes only the nearest containing
group, and `reorder` moves the leaf one sibling position within its container.
Container UUIDs and selection survive layout changes. These edits require
available owners and protocol-3 browser layout support; rejected edits leave the
saved tree unchanged. They do not close or recreate tabs.

The commands are available in config bindings. For example, in the alpha's
isolated config:

```toml
[mode.main.binding]
alt-space = 'layout horizontal vertical'
alt-shift-g = 'surface group selected next stack'
alt-shift-u = 'surface ungroup selected'
alt-ctrl-h = 'surface reorder selected earlier'
alt-ctrl-l = 'surface reorder selected later'
```

The existing `layout` command routes implicit selection through the shared tree
in shared mode for either owner. Horizontal/vertical and tile variants choose a
split; tab-group variants choose a stack. `tiles` retains a vertical split or
otherwise chooses horizontal. Floating/tiling conversion remains unsupported for
shared selection. Existing explicit native `--window-id` or environment targets
keep their native behavior. Command/binding execution is distinct from physical
keyboard-delivery validation.

Existing `close`, `move-node-to-workspace`, `move-node-to-monitor` and
`move-node-to-project` dispatch to the selected browser tab when no explicit
native target was supplied. Existing numeric `--window-id` and native environment
targets retain their meaning. `--quit-if-last-window` is rejected for browser
tabs. Native-only resize, move, split, stack, swap, fullscreen, minimize and bulk
close commands reject an implicit browser selection, including a disconnected
one, rather than modifying the last native window. Mixed grouping and split
geometry are available through the shared sidebar and the commands above.

The alpha command socket is isolated from the standalone WinMux socket and
configuration. A CLI built from this branch can target it explicitly with
`winmux --socket /tmp/winmux-browser-<uid>-<state-hash>.sock surface list`.
The socket name derives from the activated state directory; the CLI does not
automatically select or enroll an alpha helper. Omitting `--socket` retains the
standalone endpoint. The installed standalone CLI remains unchanged. The
commands do not enroll the helper or replace a running native manager.
