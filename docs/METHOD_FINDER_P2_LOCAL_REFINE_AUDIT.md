# Method Finder P2: local secondary search — evidence and regression contract

Baseline: `fix/method-finder-p1-card-layout@25d888baecd7720477f90e5ffe1171c34a7f870a`. P1 layout is preserved. P3 scroll-position restoration is out of scope.

## Source-level chain

1. `ZNUnifiedUI.mm:12376+` `znm54_submitSearch:` dispatches class searches to existing `ZNIL2CPPHybridFinder zn64_searchClasses:assembly:limit:cancel:error:`. This remains untouched.
2. On the main queue, the scan result is retained as `kZNM64ClassResultsKey`, and the current page switches to Results. Original result dictionaries hold `assembly`, `namespace`, `class`, and optional `truncated`. No new Runtime scan is needed for local refinement.
3. `ZNUnifiedUI.mm:14088+` `zn52x_renderResultsAtWidth:` checks class mode and absent `kZNM64SelectedClassKey`, then calls `znm64_renderClassResultsAtWidth:`. This final routing is unchanged.
4. `znm64_selectClass:` receives the original identity dictionary via the `kZNM54CandidateKey` button association, then calls `zn64_methodsForClass:`. This must remain bit-for-bit behavior compatible.

## P2 change

- Add one **results-only** UITextField above class cards. It filters the loaded snapshot by class name, namespace or Assembly using case/diacritic-insensitive substring comparison.
- Keep the unfiltered result array immutable and untouched; derive visible cards on each keystroke.
- Render cards in a dedicated child list container, **not** by calling `renderPage` in `UIControlEventEditingChanged`. This keeps the keyboard, editing caret and outer search UI stable.
- Reflect `visible / loaded` counts. Empty local matches produce an explanatory empty card; clearing the field restores all loaded cards.
- Show an explicit notice when the original snapshot was truncated by scan limits/time budgets: local refinement cannot recover omitted classes.
- Persist the local filter string only for the current loaded class-result set; preserve it on drill-down/back; clear on a new class scan or when toggling search mode.
- Keep selector bindings, class identity dictionaries, class method lookup, original Method Finder search, Runtime, Hook and Builder untouched. **No new Swizzle**.
- Do not change outer `contentScroll.contentOffset` policy in P2; that is P3.

## Evidence vs verification

- Static diff: only `ZNUnifiedUI.mm` and this audit document; no backend file changed.
- Expected acceptance: query `cheat` returns an original class list, entering partial text filters instantly without a new scan or dismissing keyboard; clearing shows the complete cached set; a zero-match query shows an empty state; class drilldown/back preserves the filter; a new search resets it; method search mode remains unchanged.
- Negative acceptance: no extra `method_exchangeImplementations`, no `renderPage` inside local `EditingChanged`, no changes to existing P1 action button grid.
- CI success demonstrates compilation, **not** device behavior; record device test independently.
