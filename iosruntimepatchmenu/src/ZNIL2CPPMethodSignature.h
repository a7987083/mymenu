#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *ZNIL2CPPEncodeParameterTypeNames(NSArray<NSString *> *types);
FOUNDATION_EXPORT NSArray<NSString *> *ZNIL2CPPDecodeParameterTypeNames(NSString *encoded);
FOUNDATION_EXPORT NSArray<NSString *> * _Nullable ZNIL2CPPParameterTypeNamesForCandidate(NSDictionary<NSString *, id> *candidate,
                                                                                         NSString * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSString *ZNIL2CPPFullMethodIdentity(NSString *assembly,
                                                       NSString *namespaceName,
                                                       NSString *className,
                                                       NSString *methodName,
                                                       NSArray<NSString *> *parameterTypeNames);
FOUNDATION_EXPORT NSString *ZNIL2CPPShortSignature(NSString *methodName,
                                                   NSArray<NSString *> *parameterTypeNames);

@interface ZNIL2CPPFullSignatureResolver : NSObject
+ (instancetype)sharedResolver;
- (nullable NSDictionary<NSString *, id> *)resolveAssembly:(NSString *)assembly
                                                 namespace:(NSString *)namespaceName
                                                 className:(NSString *)className
                                                    method:(NSString *)methodName
                                        parameterTypeNames:(NSArray<NSString *> *)parameterTypeNames
                                                     error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
