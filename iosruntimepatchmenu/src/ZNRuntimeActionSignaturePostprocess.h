#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// M4.6 runs immediately after the legacy Runtime Action table is embedded and
// before generated-binary signing/postprocess. It appends exact managed
// parameter signatures into the existing Runtime Action string pool and uses
// reserved[1] + ZNRuntimeActionFlagParameterSignature without changing the
// 64-byte entry ABI or format version.
BOOL ZNRuntimeActionAugmentGeneratedOutputsM46(NSArray<NSString *> *builderOutputs,
                                               NSString * _Nullable * _Nullable report,
                                               NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
