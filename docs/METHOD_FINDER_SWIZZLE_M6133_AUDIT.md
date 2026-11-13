# Method Finder Swizzle Audit — M6.13.3 (isolation branch)

Baseline: `main@7216b5524587f362622d833e3caf1244bbd3fda9` (CI Run 43347560094 success).
Working branch: `audit/method-finder-swizzle-m6133`.
Scope: Method Finder category (search / results / detail / class search / candidate actions). Not a project-wide count.

## Evidence-based installation chain

- `ZNUnifiedUI.mm:2375`: `ZNDeferredLauncher::zn_finishActivation` invokes `ZNInstallIL2CPPNamedOffsetWorkspaceDeferred`.
- `ZNIL2CPPNamedOffsetWorkspace.mm:166-172`: installs `ZNBinaryPatchWorkspace validateAll:` exchange then calls `ZNInstallIL2CPPMethodFinderUIDeferred` and `ZNInstallIL2CPPMethodFinderMenuBindingDeferred`.
- `ZNUnifiedUI.mm:4796`: Method Finder binding installer calls 52 deferred installers (some backend, some UI, some feature/runtime; **not** 52 swaps). Calls are inside `dispatch_once` and depend on available classes/selectors.
- `ZNUnifiedUI.mm:12930-12938`: M5.4 exchanges search, results, detail selector entries with consolidated renderer functions.
- `ZNUnifiedUI.mm:15140-15145`: M6.13.1 swaps `zn60v3_renderResultsAtWidth:` with `zn52x_renderResultsAtWidth:` **after** M5.4; result renderer does not call the prior implementation.
- `ZNUnifiedUI.mm:14088-14095`: final results handler explicitly routes class identities to `znm64_renderClassResultsAtWidth:`.
- `ZNUnifiedUI.mm:12400-12485`: unified class search, cancellation, class selection, back navigation use typed associated-object state and `ZNIL2CPPHybridFinder`.
- `ZNUnifiedUI.mm:12400` vicinity: method search still delegates to `znm442_submitSearch:`; do not remove M4.4.2 semantics.

## Precise tested change candidate

`ZNInstallMethodFinderM43PolishDeferred` is invoked between M4.3 and M4.4.1 installers, and registers exactly two old UI exchanges:
- `zn60v3_renderSearchAtWidth:` ↔ `znm43p_renderSearchAtWidth:`
- `zn60v3_renderResultsAtWidth:` ↔ `znm43p_renderResultsAtWidth:`

At `ZNUnifiedUI.mm:8893-8910`, its implementations only post-process an earlier renderer: keyboard configuration for the legacy limit field and removal of Assembly labels. M5.4 owns the current search field with `UIKeyboardTypeNumberPad` (`:12557+`); M6.13.1 owns result cards (`:14088+`). The two Polish selector names have no additional direct call sites apart from their own prior-IMP forwarding and installer (static scan of `ZNUnifiedUI.mm`).

**Change:** bypass only `ZNInstallMethodFinderM43PolishDeferred()` in Method Finder binding installation. Keep method bodies intact for now and do not modify any downstream behavior/backend.
- Before: 52 deferred installer call sites within Method Finder binding function.
- After: 51.
- Expected skipped exchanges: 2, provided runtime target/replacement Methods existed before.
- Static global exchange call-site count is **unchanged**: code is still present but no longer reachable through this invocation.
- Not proof of `IMP` values or actual runtime counts: these require instrumentation or a device trace.

## Dependencies intentionally retained

- `ZNInstallM442SearchRestoreDeferred` and `znm442_submitSearch:` (method query semantics)
- `ZNInstallMethodFinderUnifiedUIDeferred` (search/results/detail canonical route)
- `ZNInstallM462CandidateBindingUIDeferred` (candidate action identity)
- `ZNInstallM47ReceiverCaptureUIDeferred` (receiver binding)
- `ZNInstallM52ChainExecuteButtonDeferred` (final result renderer)
- `ZNInstallM630HardCutUIDeferred` (separate Feature UI, not Method Finder)

## Acceptance gates

1. Source diff is a single installer-call omission; original branch/commit preserved.
2. Compile arm64 + code-sign + inspect CI artifact, not merely a green GitHub commit.
3. Device: method search; class search `cheat` with visible results; class drilldown; back to class list; method details; test/invoke/receiver; Builder add; cancel/retry.
4. If any regression occurs, revert the isolated omission, do not add a compensating renderer swizzle.

## Status

- Static proof and isolated source change: completed.
- Build / binary / device evidence: pending until verified on the candidate branch.
- No source-side claim that the obsolete method implementations have been physically deleted.

## Stage 2 — M4.4.1 targeted UI removal

Commit: `41fd559d4ceb5e1c0a0c7e9f6d59200770716226`.

Static evidence in `ZNUnifiedUI.mm` (baseline location `~9420-9700`):
- `znm441_renderSearchAtWidth:` forwards to prior renderer, then traverses controls by visible title `搜索`, removes existing targets and rebinds to `znm441_submitSearch:`.
- `znm441_renderResultsAtWidth:` forwards to prior renderer, walks disabled text fields and attempts to enable Unity struct inputs. This is a historical post-render decorator.
- M5.4 `znm54_renderSearchAtWidth:` draws/search-binds current controls directly, and the M6.13.1 `zn52x_renderResultsAtWidth:` builds native result cards directly without forwarding to prior renderer.
- `ZNInstallM442SearchRestoreDeferred` still wraps legacy Search (and calls its prior alias) but final Search route is M5.4; method search invokes `znm442_submitSearch:` explicitly and still depends on `znm43_startSearch:` being the established V3 alias. Thus do **not** remove M4.3 start-search swap or M4.4.2 semantics.
- `ZNInstallM441HotfixDeferred` originally performed four exchanges: Search UI, Results UI, `zn44_endEditing:`, and `ZNIL2CPPInvokeEngine executeAssembly:...`. Stage 2 deletes **only the first two exchange calls**, preserving the latter two unchanged.

Expected effect: 2 fewer installer-stage UI exchanges, atop stage 1's two omissions. This is not a runtime IMP trace. The obsolete method bodies remain physically present and should not be deleted before device regression.

Device acceptance checklist: (1) method search with default Assembly priority; (2) explicit Assembly filter; (3) RVA/VA normalization; (4) class search `cheat` and drilldown/back; (5) test/Builder and Vector3 etc. argument input; (6) Offset input persistence; (7) keyboard and touch interaction. CI success alone cannot establish these.

Status: source change committed; CI and device results reported separately, not implied.
