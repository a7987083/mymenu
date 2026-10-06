#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    uintptr_t function0;
    uintptr_t methodInfo0;
    uintptr_t function1;
    uintptr_t methodInfo1;
    uintptr_t function2;
    uintptr_t methodInfo2;
    uintptr_t function3;
    uintptr_t methodInfo3;
    uint32_t variant;
} ZNComplexStructResolvedFunctions;

typedef BOOL (*ZNComplexStructTransformFn)(uintptr_t base,
                                           const ZNComplexStructResolvedFunctions *functions,
                                           int32_t multiplier,
                                           int64_t * _Nullable before,
                                           int64_t * _Nullable after);

FOUNDATION_EXPORT NSString * const ZNComplexStructCodecSecureLongWholeAccessor;
FOUNDATION_EXPORT NSString * const ZNComplexStructCodecObscuredInt;

@interface ZNComplexStructCodecRegistry : NSObject
+ (instancetype)sharedRegistry;
- (void)registerCodecKey:(NSString *)key transform:(ZNComplexStructTransformFn)transform;
- (nullable NSValue *)transformValueForCodecKey:(NSString *)key;
- (BOOL)supportsCodecKey:(NSString *)key;
@end

// Exact Type -> Codec mapping. Unknown complex types intentionally return nil.
FOUNDATION_EXPORT NSString * _Nullable ZNComplexStructCodecKeyForManagedType(NSString *managedTypeName);
FOUNDATION_EXPORT NSString *ZNComplexStructNormalizedManagedType(NSString *managedTypeName);

FOUNDATION_EXPORT void ZNRegisterBuiltInComplexStructCodecs(void);

NS_ASSUME_NONNULL_END
