#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../iosruntimepatchmenu/src/ZNIL2CPPInstanceResolver.h"
#import "../iosruntimepatchmenu/src/ZNIL2CPPInstanceSelectionV2.h"

// Customer-only receiver lifecycle. Do not link or initialize the Developer UI.
extern "C" void ZNInstallM462InstanceSafetyDeferred(void);

@interface ZNIL2CPPInstanceResolver (ZNCustomerReceiverLifecycle)
- (void *)zncustomer_resolveInstanceForAssembly:(NSString *)assembly
                                      namespace:(NSString *)namespaceName
                                      className:(NSString *)className
                                    diagnostics:(NSString **)diagnostics
                                          error:(NSString **)error;
@end

@implementation ZNIL2CPPInstanceResolver (ZNCustomerReceiverLifecycle)
- (void *)zncustomer_resolveInstanceForAssembly:(NSString *)assembly
                                      namespace:(NSString *)namespaceName
                                      className:(NSString *)className
                                    diagnostics:(NSString **)diagnostics
                                          error:(NSString **)error {
    // The V2 resolver returns a validated selected session receiver first.
    // A newly discovered unique instance must also be retained: otherwise
    // adding a second same-class object makes the next call ambiguous.
    void *receiver=[self zncustomer_resolveInstanceForAssembly:assembly
                                                    namespace:namespaceName
                                                    className:className
                                                  diagnostics:diagnostics
                                                        error:error];
    if (!receiver) return NULL;

    uintptr_t selected=[self znm44_selectedInstanceForAssembly:assembly
                                                     namespace:namespaceName
                                                     className:className];
    if (selected) return receiver;

    NSString *selectionError=nil;
    if ([self znm44_selectInstanceAddress:(uintptr_t)receiver
                                 assembly:assembly
                                namespace:namespaceName
                                className:className
                                    error:&selectionError]) {
        // A GCHandle-backed target can differ from the original object address.
        uintptr_t target=[self znm44_selectedInstanceForAssembly:assembly
                                                       namespace:namespaceName
                                                       className:className];
        if (target) {
            if (diagnostics) *diagnostics=[NSString stringWithFormat:
                @"customer-auto-bound 0x%llX", (unsigned long long)target];
            if (error) *error=nil;
            return (void *)target;
        }
    }
    // Preserve single-instance behavior when the optional binding fails.
    // Never choose an address from an ambiguous multi-instance result.
    if (diagnostics) *diagnostics=[NSString stringWithFormat:
        @"unique-unbound (%@)",selectionError?:@"target unavailable"];
    if (error) *error=nil;
    return receiver;
}
@end

extern "C" void ZNCustomerInstallReceiverLifecycle(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        ZNInstallIL2CPPInstanceSelectionV2Deferred();
        ZNInstallM462InstanceSafetyDeferred();
        Class cls=ZNIL2CPPInstanceResolver.class;
        Method original=class_getInstanceMethod(cls,
            @selector(resolveUniqueInstanceForAssembly:namespace:className:diagnostics:error:));
        Method replacement=class_getInstanceMethod(cls,
            @selector(zncustomer_resolveInstanceForAssembly:namespace:className:diagnostics:error:));
        if(original && replacement) method_exchangeImplementations(original,replacement);
    });
}
