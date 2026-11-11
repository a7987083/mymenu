#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface ZNAuthoringJSONImport : NSObject
// Strict schema: format=zonoe-authoring, schemaVersion=1,
// runtimeMethods/nativeHooks arrays. Legacy Patch JSON goes to the old importer.
+ (BOOL)isAuthoringConfiguration:(id)root;
+ (BOOL)importData:(NSData *)data status:(NSString * _Nullable * _Nullable)status error:(NSString * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
