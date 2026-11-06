# mymenu Customer — Phase 1 UI shell

Source branch: `build/m6.13.3-methodfinder-detail-renderer-v1`.
UI reference: `a7987083/ZonoePatch-V2@ZonoePatch-V3`
(`V3CustomerHost.mm`, `V3CustomerMenuController.mm`).

This phase isolates the Customer UIWindow and neon UI from Developer.
The current ZNCustomerAdapter intentionally returns an empty catalog and
rejects all operations. **It is not a functional Patch/Method customer yet.**
Do not ship this binary as functional.

Next implementation gate:
1. Read-only discovery for mymenu's ZN44 Static Dispatch entries.
2. Preserve existing ownership/rollback semantics by using the audited
   mymenu runtime; do not import the incompatible V3 executor.
3. Add ZNACTN1 Method actions only through a separate safe execution bridge.
4. Validate multi-feature identity, failure latch, refresh on dyld image load,
   UI input/slider semantics, launch/relaunch and actual device behavior.

Local build: `cd customer && make FINALPACKAGE=1` (Theos required).
No developer runtime, scanner, builder, or method finder should enter the
Customer target.
