#import <Foundation/Foundation.h>
#import "ZNIL2CPPInstanceResolver.h"

NS_ASSUME_NONNULL_BEGIN

@interface ZNIL2CPPInstanceResolver (ZNInstanceSelectionV2)
- (uintptr_t)znm44_selectedInstanceForAssembly:(NSString *)assembly
                                     namespace:(NSString *)namespaceName
                                     className:(NSString *)className;
- (BOOL)znm44_selectInstanceAddress:(uintptr_t)address
                           assembly:(NSString *)assembly
                          namespace:(NSString *)namespaceName
                          className:(NSString *)className
                              error:(NSString * _Nullable * _Nullable)error;
- (void)znm44_clearSelectedInstanceForAssembly:(NSString *)assembly
                                      namespace:(NSString *)namespaceName
                                      className:(NSString *)className;
- (BOOL)znm44_validateInstanceAddress:(uintptr_t)address
                             assembly:(NSString *)assembly
                            namespace:(NSString *)namespaceName
                            className:(NSString *)className
                                error:(NSString * _Nullable * _Nullable)error;
@end

extern "C" void ZNInstallIL2CPPInstanceSelectionV2Deferred(void);

NS_ASSUME_NONNULL_END
