# ZonoPatch v0.5.7 Development State

Date: 2026-09-14

This file records the post-Named-Offset development candidate. It is not a sealed release note.

## Branch / Baselines

- Branch: `feature/runtime-patch-menu-v0.5.7-toggle-method-finder`
- Sealed predecessor: `release/runtime-patch-menu-v0.5.6.2-sealed` @ `86edac4d70ef467e9a58912768b6c6c72077842a`
- v0.5.7 Named Offset baseline: `8300cf41589bf8aa9a690152d4dab3dd6333073c`
- Functional code head: `f678d1c1850503eef6926b324112e0782236f522`
- CI-validated head: `3f7c2176304942f4adc24d2941b4b13310ca8af8`

## Implemented

### ZONOE Feature Toggle

- Replaces the public Feature page text `开/关/MIXED` buttons with a custom `UIControl` matching the existing translucent ZONOE UI.
- ON: theme accent outline/glow, knob right, check mark left.
- OFF: dark translucent track, knob left, no label.
- MIXED: centered knob with understated accent indicator.
- Existing `ZN50SetFeatureEnabled` transaction/rollback and `zn.f.%016llx.enabled` persistence remain authoritative.

### Hybrid Low-Memory Method Finder

- Adds `ZNIL2CPPHybridFinder` without creating a global method index.
- Full Namespace/Class input uses direct class lookup where possible.
- Bare/class-only searches use bounded streaming with:
  - case-insensitive exact method-name matching,
  - Assembly-CSharp priority,
  - 8 candidate cap,
  - 12,000 class cap,
  - 750 ms search budget.
- Ambiguous matches are rejected instead of selecting the first candidate.
- Resolved addresses expose RVA, real Mach-O Preferred/IDA VA, Runtime VA, MethodInfo and method pointer.
- Pointer classification currently reports `direct-api`, `direct-fallback`, or `virtual-fallback` only after executable-segment validation.
- Named Offset authoring now routes symbolic expressions through the Hybrid Finder, while the existing Runtime Validator and Builder V3 still consume validated numeric RVAs.

### Method Finder UI

- Adds developer menu category `方法查找` with search field and result details.
- Shows canonical method, assembly/class, pointer source/type, RVA, Preferred/IDA VA, Runtime VA, MethodInfo and Method Pointer.
- `复制信息` copies result metadata.
- `加入 Builder` creates an unvalidated Builder row with the symbolic expression and `UnityFramework` target; it does not write Patch bytes and does not bypass `读取验证`.

## Lifecycle invariants preserved

- Full Deferred Bootstrap remains intact.
- Exactly one load-time constructor remains: `ZNDeferredColdLauncherBootstrap`.
- No compiled Objective-C `+load`.
- Method Finder UI/backend are installed from the existing deferred authoring stage after first ZN activation.
- Protection V2 + Static RVA Protection V1 remain compiled and binary-verified.

## Final CI candidate

- Workflow: `Build Runtime Patch Menu v0.5.7 Named Offset`
- Run: `34805178354`
- Result: `success`
- Artifact: `ZonoPatch-v0.5.7-NamedOffset-Test`
- Artifact ID: `10332369005`
- Artifact archive digest: `sha256:10871aa93e276ba1b73dd568d3208b2ea957dd3120e99d9e453dc2fa8b234df3`
- Dylib: `ZonoPatch_v0.5.7_NamedOffset.dylib`
- Dylib SHA256: `2de69ca9215e3eebec8a9072d9060a74a6fbaed3523c85b7921f2fbf422c881e`
- Binary: thin arm64 Mach-O
- `__init_offsets`: 4 bytes / exactly one constructor

## Validation boundary

CI, unit tests, Theos compilation, link/sign, binary marker checks and artifact upload are complete.

Not yet verified on a physical device:

- final Toggle appearance/touch behavior across themes and Full/Compact layouts,
- persisted state restore / MIXED / rollback UX,
- real IL2CPP `gethp`/`GetMoney` lookup and address comparison,
- repeated bounded searches and memory stability on a large app,
- ambiguous/hidden API behavior,
- Method Finder -> Builder -> safe Patch bytes -> `读取验证` -> apply/restore.

Generic/inflated/thunk classification is intentionally not claimed yet. Version strings inside legacy/inlined runtime code also still contain older `0.5.5/0.5.6` labels and need a compatibility audit before changing.
