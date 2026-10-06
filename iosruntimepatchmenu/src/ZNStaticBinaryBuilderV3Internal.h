#import <Foundation/Foundation.h>
@class ZNBinaryPatchWorkspace;

NS_ASSUME_NONNULL_BEGIN

// v0.5.4 explicit builder entry point. This is intentionally an internal C
// function rather than an Objective-C +load/method_exchange implementation.
BOOL ZNStaticBinaryBuilderV3BuildWorkspace(ZNBinaryPatchWorkspace *workspace,
                                           NSArray<NSString *> * _Nullable * _Nullable outputs,
                                           NSString * _Nullable * _Nullable report,
                                           NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
