#import <Foundation/Foundation.h>
#import "ZNM47DobbyCompat.h"

NS_ASSUME_NONNULL_BEGIN

@interface ZNNativeHookBackend : NSObject
+ (instancetype)sharedBackend;

- (BOOL)installInstrumentAtAddress:(uintptr_t)address
                          callback:(ZNM47DobbyInstrumentCallback)callback
                             error:(NSString * _Nullable * _Nullable)error;

- (BOOL)installReplacementAtAddress:(uintptr_t)address
                        replacement:(void *)replacement
                           original:(void * _Nullable * _Nullable)original
                              error:(NSString * _Nullable * _Nullable)error;

- (BOOL)destroyHookAtAddress:(uintptr_t)address
                       error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
