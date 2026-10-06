#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// v0.5.4 explicit generated-binary postprocess stage.
// Order is fixed: ZNF1 display metadata -> Static RVA Protection V1 ->
// self-contained ad-hoc CodeDirectory rebuild -> build_report enrichment.
BOOL ZNPostProcessGeneratedBinaryOutputs(NSArray<NSString *> *innerOutputs,
                                         NSString * _Nullable innerReport,
                                         NSArray<NSString *> * _Nullable * _Nullable outputs,
                                         NSString * _Nullable * _Nullable report,
                                         NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
