#import <Foundation/Foundation.h>
@class ZNBinaryPatchWorkspace;

NS_ASSUME_NONNULL_BEGIN
@interface ZNStaticBinaryBuilder : NSObject
+ (BOOL)buildWorkspace:(ZNBinaryPatchWorkspace *)workspace
               outputs:(NSArray<NSString *> * _Nullable * _Nullable)outputs
                report:(NSString * _Nullable * _Nullable)report
                 error:(NSString * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
