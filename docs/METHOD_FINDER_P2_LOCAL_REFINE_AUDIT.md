# Method Finder P2 — Method-name refinement (corrected)

Baseline: P1 `fix/method-finder-p1-card-layout@25d888baecd7720477f90e5ffe1171c34a7f870a`.
Correction commit: `ed56c3a3c039e922f5c12f33defd8c1fd9ded5a2`.
Prior P2 class-list filter commit `cd2b0d8` was wrong in UX scope and is superseded: its class-list UI is removed from the current source. Keep history intact.

## Request / root cause

User expects a second search **within methods after finding and opening a class**, not within the class-name search result list.

Source evidence:
- Class search: `ZNUnifiedUI.mm` `znm54_submitSearch:` -> `zn64_searchClasses:`; result list `znm64_renderClassResultsAtWidth:`. No input belongs here.
- Class selection: `znm64_selectClass:` resolves `zn64_methodsForClass:` and updates `zn60v3_candidates`.
- Final method result rendering: `zn52x_renderResultsAtWidth:` owns cards, binding every method card to a full candidate in `kZNM613CardCandidateKey` and controlling argument/execute actions.
- `znm42_filter` already filters method arity. New text refinement must compose with it without changing `zn60v3_candidates` or backend.
- P1 action grid `actionTop=125` retained unchanged.

## Corrected implementation contract

1. Restore unchanged class search results UI from the P1 source; remove incorrect local class-list filtering.
2. Add a single method-name text field at the top of the actual method results page, below back/title and above the existing arity filter.
3. Use the original full method candidate array; filter case- and diacritic-insensitive substrings of candidate[`method`] only. Do not mutate original candidate data.
4. During text editing, do not call `renderPage` or recreate cards/controls. Iterate already rendered method cards via their candidate association, set `hidden`, reorder visible cards vertically, recompute content height and update visible/total count. Argument input state and first responder remain intact.
5. Preserve class-scope method filter on return from method detail; reset it on new class selection, new search or mode change. Class list remains unfiltered.
6. No new Swizzle, new backend scan, new execution path, or changes to Builder, Dobby Hook or native call. P3 scroll offset restore remains separate.

## Validation

- Static source/diff: corrected method results filter; original class list reverts; no `renderPage` inside EditingChanged.
- CI compile and verify: independently checked in GitHub Actions.
- Device acceptance: find a class with many methods, choose `查看方法`, type partial method name, observe `visible / loaded`; clear filter; switch arity filter; visit detail/back; test existing candidate buttons and args.
- Device status: **UNVERIFIED** until user tests. No device hash or IMP trace implied.
