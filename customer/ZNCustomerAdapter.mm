#import "ZNCustomerAdapter.h"
@implementation ZNCustomerItem
@end

// The customer is deliberately fail-closed until the original ZN44 / ZNACTN1
// backends have been linked and audited. Do not falsely report execution.
@implementation ZNCustomerAdapter
+ (instancetype)shared {
    static ZNCustomerAdapter *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [ZNCustomerAdapter new]; });
    return instance;
}
- (NSArray<ZNCustomerItem *> *)snapshot { return @[]; }
- (BOOL)setEnabled:(BOOL)enabled identifier:(NSString *)identifier error:(NSString **)error {
    (void)enabled; (void)identifier;
    if(error) *error = @"Customer 执行适配器尚未接入，禁止修改目标进程";
    return NO;
}
- (BOOL)execute:(NSString *)identifier value:(NSNumber *)value error:(NSString **)error {
    (void)identifier; (void)value;
    if(error) *error = @"Customer 执行适配器尚未接入，禁止调用目标方法";
    return NO;
}
@end
