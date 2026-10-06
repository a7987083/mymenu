#import <Foundation/Foundation.h>
@class ZNRuntimeMethodAction;

NS_ASSUME_NONNULL_BEGIN

@interface ZNIL2CPPInvokeEngine : NSObject
+ (instancetype)sharedEngine;
- (NSDictionary<NSString *, id> *)capabilities;
- (nullable NSDictionary<NSString *, id> *)executeAction:(ZNRuntimeMethodAction *)action
                                                    error:(NSString * _Nullable * _Nullable)error;
- (nullable NSDictionary<NSString *, id> *)executeAction:(ZNRuntimeMethodAction *)action
                                                 receiver:(uintptr_t)receiver
                                                    error:(NSString * _Nullable * _Nullable)error;
- (nullable NSDictionary<NSString *, id> *)executeAssembly:(NSString *)assembly
                                                 namespace:(NSString *)namespaceName
                                                 className:(NSString *)className
                                                    method:(NSString *)methodName
                                             argumentCount:(NSUInteger)argumentCount
                                                     error:(NSString * _Nullable * _Nullable)error;
- (nullable NSDictionary<NSString *, id> *)executeAssembly:(NSString *)assembly
                                                 namespace:(NSString *)namespaceName
                                                 className:(NSString *)className
                                                    method:(NSString *)methodName
                                             argumentCount:(NSUInteger)argumentCount
                                            argumentValues:(NSArray<NSString *> *)argumentValues
                                                     error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
