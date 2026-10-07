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

The first slice was committed and pushed as `d3feb53a`. Desktop qualification
for stages 1–2 remains open.

### Stage 3 progress

`SavedView` now provides a common member model with optional runtime bindings,
launch descriptors, saved selection, and layout. Pin layout capture uses this
core model. `ViewLayoutNode` holds the shared arrangement; `PinnedLayoutNode`
remains a compatibility spelling while callers migrate.

The legacy conversion boundary now handles groups whose members are closed,
preserving member order, proportions, and selection without launching pages.
Groups containing native bindings wait until restart discovery finishes before
moving to their new workspace. A version migration preserves the original
session bytes in a version-specific backup, in addition to the rotating backup.
Checkpoints refuse to replace a file from an unsupported newer build.

The foundation was committed and pushed as `f3f466f8`. App Debug and Release
passed 1,060 tests each; native Release passed 150 WorkspaceCore tests and
21 BridgeCore tests, using the same locked-console exclusions described above.

The v6 checkpoint format now stores ordinary and pinned Views in `savedViews`.
Members, launch descriptors, and saved arrangements have one owner; legacy pin
records remain only for unresolved migration or as computed compatibility
adapters. Ordinary Views keep stable identities and intentional empty Views
survive restart. Pinning, unpinning, and moving members preserve their IDs;
unpinned members discard closed slots and launch descriptors. Profile moves
transfer the saved member identity to the replacement page after the existing
transaction completes.

The migration tests cover v5 backup byte preservation, v6 round trips without
duplicated pin records, closed slots, unresolved native discovery, and duplicate
or conflicting owner rejection. The remaining adapters will be retired as
commands move to shared ownership in stages 4 and 7. Native desktop
qualification remains open; stages 4–7 remain pending.

The canonical storage change passed 1,065 app tests in Debug and Release, and
151 WorkspaceCore plus 21 BridgeCore tests in both configurations. A final
profile-binding identity fix then passed 34 targeted regressions and the full
1,065-test Debug suite; optimized verification passed with the command
consolidation below. All runs use the locked-console exclusions above.
The Release model-plus-sidebar benchmark measured 0.715 ms median for 50 Views
and 2.421 ms for 200 Views; this includes saved-member reconciliation.

### Stage 4 command consolidation

WorkspaceCore now prepares complete organization changes and their membership
effects. Preparation preserves the set of live identities, keeps unresolved
native reservations in place, validates tree limits, and rejects changes to
unrelated workspaces or their metadata. One synchronous app adapter rechecks
every affected owner before applying native bindings, browser placements, and
the final tree. Profile copies still commit through the existing transactional
profile boundary.

Sidebar reordering, group transfers, typed surface moves, and native workspace
moves use that path. Layout and resize commands target the shared arrangement
even with an explicit native window ID or environment target. Balance, flatten,
join, stack, separation from a stack, and swap commands also support mixed
arrangements. Spatial navigation and its tests now live in WorkspaceCore.
Cross-View moves preserve the source selection unless focus-following was
requested.

This slice passed 1,067 app tests in Debug and Release and 158 WorkspaceCore plus 21
BridgeCore tests in both configurations, with the locked-console exclusions
above. Stage 4 still includes native drag paths, remaining ownership adapters, and
retirement of native layout authority after adoption. Stages 5–7 remain open.

Directional movement now runs in WorkspaceCore, preserving stacks as units,
entering adjacent splits, and leaving nested containers before reaching a View
boundary. Monitor-boundary moves transfer a complete stack and preserve its
selection. The `split` compatibility spelling changes the current arrangement's
axis; shared Views do not create invisible singleton containers. Existing
normalization guards still apply.

A deterministic 500-move test covers nested mixed layouts and serialized state
validity. It exposed stale container selection when a leaf left a nonempty
container; movement now prunes that metadata explicitly. App Debug and Release
passed 1,070 tests; the final monitor-stack change passed all 25 surface-command
tests. Native Debug passed 166 WorkspaceCore and 21 BridgeCore tests after the
final change; Release passed the same suites before the monitor insertion
adjustment. All runs retain the locked-console exclusions above.

Native frame gestures in Views already using shared layout now use the same
drop and resize path as browser pages. Resizing distinguishes each dragged edge,
preserves interior dividers in nested splits, and respects owner minimum sizes.
The adapter commits all changed edges together and rejects a gesture if its
layout changed before release. Native-only drop preparation is also covered by
the owner-validation tests.

Shake-to-float updates shared membership immediately. An ephemeral return
position restores the original stack identity and proportions only if the
surrounding View is unchanged; later edits and other Views remain authoritative.
Native-only Views keep their existing automatic gesture handling until native
tab chrome and the agent API use shared organization. Those paths, full native
authority adoption, and removal of duplicated placement state remain open.

The gesture slice, including shake restoration, passed 1,076 app tests in Debug
and Release. All 172 WorkspaceCore and 21 BridgeCore tests passed in both
configurations. The final native-authority guard has separate targeted coverage.
Unlocked interaction checks remain open, with the same baseline console
exclusions above.

### Stage 5 sidebar visibility

Sidebar visibility is now one enum and one setting in Appearance and the context
menu: Auto-hide, Compact, or Expanded. Runtime configuration and presentation
snapshots no longer store two overlapping flags. Legacy config keys remain
accepted at the parser boundary. An explicit `visibility` takes precedence;
otherwise legacy auto-hide wins over always-expanded, independent of key order.
Settings edits preserve legacy lines, inline comments, and dotted TOML keys.

All 160 targeted configuration, sidebar, monitor-layout, and native-management
tests passed, followed by the full 1,069-test Debug suite with the existing
locked-console exclusions. Optimized verification passed with the directional
movement slice above. Unlocked desktop qualification, arrival policy migration,
and unified View terminology remain open.
