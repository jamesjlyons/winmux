# WinMux simplification implementation

WinMux will use Spaces containing Views. A View contains a page, an app window,
or a split or stack arrangement. Pinning saves the arrangement and its launch
descriptors. Each managed browser page will have one native window containing a
compact toolbar and page content. Only explicit stacks show a tab strip.

Implementation starts from `b1ce5fd1`, including the existing chrome, sidebar,
address history, and close-focus changes. Preserve supported saved sessions,
configured arrival behavior, profile boundaries, and native window identities.

## Stages and completion criteria

1. **Baseline and test entry point.** Include the native core and bridge suites
   in `make check`. Record automated interaction and projection baselines,
   retain migration fixtures, and distinguish live runtime checks from model
   tests. Establish build, test, run, and package entry points.
2. **Read only sidebar projection.** Reconcile membership, native layout imports,
   pin state, and project materialization before presentation. Sidebar reads
   must not create workspaces, alter selection, or update layouts. Verify hidden
   sidebar operation, delayed reads, closed/moved owners, temporary native
   absence, and repeated projection without model mutation.
3. **Saved Views and pins.** Use a shared View representation with stable member
   IDs, layout, optional live bindings, and saved launch descriptors. Convert
   legacy pins through a migration boundary, retaining unresolved information
   and a recoverable backup. Preserve closed slots, order, proportions, profile
   identity, and selection. Ordinary restart restoration must not launch pages.
4. **Authoritative shared layout.** WorkspaceCore owns organization, ordering,
   layout, and intended selection. Native and browser adapters own observations
   and effect execution. Migrate move, combine, separate, resize, and selection
   operations incrementally. Resolve old names at compatibility boundaries;
   retire duplicated membership and mutation paths. Preserve focus generations,
   process validation, and transactional profile moves.
5. **Unified behavior and settings.** Use Space and View consistently. New
   arrivals follow their source; explicit combinations form arrangements.
   Translate legacy tiling into arrival/layout policies and retain CLI/config
   aliases. Offer Auto-hide, Compact, and Expanded sidebar visibility with
   explicit migration precedence. Preserve intentional empty Views and saved
   arrangements.
6. **Browser window integration.** Prototype controls, address entry, and frame
   inside the Chromium host. Verify keyboard and accessibility behavior,
   autocomplete, extensions/downloads, mixed stacks, dragging, resizing,
   fullscreen, and multiple displays. Integrate the validated implementation
   and remove helper-owned toolbar/backing windows and their synchronization.
   Preserve a compact toolbar without a singleton tab strip.
7. **Retirement and final verification.** Remove superseded runtime models,
   adapters, and temporary switches. Consolidate current user/developer guidance
   and distinguish historical Alpha/Trial records. Verify restoration, profile
   transactions, mixed layouts, accessibility, and interaction performance
   against the baseline before declaring the implementation complete.

## Delivery

Test, commit, and push the first slice of stages 1–2 before continuing through
the remaining stages. Each migration must leave a working app and retire its
superseded runtime path when compatibility and behavior checks pass. Keep
qualification reports specific to the tested build and workload; synthetic
model timings do not establish native input readiness or compositor latency.

## Verification record

### First slice of stages 1–2

The model refresh and browser inventory paths now reconcile shared membership
before layout. Sidebar projection reads materialized projects, existing native
containers, and reconciled pin bindings. It no longer creates pin destinations
or imports native arrangements. Late native discovery imports new subtrees
without changing existing mixed arrangements or the order of browser pages.

`make check` now includes app Debug and Release tests, native WorkspaceCore and
BridgeCore tests in both configurations, Python checks, and dependency-lock
verification. `make dev-build`, `make dev-run`, and `make dev-test` remain the
local build, run, and test entry points. Signed browser packaging and live
qualification continue through the tools under `browser/tools`.

Fixed v4 mixed-layout and v5 pinned-arrangement fixtures preserve member
identities, closed slots, saved selection, profile identity, and split weights
for the upcoming migration. Regression tests cover repeated read-only sidebar
projection, disabled sidebars, stale title reads after moves/closures, late
native discovery, temporary fullscreen/minimize states, and inventory arrivals.

Verification on this Mac on 2026-10-06:

- App Debug and Release: 1,055 tests passed in each configuration, with three focus tests excluded because the
  console is locked. Those same tests failed at the unchanged baseline with
  seven assertions. The exclusions apply only to this diagnostic invocation;
  `make check` continues to run the full suite.
- Native Debug and Release: 145 WorkspaceCore tests and 21 BridgeCore tests
  passed. Four activation tests require reopening protected files and failed
  at baseline while the console was locked. These were excluded from the
  diagnostic runs, but remain enabled in `make check`.
- Python: 84 tests passed through `make check-python`.
- Dependency resolution left `Package.resolved` unchanged; `git diff --check`
  passed.
- Synthetic Release model reconciliation plus sidebar projection: median
  0.480 ms / p95 0.495 ms for 50 Views; median 1.529 ms / p95 1.608 ms for
  200 Views. Ten samples follow one warmup. These timings exclude native input
  dispatch and compositor presentation.

The locked console prevents the live interaction baseline and full focus/file
protection qualification. Rerun unfiltered `make check` and the signed isolated
`browser/tools/test_browser_switch_speed.py` fixture after unlocking. Do not
relax file protection or replace desktop checks with synthetic timing claims.

Stages 3–7 remain pending. The first slice is implemented; desktop qualification
for stages 1–2 remains open.
