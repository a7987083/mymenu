#import <Foundation/Foundation.h>
#import "ZNComplexStructCodec.h"

NS_ASSUME_NONNULL_BEGIN

@interface ZNComplexStructCodecResolver : NSObject
+ (instancetype)sharedResolver;

// Returns:
// codecKey, managedType, displayName, function0..3, methodInfo0..3, variant.
// Unknown types or incomplete exact method sets fail closed.
- (nullable NSDictionary<NSString *,id> *)resolveManagedType:(NSString *)managedTypeName
                                                      error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
