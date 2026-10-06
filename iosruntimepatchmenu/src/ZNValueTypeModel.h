#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZNValueType) {
    ZNValueTypeAuto = 0,
    ZNValueTypeI32 = 1,
    ZNValueTypeU32 = 2,
    ZNValueTypeI64 = 3,
    ZNValueTypeU64 = 4,
    ZNValueTypeF32 = 5,
    ZNValueTypeF64 = 6,
};

FOUNDATION_EXPORT NSString *ZNValueTypeName(ZNValueType type);
FOUNDATION_EXPORT NSString *ZNValueTypeKey(ZNValueType type);
FOUNDATION_EXPORT ZNValueType ZNValueTypeFromKey(NSString * _Nullable key);
FOUNDATION_EXPORT BOOL ZNValueTypeIsInteger(ZNValueType type);
FOUNDATION_EXPORT BOOL ZNValueTypeIsFloating(ZNValueType type);

// Runtime ABI recommendation. Unknown/unsupported managed types remain Auto.
FOUNDATION_EXPORT ZNValueType ZNValueTypeForManagedTypeName(NSString * _Nullable managedType);

// Public-control defaults. Slider intentionally exposes integer UI steps even
// when the backend value type is F32/F64; e.g. UI 5 -> backend 5.0f/5.0.
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *ZNDefaultRangeForValueType(ZNValueType type,
                                                                                    BOOL slider);

// Canonicalizes an authored value for display/invocation according to type and
// configured range. Returns nil on invalid/out-of-range input.
FOUNDATION_EXPORT NSString * _Nullable ZNCanonicalValueString(NSString * _Nullable input,
                                                               ZNValueType type,
                                                               NSNumber * _Nullable minValue,
                                                               NSNumber * _Nullable maxValue,
                                                               NSNumber * _Nullable stepValue,
                                                               NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
