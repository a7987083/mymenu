#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void ZNSSPV3InstallExecutionProbes(IMP anchorIMP);
FOUNDATION_EXPORT void ZNSSPV3FeatureBegin(id object, BOOL active);
FOUNDATION_EXPORT void ZNSSPV3FeatureEnd(id object, BOOL active);
FOUNDATION_EXPORT NSArray<NSString *> *ZNSSPV3DiagnosticLines(void);

NS_ASSUME_NONNULL_END
