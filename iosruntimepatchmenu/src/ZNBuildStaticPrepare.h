#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ZNBinaryPatchWorkspace;

// M6.8.4 active Static provider preparation.
// This is intentionally independent from the historical M5.8.5/M5.9.1
// ZNStaticBinaryBuilder swizzle route retained in ZNUnifiedUI.mm.
FOUNDATION_EXPORT BOOL ZNBuildPrepareStaticWorkspaceV1(
    ZNBinaryPatchWorkspace *workspace,
    NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
