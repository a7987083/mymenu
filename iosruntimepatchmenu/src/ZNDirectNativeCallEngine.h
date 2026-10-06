#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// M6.13 Direct Native Call V1.
// Calls a resolved IL2CPP methodPointer directly, bypassing runtime_invoke.
// V1 is deliberately fail-closed: only ARM64 GPR-safe arguments/returns are accepted.
@interface ZNDirectNativeCallEngine : NSObject
+ (instancetype)sharedEngine;
@property(nonatomic,copy,readonly) NSDictionary<NSString *,id> *lastResult;
- (BOOL)prepare:(NSString * _Nullable * _Nullable)error;
- (BOOL)supportsCandidate:(NSDictionary<NSString *,id> *)candidate
                   reason:(NSString * _Nullable * _Nullable)reason;
- (nullable NSDictionary<NSString *,id> *)executeCandidate:(NSDictionary<NSString *,id> *)candidate
                                            argumentValues:(NSArray<NSString *> *)argumentValues
                                                     error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
