# Method Finder P1 — Result Card Overlap Audit

Baseline: `audit/method-finder-swizzle-m6133@45c473860edb3b4b153e52fbc608131134958e71` (user tested).
Change commit: `1c802c676cc564c7231ca6c370bbb1007749f059`.
Scope: P1 only — method result card geometry. P2 (secondary class search) and P3 (scroll restore) intentionally untouched.

## Source evidence

- `iosruntimepatchmenu/src/ZNUnifiedUI.mm:14088+`: final installed M6.13.1 renderer is `zn52x_renderResultsAtWidth:`; it handles class-list dispatch but otherwise owns method cards directly.
- Baseline `:14174-14229`: fixed `railW=190` / `leftW=MAX(120, cardWidth-190-rightInset-23)` and right rail `x0=cardWidth-rightInset-190`. For card width below 343 points the forced 120pt label column can overlap the rail; method labels are also excessively truncated at greater widths.
- Baseline `:14230-14310`: eight buttons are placed in four rows within the right rail with fixed row y-values of 7, 39, 71, 103; all selectors and associated candidates are set here.
- `ZNM613ApplyModeVisual` locates mode buttons within card and applies state without owning their frames; button movement must preserve the same parent card and titles.
- `znm54_openDetail:` is bound to a transparent identity tap target; do not overlay the operation buttons with this target.
- Param rows begin at `topAreaH`, followed by status and result labels. Increasing `topAreaH` carries the lower sections down together without changing parameter state or text-field targets.

## Isolated fix

- Identity labels occupy the full card width minus horizontal insets.
- Detail tap target ends before the button grid.
- Eight existing buttons use two columns spanning the card below the identity section.
- Four row positions derive from one `actionTop` and `actionPitch`.
- Parameter block starts below last button; original status and candidate association logic preserved.
- No new hooks, selectors, helper runtime state, Finder search changes or swizzles.

Geometry invariants: all positions are relative to `card.bounds`. Button columns end before right inset; the last 27pt-tall button ends at `actionTop + 3*actionPitch + 27`, less than `topAreaH` (`actionTop + 4*actionPitch + 5`).

## Acceptance

1. Build and verify arm64 dylib in GitHub Actions.
2. On-device inspect 0/1/N argument result cards at narrow window widths; full method, class, Assembly and RVA fields visible in dedicated area (very long text may still ellipsize).
3. Tap identity to open detail; tap all eight buttons / long press receiver; verify correct candidate association and mode state.
4. Confirm parameter fields and both status labels remain below grid, and card height fits.
5. P2/P3 deferred; no claim of scroll restoration or secondary search from this patch.

Verification: source review / git diff completed; build and device evidence tracked separately.
