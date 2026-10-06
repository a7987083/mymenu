#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// M6.10 — Static Prepared Native Hook Backend V1.
// Instruments UnityFramework on disk before final signing. Runtime activation
// only writes a replacement pointer into a writable slot.
FOUNDATION_EXPORT BOOL ZNBuildInstallStaticPreparedNativeHooksV1(
    NSArray<NSString *> *builderOutputs,
    NSString * _Nullable * _Nullable report,
    NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
