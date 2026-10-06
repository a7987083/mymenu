#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZNIL2CPPOwningMethodResolver : NSObject
+ (instancetype)sharedResolver;
- (NSArray<NSDictionary<NSString *, id> *> * _Nullable)resolveRVA:(uint64_t)rva
                                                            limit:(NSUInteger)limit
                                                            error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
