#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface ZNPatchJSONImporter : NSObject
+ (NSArray<NSString *> *)discoverJSONFiles;
+ (NSString *)discoveryStatus;
+ (nullable NSArray<NSDictionary *> *)importFile:(NSString *)path error:(NSString * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
