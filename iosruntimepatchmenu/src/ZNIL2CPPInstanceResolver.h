#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZNIL2CPPInstanceResolver : NSObject
+ (instancetype)sharedResolver;
- (NSDictionary<NSString *, id> *)capabilities;
- (NSArray<NSNumber *> *)candidateAddressesForAssembly:(NSString *)assembly
                                             namespace:(NSString *)namespaceName
                                             className:(NSString *)className
                                                 limit:(NSUInteger)limit
                                           diagnostics:(NSString * _Nullable * _Nullable)diagnostics
                                                 error:(NSString * _Nullable * _Nullable)error;
- (void * _Nullable)resolveUniqueInstanceForAssembly:(NSString *)assembly
                                           namespace:(NSString *)namespaceName
                                           className:(NSString *)className
                                         diagnostics:(NSString * _Nullable * _Nullable)diagnostics
                                               error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
