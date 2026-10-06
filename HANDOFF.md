# HANDOFF

## Current work line

ZonoPatch Runtime Patch Menu `v0.5.8-dev` — **M5.8.3 Slider Authored Max + Action Identity**.

- Repository: `a7987083/UnitXP_SP3-Moonstone`
- Active branch: `fix/m5.8.3-slider-max-action-identity`
- Baseline: M5.8.2 `59eebc1d21c7a6894f27a5480bf8100bbf4f2094`
- Business-code CI anchor: `8fcdb5af93e2cf8884f2e5189acad3acf744abcc`
- Run: `36364086245` — SUCCESS
- Job: `108746902686`
- Artifact ID: `10947010903`
- Artifact digest: `sha256:344f603bc385d8d86e044b37709ce14f76282c366fdaa49cf71ee2889f0b30cc`
- Dylib: `ZonoPatch_v0.5.8_M5.8.3_SliderMax_ActionIdentity.dylib`

## Why M5.8.3

M5.8.2 device feedback confirmed Slider interaction/value display works, but exposed two authoring/identity bugs: an authored Slider value such as `31` did not become `max=31`, and display-layer dedupe merged distinct Fixed/Number/Slider Builder actions targeting the same IL2CPP method.

## Runtime customer architecture

`ZNM58UnifiedControlRuntime` remains the only Runtime customer renderer. No new UI/controller/nested renderer was added.

- UI-level title/method collapse was removed.
- `ZNRuntimeActionRuntime` remains the exact embedded-record dedupe owner.
- Separate Builder actions targeting the same method stay separate.
- Fixed actions retain `执行`.
- Number actions retain input + `执行`.
- Slider keeps live in-row value display and release-only invoke.
- Runtime value persistence remains `zonoe.m5.8.2.runtime-values.v1`, preserving values across the M5.8.2 → M5.8.3 upgrade.

## Slider authoring contract

Only Slider is generation-time value-required.

- Builder argument field live-syncs during EditingChanged.
- Before Runtime Action embedding, every enabled Slider validates the current authored value.
- Missing / invalid / non-finite / `<= 0` value fails generation.
- Valid Slider metadata becomes `min=0`, `max=<authored value>`, `step=1`, `default=<authored value>`.
- Number / Fixed / Switch / Button have no new pre-generation value requirement.

## CI history

- Run `36363946557`: build succeeded; Binary Verify failed only because CI searched a Chinese Objective-C NSString with `strings -a`.
- Commit `8fcdb5af93e2cf8884f2e5189acad3acf744abcc` changed only the verification marker to ASCII.
- Run `36364086245`: Build / Binary Verify / Artifact Upload all SUCCESS.

## Immediate device checklist

1. Footer `0.5.8 · M5.8.3`.
2. Slider authored with `31` has maximum exactly `31`.
3. Empty/invalid Slider value is rejected at generation.
4. Number/Fixed can generate without a mandatory authored value.
5. Same-method Fixed + Number + Slider actions all appear; none are collapsed by title/method identity.
6. Fixed shows `执行`; Number shows input + `执行`.
7. Slider value label follows drag; drag itself does not Invoke; release invokes once.
8. Persisted Runtime values restore after restart.

## Open boundaries

- M5.8.3 device validation is pending; CI success is not device success.
- Slider currently uses authored max as its generated default/initial value as well. Change this only if product behavior is explicitly revised.
- Static controls still need regression on a freshly generated M5.8+ target.
- Builder renderer / Method Finder Phase 2 consolidation remains open. Do not add another renderer layer.
