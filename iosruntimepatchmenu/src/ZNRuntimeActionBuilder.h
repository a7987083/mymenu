#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Runs after Static Binary Builder V3 and before generated-binary postprocess.
// It never changes ZN44StaticEntry or Static Dispatch code. Runtime actions are
// appended inside V3-owned __ZNDATA/__zndata capacity and section.size is grown
// only within the already-owned segment.
BOOL ZNRuntimeActionEmbedIntoGeneratedOutputs(NSArray<NSString *> *builderOutputs,
                                              NSString * _Nullable * _Nullable report,
                                              NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
