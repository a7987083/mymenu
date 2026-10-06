# Method Finder UI Architecture Audit — M5.4

## Scope

This audit covers the Method Finder UI/runtime installation chain in `iosruntimepatchmenu` before M5.4 consolidation.

## Confirmed structural problem

`ZNRuntimeMenuControllerV040` accumulated multiple UI generations through repeated `method_exchangeImplementations` calls. Several later modules render an earlier UI first, then walk the view hierarchy, identify controls by title/position, remove targets, move frames, and append more controls.

This creates runtime behavior that depends on install order rather than one explicit UI contract.

## Main generations

| Layer | Role before M5.4 | M5.4 disposition |
|---|---|---|
| Finder V2 / Search V2 | legacy resolver/search compatibility | BACKEND / compatibility only |
| Finder V3 | candidate state, page state, limit/status, hybrid search helpers | KEEP as state/backend |
| M4.2 | result-card/runtime evolution | renderer superseded |
| M4.3 | Assembly picker, custom limit, search/results/detail replacement | UX semantics merged into Unified UI |
| M4.3 Polish | post-render keyboard/label cleanup | renderer superseded |
| M4.4.1 | post-render target rebinding + address normalization | renderer superseded; search behavior retained through final search route |
| M4.4.2 | restores proven V3 named-search route and explicit Assembly semantics | KEEP search/backend semantics |
| M4.5 | owning-method address resolver + detail decoration | KEEP owning-method backend; renderer decoration superseded |
| M4.6 / M4.6.1 | full signatures, exact invoke/static patch, overload UI polish | KEEP action/backend; renderer polish superseded |
| M4.6.2 | explicit candidate-to-test-button binding | KEEP as behavior decorator after Unified UI |
| M4.7 Receiver Capture | long-press receiver capture | KEEP as behavior decorator after candidate binding |
| M4.7 MultiArg UI | /2-/8 argument storage + post-render rows | KEEP argument-value behavior; rows merged into Unified UI |
| M4.8 / M4.9 / M5.0 | return capture / generic invoke / managed-reference chaining | KEEP backend |
| M5.1 | Builder/runtime controls + Finder chain-button post-render layer | KEEP non-Finder backend and chain behavior decorator |
| M5.2 | Chain V2, execute-chain state, old search-history hook | KEEP chain backend; REMOVE old history hook from install path |
| M5.3 | control binding | KEEP backend/runtime UI outside Finder |

## Repeated selector exchanges confirmed

The following selectors were repeatedly exchanged by multiple generations:

- `zn60v3_renderSearchAtWidth:`
- `zn60v3_startSearch:` / later replacement submit handlers
- `zn60v3_renderResultsAtWidth:`
- `zn60v3_renderDetailAtWidth:`

Examples:

1. M4.3 exchanges V3 search/results/detail renderers.
2. M4.3 Polish wraps the same search/results selectors again.
3. M4.4.1 wraps search again and removes/rebinds UI targets by walking the view tree.
4. M4.4.2 wraps search again to restore a prior V3 search route.
5. M4.5 wraps search/results/detail behavior again.
6. M4.6.x/M4.7/M5.1/M5.2 repeatedly wrap the results renderer to mutate already-rendered controls.

## Fragile patterns confirmed

- UI controls discovered by visible title text (`搜索`, `创建方法`, `链式调用`).
- Candidate identity inferred from button order or Y position in older layers.
- `removeTarget:nil action:NULL` can remove behavior installed by a prior layer.
- Later modules depend on the meaning of a selector *after* an earlier exchange, e.g. a selector alias intentionally points to an older V3 implementation.
- Several installer functions mix backend behavior and UI decoration, so disabling the entire installer would silently remove required runtime behavior.

## M5.4 target architecture

```text
ZNRuntimeMenuControllerV040
  |
  +-- V3 state/backend
  |     query / candidates / selected / page / limit / status
  |
  +-- Search backends
  |     hybrid named search
  |     M4.5 owning-method address resolution
  |     Assembly semantics
  |
  +-- M5.4 Unified Finder Renderer
  |     Search
  |     Results
  |     Detail
  |     persistent search history
  |     /0-/8 argument rows
  |
  +-- behavior decorators only
        M4.6.2 candidate binding
        M4.7 receiver capture gesture
        M5.1/M5.2 chain create/execute/restart
```

The Unified renderer does **not** call the previous search/results/detail renderer implementation. This deliberately cuts the old renderer chain at runtime while preserving backend/action selectors needed for compatibility.

## Search-history contract

- Persistent `NSUserDefaults` storage.
- Maximum 50 entries.
- Newest first.
- Case-insensitive deduplication.
- One row per query, independently scrollable.
- History is rendered by the Unified Search page itself, not a swizzle/post-render hook.
- Tapping a history row only fills the method-name field; it does not start a search.

## Migration rule

No new Method Finder feature may add another renderer swizzle. New capabilities must be implemented as:

1. state/backend service, or
2. explicit Unified renderer code, or
3. narrowly scoped behavior decorator that binds to explicit controls without changing layout.
