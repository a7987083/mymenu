# Method Finder V2 — Verified Source Audit and Migration Contract

Audit target: `a7987083/mymenu`, baseline `45c473860edb3b4b153e52fbc608131134958e71` (user-reported tested M6.14); historic stable `7216b5524587f362622d833e3caf1244bbd3fda9`.
Branch: `refactor/method-finder-v2`, created from the tested baseline. This file is an **architecture/audit artifact**, not evidence of a V2 implementation.

## Evidence hierarchy and current status

- Direct source evidence: `iosruntimepatchmenu/Makefile`, `iosruntimepatchmenu/src/ZNUnifiedUI.mm`, `ZNIL2CPPMethodFinderSearchV3.mm`, `ZNIL2CPPHybridFinder.mm`, `ZNIL2CPPInvokeEngine.mm`, `ZNRuntimeActionRuntime.mm`.
- The M6.14 baseline had successful GitHub CI for the isolated UI-swap removals; the user reported that its dylib worked on device. The exact device test matrix/logs were **not** supplied.
- V2 runtime IMP maps, binary behavior, device compatibility, and regression are **not verified**. No claim that creating this branch removes any Swizzle.

## 1. Menu/installation entry

1. `ZNUnifiedUI.mm:2375` deferred launcher invokes `ZNInstallIL2CPPNamedOffsetWorkspaceDeferred`.
2. `ZNIL2CPPNamedOffsetWorkspace.mm:161-172` calls Method Finder UI and menu-binding installers after its workspace `validateAll:` exchange.
3. `ZNUnifiedUI.mm:4766-4784`: `ZNInstallIL2CPPMethodFinderUIDeferred` installs category/symbol and two page/layout exchanges.
4. `ZNUnifiedUI.mm:4796` installs legacy backend/UI/behavior adaptations, including search, receiver, signature, runtime action, builder and M5.4/M6.13.1 rendering. Previously removed M4.3 Polish installer remains bypassed; M4.4.1's Search/Results exchanges remain bypassed.
5. `ZNUnifiedUI.mm:2378,12930-12938`: M5.4 renderer installer can be called both in nested binding and separately; `dispatch_once` guards duplicate installation.
6. `ZNUnifiedUI.mm:15140-15145`: final Results route swaps to `zn52x_renderResultsAtWidth:`, which does not call its previous implementation.
7. `ZNUnifiedUI.mm:5365-5375`: `zn60v3_renderFinder` clears `contentView` and dispatches by current page (search/results/detail).

## 2. Class search data path (verified)

`ZNUnifiedUI.mm:12376-12416`:
- Mode is stored with `kZNM64ClassModeKey` associated object; cancel token `kZNM64SearchTokenKey`, class results `kZNM64ClassResultsKey`, selected identity `kZNM64SelectedClassKey`.
- Search submit trims input, decides explicit Assembly filter by `kZNM442AssemblyExplicitKey`, executes async `[ZNIL2CPPHybridFinder sharedFinder] zn64_searchClasses:assembly:limit:cancel:error:`, and commits the result to associated state on main queue only if token still matches.
- `ZNIL2CPPMethodFinderSearchV3.mm:395-467`: class-name matching uses rank (exact/prefix/suffix/contains), cancellation and a wall-time budget, bounded candidate retention and `truncated` metadata. Result identity includes `assembly`, `namespace`, `class`.
- `ZNUnifiedUI.mm:12451-12482`: selected class uses `zn64_methodsForClass:limit:cancel:error:`, then stores canonical method candidates in the existing results model.
- `ZNIL2CPPMethodFinderSearchV3.mm:469-512`: class method enumeration returns normal candidate dictionaries.
- `ZNUnifiedUI.mm:12482+`: class list UI, item actions, truncation notice and content-height update are still UIKit code in the unified translation unit.
- `ZNUnifiedUI.mm:14088-14095`: final results renderer checks class mode + no selected class, then delegates class cards to `znm64_renderClassResultsAtWidth:`.

## 3. Method search data path (verified)

- `ZNUnifiedUI.mm:12534-12550`: search field/Return button target `znm54_submitSearch:`; mode switch is explicit.
- `ZNUnifiedUI.mm:12376-12421`: in method mode, `znm54_submitSearch:` dispatches through `znm442_submitSearch:`.
- `ZNUnifiedUI.mm:9870-9905`: M4.4.2 normalizes RVA/VA input, records explicit Assembly selection and invokes `znm43_startSearch:`; this alias's meaning depends on earlier M4.3 exchange and V3 search route (see `ZNUnifiedUI.mm:9719-9725`).
- `ZNUnifiedUI.mm:10200-10205`: M4.5 exchanges `znm442_submitSearch:` with `znm45_submitSearch:` to add address/owning-method handling.
- `ZNIL2CPPMethodFinderSearchV3.mm:515+`: `zn60_searchCandidates:limit:error:` implements the real bounded IL2CPP candidate lookup. This backend is reusable; the selector alias chain is **not** a stable V2 API.

## 4. Results/detail/action path (verified)

- `ZNUnifiedUI.mm:12930-12938`: M5.4 installs Search/Results/Detail UI implementations.
- `ZNUnifiedUI.mm:14088+`: M6.13.1 owns final results cards and method argument UI; it explicitly bypasses older result implementation. `ZNM613AnalyzeCandidate` analyzes ABI suitability and execution affordances.
- `ZNUnifiedUI.mm:12660-12665`: `znm54_openDetail:` stores selected candidate and navigates to page 2.
- `ZNUnifiedUI.mm:12860+`: M5.4 detail rendering; older M4.3/M4.5 detail adapters were installed before it and may remain as callable aliases.
- `ZNUnifiedUI.mm:12668-12681`: `znm54_createCandidate:` reads argument values and invokes `[ZNRuntimeActionStore sharedStore] addMethodCandidate:title:argumentValues:error:` (existing builder backend).
- `ZNUnifiedUI.mm:13300+`: existing runtime saved-action execution uses `[ZNIL2CPPInvokeEngine sharedEngine] executeAction:error:`; non-UI runtime chain/invoke behaviors are shared with other categories.
- M4.4.1 `zn44_endEditing:` and engine `executeAssembly:...` exchanges were intentionally retained after stage 2. Do not remove these with Method Finder UI.

## 5. Current architecture hazards

1. Single compiled UI file `ZNUnifiedUI.mm` (~19,448 lines) includes many legacy versions, so moving source mechanically would preserve technical debt.
2. Search uses M4.3/M4.4.2/M4.5 selector alias behavior. New V2 must replace **UI dependency on aliases**, not rewrite validated search backend or mutate existing alias behavior while legacy mode is active.
3. UIView tree searches by visible titles and indiscriminate `removeTarget:nil action:NULL` exist in legacy wrappers; new V2 must use explicit targets and stable candidate identities.
4. M6.13.1 result cards depend on many internal helpers and associated objects, so cannot be detached into another translation unit with a single `#import` or blind copy.
5. `ZNRuntimeActionStore` / `ZNIL2CPPInvokeEngine` and several old dispatchers are shared; removal of installer chains risks Feature/Builder/Runtime behavior outside Method Finder.
6. Do not infer actual final IMP addresses from the source list alone: instrument `method_getImplementation` against the target device before claiming direct runtime ownership.

## 6. V2 proposed source boundaries (not yet implemented)

- `src/methodfinder/ZNMethodFinderState.{h,mm}`: owns mode, page, query, explicit Assembly scope, cancel generation, selected class/candidate, method results, filter, status, argument draft and history. Typed interfaces; no new `objc_setAssociatedObject` state for V2.
- `src/methodfinder/ZNMethodFinderSearchService.{h,mm}`: normalizes query and dispatches existing `ZNIL2CPPHybridFinder` APIs; cancellation and immutable result callbacks delivered on main queue. Address normalization must preserve RVA/VA and explicit Assembly semantics.
- `src/methodfinder/ZNMethodFinderController.{h,mm}`: owns UIKit Search/ClassList/Results/Detail views; one direct dispatcher based on typed page enum; explicit control targets, reuse existing theme primitives through a small adapter.
- `src/methodfinder/ZNMethodFinderActions.{h,mm}`: maps canonical candidate identity + typed argument values into existing `ZNRuntimeActionStore` and `ZNIL2CPPInvokeEngine` / diagnostics, without new engine or execution hook.
- `src/methodfinder/ZNMethodFinderBridge.{h,mm}`: one integration boundary with existing menu. Prefer explicit page embedding/calls, no additional renderer `method_exchangeImplementations`.

These are proposed file names/contracts, not existing compiled code.

## 7. Safe transition sequence

A. Introduce a typed state module and deterministic tests with no behavior change; compile it into the target while keeping legacy UI active.
B. Introduce the search service adapter with normalization, ranking/scope and cancellation behavior tests; do not alter legacy search dispatch yet.
C. Introduce a V2 controller in parallel but behind an explicit `legacy` / `v2` choice at the **single menu integration point**; never install both competing result renderers.
D. Connect builder / execution through existing engines and test candidate identity and argument marshalling parity.
E. After device matrix passes, make V2 sole active Method Finder UI and remove obsolete Method Finder UI installation calls. Preserve shared Runtime/Feature/Builder hooks.
F. Remove truly unreachable legacy methods only after target-source search, dependency inspection and compile/device validation; otherwise retain them.

### Regression matrix

- Method search query / `Class::Method` / Assembly priority and explicit filter / RVA and VA input
- Class search e.g. `cheat`; nonzero visible results; truncation notice; class method list; back navigation
- Cancellation / repeated searches / stale async result protection
- Page Search ↔ Results ↔ Detail ↔ ClassList; keyboard entry and touch passthrough
- Argument filters + editable primitive/Unity struct parameters + Receiver/instance selection
- Test method call / return capture / immediate chain / Native Hook status
- Builder creation, stable action identity, saved action execution
- Feature/Runtime controls and Offset input persistence remain unaffected

## Gate definitions

- `audit complete`: source links and call/data graphs reproduced against fixed SHA.
- `implemented`: isolated code commit on V2 branch.
- `compiled`: arm64 build verified with correct artifact hash and steps.
- `runtime tested`: device logs/screens demonstrating V2 actual execution (not CI).
- `regression tested`: above matrix compared to frozen M6.14 baseline.
