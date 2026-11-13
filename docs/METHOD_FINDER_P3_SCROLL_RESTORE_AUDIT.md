# Method Finder P3 — scroll restoration audit

Baseline: `fix/method-finder-p2-class-refine@4083db5e5ee94082cd3b195ea4d045e6574f9aef` (P2 compiled; on-device status not independently evidenced).
Change: `f029700d9928afeddf26b7178bbdeb3ea209fde6`.

## Evidence chain

- `ZNUnifiedUI.mm` `zn60v3_renderFinder` clears contentView subviews and draws Search/Results/Detail on every render.
- `znm64_selectClass:` moves from class results to method results by selecting class identity, asynchronously replacing candidates and rendering the method results.
- `znm64_backToClasses:` moves back to class results but previously neither stored nor restored the original scroll position.
- `znm54_openDetail:` stores the selected candidate and renders Detail; `zn60v3_backToResults:` renders Results again without explicit scroll restoration.
- `contentScroll` is the shared vertical content container; global category transitions and unrelated UI also use it, so global interception is unsafe.
- P2 method-name refinement keeps the candidate identity and full original data; P1 geometry is unchanged.

## Minimal correction

- Maintain two **Method Finder-only** owner-associated values: class-list scroll Y and method-list scroll Y.
- Capture the respective list's offset *before* navigating from class list or method list.
- Restore immediately after the destination list's `renderPage`, clamping to the newly rendered scrollable height and adjusted insets.
- Reset stored positions on a new class search, a new method search and class/method-mode switch. Reset method offset when choosing a new class.
- Keep the text filter and arity filter states intact. No new swizzle, no timer, no global UIScrollView delegate and no delayed dispatch.
- This intentionally does not change generic feature/category scrolling, class/method data, runtime, invoke or builder logic.

## Acceptance on device

1. Search class names, scroll to the middle of the class list, open a class, back: class list returns to the previous position.
2. Open a class with many methods, scroll to a lower result, open details, back: method list returns to the previous position.
3. Repeat with P2 method filter active; confirm filtered list and scroll position restored.
4. Switch to a new class or perform new search; old offsets must not leak.
5. Check very short or empty lists; offset must clamp within content bounds.
6. Confirm P1 action grid / P2 live filtering / execution controls still work.

Validation: source commit is not a runtime result. CI/device status must be reported separately.
