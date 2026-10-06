#import <Foundation/Foundation.h>

#import "ZNPatchCore.h"

// M6.1 split-mode.
//
// Offset and Runtime are deliberately separate authoring/execution domains:
//
//   Offset  -> Static/Offset backend only.
//   Runtime -> Explicit IL2CPP Method/Invoke backend only.
//
// In particular, Number/Slider rows created in the Offset workspace are never
// auto-promoted into Runtime actions during generation. This avoids changing
// Target/RVA semantics behind the user's back and keeps Offset validation,
// Shared Site handling, Static Value Cell generation and Runtime Method calls
// independently auditable.
//
// The public installer remains present because bootstrap already calls it. It
// now records the split-mode contract and intentionally installs no Builder
// swizzle.

extern "C" void ZNInstallM610UnifiedFeatureModelDeferred(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[ZNRuntimeLogger sharedLogger] log:
            @"[m6.1-split] Offset/Runtime separated: no Offset->Runtime promotion; "
             "Offset stays Static/Offset backend; Runtime stays explicit IL2CPP backend"];
    });
}
