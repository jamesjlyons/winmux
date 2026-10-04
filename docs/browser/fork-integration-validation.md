# Fork interface integration validation

Validated on October 2, 2026 (UTC), on `codex/chromium-browser`.
Implementation commits: `c60bc94e`, `c3f4eeb4`, and `47883311`.

## Automated checks

- `make check`: 831 application tests passed in Debug and again in the optimized
  configuration; five appcast tests passed and dependency resolution was clean.
- Native SwiftPM checks: 60 WorkspaceCore tests and ten BridgeCore tests passed.
- Browser tooling checks: 39 Python tests passed, including fresh-layout reset and
  archive safeguards.
- The signed `alpha-fork-spaces-3` package passed its packaging verification.
  Its helper binary and all 594 recorded native-source hashes matched the tested
  checkout, including the concurrent thin browser-header changes.

The integration tests cover mixed-row metadata/search, window and stack move
menus, nested subtree identity/order/selection/proportions, unavailable owners,
source focus, drag cancellation, expansion locking, new-Group rollback, native
float/tile transitions, hosted Settings, and the fresh configuration.
Existing browser control, drag, snapping, resizing, and restoration tests remain
in the application checks. Browser layout/control/session versions remain 3/4/4.

## Isolated live fixture

The final signed package resumed an isolated profile and layout containing two
browser pages and two explicitly scoped native fixture windows. Both browser
page identities and the moved mixed subtree survived restart.

Live checks exercised mixed icons, compact and expanded sidebars, search,
Organize and Space selection, page and whole-stack Move menus, cross-Space and
new-Group moves, and the original simplified Settings window. Stack identity,
member order, active selection and proportions were compared before and after
movement. Split, stack and resize commands kept the same Chromium hosts within
one browser run. Native floating and tiling commands succeeded in the mixed
workspace. Light and dark sidebar appearances were inspected using fixture-only
settings; system appearance settings were unchanged.

Both fixture browser runs quit normally with exit code zero, and their temporary
native-management services were removed. Physical Space swipes, pointer-driven
edge scrolling, and tab clicks beneath overlapping floating windows were not
manually exercised; their model/interaction paths are covered by automated tests.
Helper-owned page controls were covered by application tests; live screenshots
inspected the sidebar and Chromium page contents. This is functional validation,
not a mixed-layout performance qualification.

## Daily rollout and recovery

The previous daily workspace was stopped, and its browser quit normally before
reset. The complete `daily/native-state` directory was archived under
`layout-archives/20261002T050753Z-dd8e064e/native-state` in the existing
`WinMux Browser Workspace Alpha` application-support directory. `archive.json`
records the prior `alpha-thin-chrome-1` package; that package and the preceding
window-drag package remain available.

All 528 regular Chromium profile files had identical hashes immediately before
and after reset. The profile was reused directly, with no standalone import.
Fresh startup created only Default Space and the automatic Group 1. All six
previously saved browser-page identities were present among eight restored
pages, and all current surfaces were available.

A subsequent clean daily stop/quit/start retained exactly those eight browser
identities. The saved organization still contained one Space and only Group 1;
previous Space and Group assignments were absent. Additional daily split, stack
and resize commands passed with all page identities available. The temporary
resize weights were cleared while stopped, and the final restart retained all
nine current pages in Group 1. The daily workspace was left running from
`alpha-fork-spaces-3` with the compact system-colored sidebar.

Local evidence is retained in `.local/browser/fork-ui-1` and `fork-ui-2` in the
browser checkout, plus the `fork-daily-*` and `fork-layout-archive.json` reports in
the primary checkout. The profile report stores hashes and surface identities,
without page titles or URLs. For recovery steps, see [the interface guide](fork-interface.md).
