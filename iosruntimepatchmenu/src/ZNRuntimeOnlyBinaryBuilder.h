#import <Foundation/Foundation.h>

@class ZNBinaryPatchWorkspace;

NS_ASSUME_NONNULL_BEGIN

// M4.6.1 runtime-only generation path. It creates an owned __ZNDATA/__zndata
// container with an empty Static Dispatch header so Runtime Method Call records
// can be embedded without requiring any Static Patch row.
BOOL ZNRuntimeOnlyBinaryBuilderBuildWorkspace(ZNBinaryPatchWorkspace *workspace,
                                              NSArray<NSString *> * _Nullable * _Nullable outputs,
                                              NSString * _Nullable * _Nullable report,
                                              NSString * _Nullable * _Nullable error);

// Runtime-only outputs intentionally skip Static Feature metadata/RVA transforms
// (there are zero Static entries) but still rebuild the ad-hoc CodeDirectory.
BOOL ZNRuntimeOnlyPostProcessGeneratedOutputsM461(NSArray<NSString *> *innerOutputs,
                                                  NSString *innerReport,
                                                  NSArray<NSString *> * _Nullable * _Nullable outputs,
                                                  NSString * _Nullable * _Nullable report,
                                                  NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
