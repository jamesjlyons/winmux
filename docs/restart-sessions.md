# Restart sessions and signed development builds

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
The live tree is captured on the main actor; a separate serial writer compares and saves the
snapshot. Quit captures the final state before yielding and waits for its write before window
cleanup. Revisions prevent a delayed checkpoint from replacing a newer quit snapshot. Unchanged
content skips disk access, and a failed write remains eligible for retry.

The existing version-1 session is imported only when saved during this boot.
Corrupt files fall back to the backup; unsupported versions are preserved. Saving
is suspended while disabled, read-only, locked, awaiting Accessibility permission,
or still restoring. `winmux doctor` reports the file path and save/restore result.

- Regular: `~/Library/Application Support/WinMux/window-state.json`
- Development: `~/Library/Application Support/WinMux-Debug/window-state.json`
- An explicit `--config-path` gets a separate session under `sessions/<path-hash>/`.

The builds do not import one another's layouts. Configuration preferences remain
in the selected TOML; use an explicit config path for an isolated test profile.

## Development workflow

An **Apple Development** certificate and its private key must be available in the
login keychain. The scripts deliberately fail if signing is unavailable.

```sh
make dev-build                      # optimized Dev build and signing; leaves the running app alone
make dev-test                       # test the same optimized Dev configuration
# Quit WinMux Dev so it saves its session.
./script/dev-app.sh install          # installs /Applications/WinMux Dev.app
make dev-run                        # runs that installed app
```

`make run` builds, installs, and runs the same signed bundle; quit the running Dev
app first. `DEV_SIGNING_IDENTITY` can select a specific certificate (default:
`Apple Development`). Keep the same certificate/team, bundle identifier
`com.zimengxiong.winmux.debug`, and installation path across updates. Installation
verifies that each replacement satisfies the previous app's designated code
requirement before replacing it, and refuses to replace a running Dev bundle.
The regular `/Applications/WinMux.app` is not replaced.

Daily Dev builds use SwiftPM's `release` optimization with `-DDEBUG`. That explicit
flag preserves the Dev app identity, socket, session directory, and disabled automatic
updates. Use `make dev-build DEV_BUILD_CONFIGURATION=debug` for an unoptimized build
that is easier to step through in a debugger; the same option applies to `dev-test`.
`make build` remains the regular Debug build. Direct `script/dev-app.sh build`
packaging retains its historical Debug default; pass `DEV_BUILD_CONFIGURATION=release`
only after compiling with `swift build -c release -Xswiftc -DDEBUG`.
See [overall app speed](app-speed.md) for measurements and limitations.

Moving from an old ad-hoc build may require granting Accessibility and Screen
Recording once to the signed **WinMux Dev** app. Subsequent updates using this
workflow preserve its signing identity. WinMux never resets system privacy
permissions. macOS remains responsible for granting or revoking access.

For a separate test profile:

```sh
WINMUX_CONFIG_PATH="$PWD/.local/winmux-dev.toml" make dev-run
```

## Validation

Validated locally on September 13, 2026:

- 579 Swift tests passed, including 15 restart-session cases.
- A live Command-Q/reopen cycle restored all 11 saved windows with matching
  workspace assignments, stack order, selected tabs, layout proportions, and focus.
- A second signed binary had a different code hash and satisfied the installed
  app's designated requirement. Accessibility and Screen Recording remained granted.
- Launching while macOS was locked preserved the 11-window session and waited for
  unlock. SIGTERM exited in 0.06 seconds while locked, retaining that snapshot.
- The launcher refused a duplicate instance. The regular installed app was not replaced.

Floating-frame adaptation, missing/delayed windows, corrupt files, legacy import, and project
ordering are covered by automated tests; a physical display disconnect was not part
of the live check.
