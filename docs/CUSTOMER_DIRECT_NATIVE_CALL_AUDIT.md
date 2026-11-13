# Customer Direct Native Call support — evidence & regression contract

Baseline: `customer/clean-runtime-rewrite@179ed1fb62605c5fe96a73aea6a5eb25e87240c1`.
Work branch: `fix/customer-direct-native-call`. The baseline branch is not rewritten.

## Root cause (source-verified)

- `ZNRuntimeActionRuntime.mm` accepts ZNACTN1 kind=1 and kind=3 and splits them into `records` and `directRecords`.
- `customer/ZNCustomerAdapter.mm` previously enumerated **only `methods.records`**. Thus kind=3 was omitted, regardless of whether binary parsing worked.
- `customer/Makefile` omitted `ZNDirectNativeCallEngine.mm` and its resolver/codec dependencies. Simply making kind=3 visible would have no correct execution route.
- The supplied `build_report.json` reports 6 actions, with 3 kind=1 and 3 kind=3. It reports the generation process; actual embedded Mach-O and client dyld state have not been inspected.

## Implementation contract

- Enumerate the two canonical Runtime Action record collections once; keep distinct `method:` and `direct:` UI identities so type cannot be accidentally conflated.
- Keep existing per-argument UI controls, field semantics and original argument-vector values; only the selected control argument is overridden.
- For kind=1, reuse existing `ZNRuntimeActionRuntime executeRecord`.
- For kind=3, resolve explicit Assembly / namespace / class / method / arity using existing `ZNIL2CPPHybridFinder`. Fail closed on candidate identity mismatch, parameter count mismatch, type-signature mismatch or unsupported ARM64 ABI. Execute **only** through existing `ZNDirectNativeCallEngine`; no runtime_invoke fallback.
- Link existing `ZNDirectNativeCallEngine`, `ZNIL2CPPHybridFinder` and their codec modules in customer target; no developer menu, builder or additional Swizzle is installed.
- Native Hook kind=2 is not changed and remains metadata-only preview.

## Validation gates

1. Static review: changed Adapter and Customer Makefile only (plus this document / temporary CI trigger).
2. Customer-specific arm64 CI compilation and dylib verification; first real compiler/linker failure must be fixed without widening unrelated scope.
3. Binary verification: supply generated UnityFramework (not just JSON); inspect ZNACTN1 table and all 6 entry payloads.
4. On-device: client should display 3 kind=1 and 3 kind=3 records if binary scan succeeds; select kind=3 to exercise ABI checks and actual execution with qualified instance, and confirm no fallback. Also verify static and kind=1 control paths.
5. Log/report diagnostics must distinguish invalid table, missing image, unresolved method, unsupported ABI and successful execution.
6. Regressions and real device execution status are **not proven by CI**.

## Observed constraints

- `ZNDirectNativeCallEngine V1` intentionally supports only ARM64 GPR-safe arguments/returns with a narrow codec exception. Not every method candidate can be called directly.
- Different client branches implement distinct code: `customer/m6.13-client` adapter is a fail-closed shell, whereas `customer/clean-runtime-rewrite` has a working Runtime Method adapter but lacked direct-kind collection.
