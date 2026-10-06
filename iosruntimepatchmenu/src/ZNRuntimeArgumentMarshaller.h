#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A custom encoder receives the human-entered argument and must return the
/// exact unboxed IL2CPP value-type payload. Registration is performed once,
/// before executing Runtime Call actions.
typedef NSData * _Nullable (^ZNRuntimeValueTypeEncoder)(NSString *text,
                                                         NSUInteger expectedSize,
                                                         NSString * _Nullable * _Nullable error);

@interface ZNRuntimeArgumentMarshaller : NSObject

/// Thread-safe registration by full managed name, e.g. Namespace.Type.
+ (void)registerValueType:(NSString *)managedType encoder:(ZNRuntimeValueTypeEncoder)encoder;

/// Build an *unboxed* value-type buffer from the exact MethodInfo parameter.
/// The caller must retain the returned NSMutableData until il2cpp_runtime_invoke returns.
/// Supported without a custom encoder: explicit "hex:<bytes>" input with an exact
/// size match. This deliberately does not guess fields or encryption strategies.
+ (nullable NSMutableData *)encodeValueTypeParameterForMethod:(uintptr_t)methodInfo
                                                        index:(NSUInteger)index
                                                         type:(NSString *)managedType
                                                        input:(NSString *)text
                                                    imagePath:(NSString *)imagePath
                                                        error:(NSString * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
