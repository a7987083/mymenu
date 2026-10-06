#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ZNIL2CPPInstanceSelectionV2.h"
#import "ZNIL2CPPResolver.h"
#import "ZNIL2CPPRuntimeCommon.h"
#import "ZNPatchCore.h"

// M4.6.2 receiver stability layer.
//
// IL2CPP used uint32_t GCHandle values in older releases and pointer-sized
// Il2CppGCHandle values in newer releases. On arm64 a uintptr_t declaration is
// ABI-compatible with both exported forms: old W0 returns are zero-extended,
// while newer X0 pointer handles are preserved. We intentionally create a
// strong, non-pinned handle. The handle keeps the managed object alive while
// get_target returns the current object address if a moving collector is used.
typedef uintptr_t ZNM462GCHandle;
typedef ZNM462GCHandle (*ZNM462GCHandleNewFn)(void *object, bool pinned);
typedef void *(*ZNM462GCHandleGetTargetFn)(ZNM462GCHandle handle);
typedef void (*ZNM462GCHandleFreeFn)(ZNM462GCHandle handle);

@interface ZNM462Selection : NSObject
@property(nonatomic,assign) BOOL handleBacked;
@property(nonatomic,assign) ZNM462GCHandle handle;
@property(nonatomic,assign) uintptr_t fallbackAddress;
@end
@implementation ZNM462Selection
@end

static NSMutableDictionary<NSString *, ZNM462Selection *> *ZNM462Store(void) {
    static NSMutableDictionary<NSString *, ZNM462Selection *> *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [NSMutableDictionary dictionary]; });
    return store;
}

static BOOL ZNM462GCAPI(ZNM462GCHandleNewFn *newFn,
                        ZNM462GCHandleGetTargetFn *getFn,
                        ZNM462GCHandleFreeFn *freeFn) {
    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    NSString *path = resolver.unityPath ?: @"";
    ZNM462GCHandleNewFn n = (ZNM462GCHandleNewFn)ZNIL2CPPResolveSymbol(path, "il2cpp_gchandle_new");
    ZNM462GCHandleGetTargetFn g = (ZNM462GCHandleGetTargetFn)ZNIL2CPPResolveSymbol(path, "il2cpp_gchandle_get_target");
    ZNM462GCHandleFreeFn f = (ZNM462GCHandleFreeFn)ZNIL2CPPResolveSymbol(path, "il2cpp_gchandle_free");
    if (newFn) *newFn = n;
    if (getFn) *getFn = g;
    if (freeFn) *freeFn = f;
    return n && g && f;
}

static void ZNM462ReleaseSelection(ZNM462Selection *selection) {
    if (!selection || !selection.handleBacked || !selection.handle) return;
    ZNM462GCHandleFreeFn freeFn = NULL;
    if (ZNM462GCAPI(NULL, NULL, &freeFn) && freeFn) {
        freeFn(selection.handle);
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[instance-selection-v3] freed gchandle=0x%llX",
                                             (unsigned long long)selection.handle]];
    } else {
        [[ZNRuntimeLogger sharedLogger] log:@"[instance-selection-v3] gchandle_free unavailable during release; process-lifetime leak only"];
    }
}

@interface ZNIL2CPPInstanceResolver (ZNM462InstanceSafety)
- (uintptr_t)znm462_selectedInstanceForAssembly:(NSString *)assembly
                                       namespace:(NSString *)namespaceName
                                       className:(NSString *)className;
- (BOOL)znm462_selectInstanceAddress:(uintptr_t)address
                             assembly:(NSString *)assembly
                            namespace:(NSString *)namespaceName
                            className:(NSString *)className
                                error:(NSString * _Nullable * _Nullable)error;
- (void)znm462_clearSelectedInstanceForAssembly:(NSString *)assembly
                                        namespace:(NSString *)namespaceName
                                        className:(NSString *)className;
@end

@implementation ZNIL2CPPInstanceResolver (ZNM462InstanceSafety)

- (uintptr_t)znm462_selectedInstanceForAssembly:(NSString *)assembly
                                       namespace:(NSString *)namespaceName
                                       className:(NSString *)className {
    NSString *key = ZNIL2CPPConservativeInstanceKey(assembly, namespaceName, className);
    __block ZNM462Selection *selection = nil;
    @synchronized (ZNM462Store()) {
        selection = ZNM462Store()[key];
    }
    if (!selection) return 0;
    if (!selection.handleBacked) return selection.fallbackAddress;

    ZNM462GCHandleGetTargetFn getFn = NULL;
    if (!ZNM462GCAPI(NULL, &getFn, NULL) || !getFn) {
        [self znm44_clearSelectedInstanceForAssembly:assembly namespace:namespaceName className:className];
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[instance-selection-v3] target API disappeared; cleared %@", key]];
        return 0;
    }
    void *target = getFn(selection.handle);
    if (!target) {
        [self znm44_clearSelectedInstanceForAssembly:assembly namespace:namespaceName className:className];
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[instance-selection-v3] null gchandle target; cleared %@", key]];
        return 0;
    }
    return (uintptr_t)target;
}

- (BOOL)znm462_selectInstanceAddress:(uintptr_t)address
                             assembly:(NSString *)assembly
                            namespace:(NSString *)namespaceName
                            className:(NSString *)className
                                error:(NSString * _Nullable * _Nullable)error {
    NSString *validationError = nil;
    if (![self znm44_validateInstanceAddress:address
                                    assembly:assembly
                                   namespace:namespaceName
                                   className:className
                                       error:&validationError]) {
        if (error) *error = validationError ?: @"M4.6.2 receiver validation failed";
        return NO;
    }

    ZNM462Selection *selection = [ZNM462Selection new];
    ZNM462GCHandleNewFn newFn = NULL;
    ZNM462GCHandleGetTargetFn getFn = NULL;
    ZNM462GCHandleFreeFn freeFn = NULL;
    BOOL hasGCHandle = ZNM462GCAPI(&newFn, &getFn, &freeFn);
    if (hasGCHandle) {
        ZNM462GCHandle handle = newFn((void *)address, false);
        if (!handle) {
            if (error) *error = @"M4.6.2 il2cpp_gchandle_new 返回空句柄";
            return NO;
        }
        void *target = getFn(handle);
        if (!target) {
            freeFn(handle);
            if (error) *error = @"M4.6.2 GCHandle 创建后无法取得 target";
            return NO;
        }
        NSString *targetValidationError = nil;
        if (![self znm44_validateInstanceAddress:(uintptr_t)target
                                        assembly:assembly
                                       namespace:namespaceName
                                       className:className
                                           error:&targetValidationError]) {
            freeFn(handle);
            if (error) *error = targetValidationError ?: @"M4.6.2 GCHandle target 类型验证失败";
            return NO;
        }
        selection.handleBacked = YES;
        selection.handle = handle;
        selection.fallbackAddress = 0;
    } else {
        // Some stripped/older games do not export all three GCHandle APIs. Keep
        // the device-proven M4.4 behavior as a compatibility fallback rather
        // than disabling instance execution globally.
        selection.handleBacked = NO;
        selection.handle = 0;
        selection.fallbackAddress = address;
    }

    NSString *key = ZNIL2CPPConservativeInstanceKey(assembly, namespaceName, className);
    ZNM462Selection *previous = nil;
    @synchronized (ZNM462Store()) {
        previous = ZNM462Store()[key];
        ZNM462Store()[key] = selection;
    }
    ZNM462ReleaseSelection(previous);

    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[instance-selection-v3] selected %@ -> %@ 0x%llX",
                                         key,
                                         selection.handleBacked ? @"gchandle" : @"raw-fallback",
                                         (unsigned long long)(selection.handleBacked ? selection.handle : selection.fallbackAddress)]];
    if (error) *error = nil;
    return YES;
}

- (void)znm462_clearSelectedInstanceForAssembly:(NSString *)assembly
                                        namespace:(NSString *)namespaceName
                                        className:(NSString *)className {
    NSString *key = ZNIL2CPPConservativeInstanceKey(assembly, namespaceName, className);
    ZNM462Selection *selection = nil;
    @synchronized (ZNM462Store()) {
        selection = ZNM462Store()[key];
        [ZNM462Store() removeObjectForKey:key];
    }
    ZNM462ReleaseSelection(selection);
}

@end

static void ZNM462Swap(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

extern "C" void ZNInstallM462InstanceSafetyDeferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = ZNIL2CPPInstanceResolver.class;
        ZNM462Swap(cls,
                   @selector(znm44_selectedInstanceForAssembly:namespace:className:),
                   @selector(znm462_selectedInstanceForAssembly:namespace:className:));
        ZNM462Swap(cls,
                   @selector(znm44_selectInstanceAddress:assembly:namespace:className:error:),
                   @selector(znm462_selectInstanceAddress:assembly:namespace:className:error:));
        ZNM462Swap(cls,
                   @selector(znm44_clearSelectedInstanceForAssembly:namespace:className:),
                   @selector(znm462_clearSelectedInstanceForAssembly:namespace:className:));
        [[ZNRuntimeLogger sharedLogger] log:@"[instance-selection-v3] GCHandle receiver lifetime layer installed"];
    });
}
