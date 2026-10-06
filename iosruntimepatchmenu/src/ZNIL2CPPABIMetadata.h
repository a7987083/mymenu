#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZNIL2CPPABIValueKind) {
    ZNIL2CPPABIValueKindUnknown = 0,
    ZNIL2CPPABIValueKindVoid,
    ZNIL2CPPABIValueKindBool,
    ZNIL2CPPABIValueKindSigned32,
    ZNIL2CPPABIValueKindUnsigned32,
    ZNIL2CPPABIValueKindSigned64,
    ZNIL2CPPABIValueKindUnsigned64,
    ZNIL2CPPABIValueKindFloat32,
    ZNIL2CPPABIValueKindFloat64,
    ZNIL2CPPABIValueKindPointer,
    ZNIL2CPPABIValueKindObjectReference,
    ZNIL2CPPABIValueKindComplexValueType,
};

FOUNDATION_EXPORT NSString *ZNIL2CPPABIValueKindName(ZNIL2CPPABIValueKind kind);
FOUNDATION_EXPORT ZNIL2CPPABIValueKind ZNIL2CPPABIKindForManagedTypeName(NSString *typeName);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *ZNIL2CPPDescribeMethodABI(NSDictionary<NSString *, id> *candidate);
FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable ZNIL2CPPBuildReturnOverridePlan(
    NSDictionary<NSString *, id> *candidate,
    NSNumber *value,
    NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
