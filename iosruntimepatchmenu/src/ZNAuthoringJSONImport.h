#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface ZNAuthoringJSONImport : NSObject
// Portable schema: format=zonoe-authoring; export v2 includes offsetPatches,
// offsetDefaultTarget, runtimeMethods and nativeHooks. Import accepts v1/v2.
// Legacy Patch JSON continues through the original importer.
+ (BOOL)isAuthoringConfiguration:(id)root;
// Portable authoring only: Offset keeps its authored RVA; no captured original,
// prepared validators, runtime address, UUID or trampoline is exported.
+ (nullable NSData *)exportDataWithError:(NSString * _Nullable * _Nullable)error;
+ (BOOL)importData:(NSData *)data status:(NSString * _Nullable * _Nullable)status error:(NSString * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
