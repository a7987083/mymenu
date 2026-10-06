#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ZNBinaryPatchWorkspace;

FOUNDATION_EXPORT BOOL ZNBuildExecutorBuildWorkspace(ZNBinaryPatchWorkspace *workspace,
                                                     NSArray<NSString *> * _Nullable * _Nullable outputs,
                                                     NSString * _Nullable * _Nullable report,
                                                     NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
