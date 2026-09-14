# Restart sessions

WinMux checkpoints the current session after layout changes and flushes it before
quitting. The saved session includes workspace/project order, display assignment,
nested tiles and tab groups, tab selection, floating frames, and focused workspace
and window. Normal Quit, Command-Q, macOS termination, SIGTERM, and SIGINT use the
same shutdown path. Window cleanup has a five-second deadline. Force Quit/SIGKILL
can only recover the most recent checkpoint.

Restoration applies to windows that are still open in the same macOS boot and app
process. It does not relaunch applications or reopen documents. Window IDs are
checked against the owning process, bundle ID, launch date, and boot identity to
avoid assigning a reused ID to an unrelated window. Missing windows are skipped;
discovery retries for up to ten seconds. Editing a workspace cancels any pending
restore for that workspace. A missing display falls back to the main display,
with floating frames clamped to its visible bounds.

Session files are atomically replaced with a last-good `.backup` alongside them.
The existing version-1 session is imported only when saved during this boot.
Corrupt files fall back to the backup; unsupported versions are preserved. Saving
is suspended while disabled, read-only, locked, without Accessibility permission,
or still restoring. `winmux doctor` reports the file path and save/restore result.

- Regular: `~/Library/Application Support/WinMux/window-state.json`
- Development: `~/Library/Application Support/WinMux-Debug/window-state.json`
- An explicit `--config-path` gets a separate session under `sessions/<path-hash>/`.

The builds do not import one another's layouts. Configuration preferences remain
in the selected TOML; use an explicit config path for an isolated test profile.
