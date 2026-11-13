# Method Finder P4 — Offline Chinese method-name gloss (Developer only)

## Stable baseline and scope

- Baseline: `fix/method-finder-p3-scroll-restore@3ef77f877932e369107c215eb37894cee8d5fe26`.
- Work branch: `feat/method-finder-p4-local-translation`.
- **Developer dylib only:** `iosruntimepatchmenu/Makefile` compiles `ZNMethodTranslator.mm`.
- Customer `customer/clean-runtime-rewrite` and its Makefile were **not changed**.
- Existing runtime method identities, finder searches, filters, patch authoring, native hook execution and binary format are **not translated or mutated**.

## Source and implementation

- `resources/MethodTranslation.zh-CN.json`: exactly 3,000 unique offline terms, filtered from MIT ECDICT-derived sources with approx. 470 manually curated game/SDK/Unity/developer glosses or whole-method aliases. Count is mechanically verified; every imported sense is **not** individually linguistically verified.
- `resources/DICTIONARY_LICENSE.md`: upstream attribution and MIT notices.
- `scripts/generate_dictionary.py`: reproducible UTF-8 JSON→C++ static-data generator. Run after changes and commit the regenerated header.
- `src/ZNMethodDictionary.generated.h`: generated embedded dictionary; no runtime external file or network request.
- `src/ZNMethodTranslator.h/.mm`: per-process once-only dictionary decode, bounded 512-item method-name cache, case/underscore parsing, DP merged-token segmentation, exact method-name overrides, unknown-token fail-closed.
- `src/ZNUnifiedUI.mm`: only P3's single final method-card renderer was modified. Added one Chinese gloss row under original name; card content and action area moved 22pt without changing button actions or finder method records.
- `tests/method_translator_test.mm`: representative Objective-C++ Foundation smoke checks.

## Build/verification

- Local maintenance:
  ```sh
  cd iosruntimepatchmenu
  python3 scripts/generate_dictionary.py
  python3 scripts/generate_dictionary.py --check
  make FINALPACKAGE=1
  ```
- Theos `before-all::` rejects stale generated headers, preventing silent JSON/embedded-binary divergence.
- CI pass: GitHub Actions run **43391978816**, tested commit `3e803f15cdd0639461aad34b11867af2d8b201e6`. Separate translation Foundation smoke test, dictionary reproducibility check, arm64 dylib build, and ldid packaging succeeded.
- CI artifact: `mymenu-M6.13.3-3e803f1`.
- Packaged Mach-O SHA256: `11b58979fb5b7b51813b82fa26537c2da5116a6cd1457bad4d735ef3a05a9478`.
- Independent artifact inspection: Mach-O 64-bit arm64; embedded data contains `addcoingem`, `setloginsdkname` and `ZNMethodTranslator`.
- **On-device verification: not yet performed**; screenshots/display behavior and device lifecycle require user testing.

## Risks and next steps

- Glosses represent method-name hints, **not proof of actual code behavior**. Ambiguous everyday words may use imperfect senses; revise exact whole-method entries to override when necessary.
- DP intentionally returns no translation when a segment cannot be fully interpreted; this avoids hallucinating partial names.
- Large method lists may add small CPU/memory overhead during first render; per-process cache bounds repeat costs.
- Device acceptance: verify method card Chinese line, text truncation, card tapping, hooks, numeric controls, P2 refinement and P3 scroll restoration; confirm method identities and exported embed actions remain unchanged.
- Extend vocabulary: edit JSON while maintaining exactly 3000 entries for this P4 baseline; regenerate header and re-run tests/CI. If choosing a larger capacity later, explicitly change generator contract rather than padding duplicate terms.
