#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Display-only developer Method Finder translation. Never changes candidate identity.
@interface ZNMethodTranslator : NSObject
+ (nullable NSString *)translateMethodName:(NSString *)methodName;
@end
NS_ASSUME_NONNULL_END
