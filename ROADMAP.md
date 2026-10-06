# ROADMAP

## Current milestone — M5.8.3 Slider Authored Max + Action Identity

Repository: `a7987083/UnitXP_SP3-Moonstone`

Branch: `fix/m5.8.3-slider-max-action-identity`

Baseline: M5.8.2 `59eebc1d21c7a6894f27a5480bf8100bbf4f2094`

Business-code CI anchor: `8fcdb5af93e2cf8884f2e5189acad3acf744abcc` / Run `36364086245` / SUCCESS.

### M5.8.3 completed

- Keep `ZNM58UnifiedControlRuntime` as the single Runtime customer renderer; no nested/second Runtime UI was added.
- Remove the M5.8.2 display-layer `title + canonicalIdentity` collapse. `ZNRuntimeActionRuntime` remains responsible for exact embedded-record dedupe, while separate Builder actions targeting the same IL2CPP method remain separate cards.
- Fixed / Number / Slider variants for the same method are preserved as distinct Runtime actions.
- Only Slider has a generation-time value requirement.
- Slider authored value is validated as finite and `> 0`; generation fails closed with a clear error if missing/invalid.
- At generation, Slider metadata is normalized to `min=0`, `max=<authored value>`, `step=1`, `default=<authored value>` before Runtime Action embedding.
- Builder argument fields live-sync into `ZNRuntimeActionStore` while typing, so tapping Build without ending text editing cannot embed a stale Slider max.
- Number / Fixed / Switch / Button gain no new generation-time value requirement.
- Existing M5.8.2 live Slider value label and Runtime value persistence remain unchanged.
- ABI unchanged: Static Entry 128 bytes; Runtime Action Entry 64 bytes.

### CI / artifact

- Workflow: `Build Runtime Patch Menu v0.5.8 M5.8.3 Slider Max Action Identity`
- Run: `36364086245`
- Job: `108746902686`
- Result: SUCCESS
- Build: SUCCESS
- Binary Verify: SUCCESS
- Artifact Upload: SUCCESS
- Artifact ID: `10947010903`
- Artifact digest: `sha256:344f603bc385d8d86e044b37709ce14f76282c366fdaa49cf71ee2889f0b30cc`
- Dylib: `ZonoPatch_v0.5.8_M5.8.3_SliderMax_ActionIdentity.dylib`

First Run `36363946557` also compiled successfully; it failed only in Binary Verify because `strings -a` was incorrectly used to assert a Chinese Objective-C NSString. The CI assertion was corrected to an ASCII binary marker; business code was unchanged.

### Immediate device acceptance

1. Footer shows `0.5.8 · M5.8.3`.
2. Create Slider with authored value `31`; generated Runtime Slider must stop at `31` and display its current value.
3. Attempt to generate a Slider with empty/invalid value; generation must be rejected.
4. Number / Fixed actions must still generate without a mandatory authored value.
5. Create Fixed + Number + Slider actions for the same method; all intended actions must remain visible instead of being collapsed.
6. Fixed actions must expose `执行`; Number actions must expose input + `执行`.
7. Slider drag remains UI-only and release invokes once.
8. Runtime value persistence survives menu reopen/app restart.

### Next phase

Do not add another renderer layer. After M5.8.3 device acceptance, continue M5.8 Phase 2 Builder/Method Finder consolidation only if the current Runtime surface remains stable.
