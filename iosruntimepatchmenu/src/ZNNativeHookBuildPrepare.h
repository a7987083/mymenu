#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// M6.9 — Build-time Prepared Native Hook Descriptor V1.
//
// Resolves IL2CPP identities while the authoring game/runtime is already ready,
// then persists final UnityFramework RVA / UUID / static ABI facts. Generated
// binaries consume this descriptor without entering IL2CPP Method Resolve at
// process startup.
FOUNDATION_EXPORT BOOL ZNBuildPrepareNativeHookDescriptorsV1(
    NSString * _Nullable * _Nullable report,
    NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
