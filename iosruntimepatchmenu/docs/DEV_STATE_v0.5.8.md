# Method Finder V3 — v0.5.8-dev

## Baselines

- Milestone 1 branch: `feature/runtime-patch-menu-v0.5.8-method-finder-v3`
- Milestone 2 branch: `feature/runtime-patch-menu-v0.5.8-method-finder-v3-m2`
- Parent device-verified V2 baseline: `4377d4a4c6e325e54299e3055346240f4963940f`
- M1 product source commit: `ef98a090e1df5b69df3fbb86adb905008285d82c`
- M1 docs/state head after device acceptance: `92f64c9dc6e208904228ada6059cea7ba102972d`
- M2 compiled product source commit: `69b546edd0ed83a5699805951304aa3371a0bc30`
- V2 qualified lookup, RVA reverse lookup, zero-`__TEXT.vmaddr` compatibility, and Named Offset semantics remain preserved.

## Milestone 1 — device verified

Implemented:

- Interactive multi-candidate search API (`ZNIL2CPPMethodFinderSearchV3`).
- Candidate-list modes for bare name, qualified class, and RVA reverse lookup.
- Candidate limit 8/16/32/64 (default 32).
- Search result page instead of treating multiple matches as an interactive-search error.
- Method detail page with RVA, Preferred VA, Runtime VA, MethodInfo, Method Pointer, pointer source/type.
- Safe first-16-byte native code preview via `vm_read_overwrite`.
- Per-address/raw-byte copy actions.
- `Create Patch` reuses the existing Builder + Runtime Validator chain and does not bypass validation.
- Candidate -> Builder bridge forces the selected candidate's canonical expression into the Builder row.
- V2 remains authoritative for Named Offset single-result resolution.

M1 build evidence:

- Workflow: `Build Method Finder V3 via Main`
- Run: `34878983443`
- Result: success
- Artifact id: `10361858260`
- Artifact: `ZonoPatch-v0.5.8-MethodFinder-V3-M1`
- Archive digest: `sha256:a8726474677cc4f2b3caa583820806e10df1841c6b096621cb5c10cecfd4a92d`
- Dylib SHA256: `1b05fcd88ad2b80915bb5668442f8523604ad81567b2a16e78013f1781faad6e`
- Mach-O: thin arm64 dylib
- `__init_offsets`: 4 bytes, exactly one cold-launch constructor

M1 device acceptance reported PASS:

1. `get_TotalCashReward` opens the candidate list and includes `Cash::get_TotalCashReward/0`.
2. Selected detail shows the known RVA `0x2DA9E10` with Runtime/MethodInfo/Method Pointer data.
3. `0x2DA9E10` RVA reverse lookup works.
4. Full qualified expression resolves the known target.
5. Candidate detail/copy workflow works.
6. `Create Patch` preserves the selected candidate's full canonical expression.

Therefore the tested M1 paths are **DEVICE-VERIFIED**. M1 itself is not a sealed release tag.

## Milestone 2 — async wide search + persistent index

M2 is implemented as a layer after the already-tested M1 workflow instead of rewriting M1 search/detail/Builder semantics.

Implemented:

- Bare method-name wide search, case-insensitive.
- Match priority: `exact > prefix > suffix > contains`.
- Example target behavior: searching `cash` can match names such as `CashReward`, `GetCash`, `SetCash`, and `get_TotalCashReward`.
- Structured queries (`Class::Method`, namespace/full assembly expression) retain exact M1 semantics.
- `0xRVA` remains an exact reverse lookup.
- Search work runs off the UI thread on a user-initiated background queue.
- Cooperative cancellation using a per-search UUID token.
- 12,000-class shard progress updates and an in-menu Cancel action.
- Cancelled first-time index builds do not save partial indexes.
- Assembly-CSharp is scanned first.
- Compact persistent metadata index stored as binary plist in the app cache area.
- Index is bound to UnityFramework Mach-O `LC_UUID` plus file size; fallback fingerprint uses file size + mtime only when UUID is unavailable.
- Persisted data contains only Assembly, Namespace, Class, Method, argument count, and RVA.
- Runtime VA, MethodInfo, and Method Pointer are never persisted and are re-resolved for the current launch.
- 32-byte fixed `ZN61IndexRecord` plus deduplicated string tables.
- First bare wide search builds the index while gathering ranked results.
- Subsequent bare searches query the saved index first and then re-resolve selected records against the current runtime.
- RVA reverse uses the index when available; without an index it falls back to the device-verified M1 reverse path rather than forcing a full index build.

## Milestone 2 build and verification

M2 compiled product source:

- Commit: `69b546edd0ed83a5699805951304aa3371a0bc30`
- Workflow: `Build Method Finder V3 via Main`
- Run: `34881764073`
- Result: success
- Source assertions: success
- Named Offset parser tests: success
- Static protection tests: success
- clang/Theos compile + link + sign: success
- Binary verification: success
- Artifact upload: success
- Artifact id: `10363436049`
- Artifact name: `ZonoPatch-v0.5.8-MethodFinder-V3-M2`
- Artifact size: `327976` bytes
- Artifact ZIP digest: `sha256:f4cc5d6bdf1549cd0f35c7dd7341f355e1907c208bc8a6e4ae1ee7a694b9161e`
- Dylib: `ZonoPatch_v0.5.8_MethodFinderV3_M2.dylib`
- Dylib size: `751216` bytes
- Dylib SHA256: `77d1cd3fe30c403c5f5db35ee35fbce8fa4da5f62352be04474bbabe52f24784`
- Mach-O: thin arm64 dynamic library
- Export verification: `_ZonoePatchGetAPIVersion`, `_ZonoePatchGetVersion` present
- Binary markers: `v3-candidate-list`, `v3-reverse-rva`, `m2-wide-index`, `m2-wide-build`, `built-and-saved` present
- `__init_offsets`: 4 bytes, preserving the one-constructor invariant
- Artifact was independently downloaded and the ZIP/dylib hashes and Mach-O constructor layout were rechecked after CI.

## Validation boundary

M2 is currently **SOURCE-IMPLEMENTED + CI-COMPILED + BINARY-VERIFIED**.

M2 is **NOT DEVICE-VERIFIED YET**. Do not call M2 sealed/release until the device acceptance checks below pass.

## Milestone 2 device acceptance

1. Start a first-time bare search for `cash`; the menu remains responsive while progress changes in the UI.
2. During a first-time `cash` index build, press Cancel once. Search stops without crash/hang, and a partial index is not reused as a valid index.
3. Run `cash` again and allow the first complete index build to finish. Results contain relevant method names and respect `exact > prefix > suffix > contains` priority.
4. Confirm a result such as `get_TotalCashReward` can still open the M1 detail page and resolves to the known RVA `0x2DA9E10` for the current game build.
5. Run `cash` once more after a completed index build. Status/log should report the index-hit path (`m2-wide-index`, `index=hit`) and should be materially faster than the initial build.
6. Re-test the full qualified expression `Assembly-CSharp.dll!com.notdoppler.ETDR.Cash::get_TotalCashReward/0`; it must remain exact and resolve the known target.
7. Re-test `0x2DA9E10`; RVA reverse must remain exact and functional.
8. Re-test detail copy and `Create Patch`; the Builder must still receive the exact selected canonical expression.

## Known M2 technical debt / risks

- The first complete index build resolves a native method pointer/RVA for every enumerated method. It is off-main and cancelable, but real-device build time still requires measurement.
- The binary plist index is compact enough for this milestone but is not mmap/SQLite-backed.
- No stale-index garbage collector is implemented; fingerprint mismatch prevents reuse, but old cache files may remain until the OS clears cache.
- Generic/inflated/shared native pointer classification remains incomplete.
- `-Wno-incomplete-implementation` was added to tolerate Objective-C category dependency declarations in the M2 bridge after clang treated those declarations as `-Werror`. This does not alter runtime behavior, but the declarations should be cleaned into dedicated dependency interfaces before sealing.
- Feature-branch GitHub Actions still has the earlier synthetic `BuildFailed/startup_failure` registration issue; the working CI path is the workflow registered on `main` that checks out the exact feature source SHA.

## Later milestones, not part of M2

- full IL2CPP return/parameter type and ABI metadata;
- Return Override backend;
- jailbreak inline Hook/Replace backend and original trampoline;
- call trace / argument / return logging;
- unified Runtime Modification management page.
