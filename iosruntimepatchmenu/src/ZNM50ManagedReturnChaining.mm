#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#import "ZNIL2CPPInstanceSelectionV2.h"
#import "ZNIL2CPPInvokeEngine.h"
#import "ZNIL2CPPResolver.h"
#import "ZNRuntimeActionModel.h"
#import "ZNPatchCore.h"

typedef uintptr_t ZNM50GCHandle;
typedef ZNM50GCHandle (*ZNM50GCHandleNewFn)(void *object, bool pinned);
typedef void *(*ZNM50GCHandleGetTargetFn)(ZNM50GCHandle handle);
typedef void (*ZNM50GCHandleFreeFn)(ZNM50GCHandle handle);

@interface ZNM50ManagedReturnState : NSObject
@property(nonatomic,assign) ZNM50GCHandle handle;
@property(nonatomic,assign) uintptr_t fallbackAddress;
@property(nonatomic,copy) NSString *typeName;
@property(nonatomic,assign) uint64_t generation;
@end
@implementation ZNM50ManagedReturnState
@end

static ZNM50ManagedReturnState *gZNM50State = nil;
static uint64_t gZNM50Generation = 0;

static void *ZNM50Symbol(NSString *path, const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p || !path.length) return p;
#ifdef RTLD_NOLOAD
    void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
#else
    void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY);
#endif
    return h ? dlsym(h, name) : NULL;
}

static BOOL ZNM50GCAPI(ZNM50GCHandleNewFn *newFn,
                       ZNM50GCHandleGetTargetFn *getFn,
                       ZNM50GCHandleFreeFn *freeFn) {
    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    NSString *path = resolver.unityPath ?: @"";
    ZNM50GCHandleNewFn n = (ZNM50GCHandleNewFn)ZNM50Symbol(path, "il2cpp_gchandle_new");
    ZNM50GCHandleGetTargetFn g = (ZNM50GCHandleGetTargetFn)ZNM50Symbol(path, "il2cpp_gchandle_get_target");
    ZNM50GCHandleFreeFn f = (ZNM50GCHandleFreeFn)ZNM50Symbol(path, "il2cpp_gchandle_free");
    if (newFn) *newFn = n;
    if (getFn) *getFn = g;
    if (freeFn) *freeFn = f;
    return n && g && f;
}

static void ZNM50ReleaseState(ZNM50ManagedReturnState *state) {
    if (!state || !state.handle) return;
    ZNM50GCHandleFreeFn freeFn = NULL;
    if (ZNM50GCAPI(NULL, NULL, &freeFn) && freeFn) freeFn(state.handle);
}

static uintptr_t ZNM50CurrentManagedReturn(void) {
    ZNM50ManagedReturnState *state = nil;
    @synchronized (ZNIL2CPPInvokeEngine.class) { state = gZNM50State; }
    if (!state) return 0;
    if (!state.handle) return state.fallbackAddress;
    ZNM50GCHandleGetTargetFn getFn = NULL;
    if (!ZNM50GCAPI(NULL, &getFn, NULL) || !getFn) return 0;
    return (uintptr_t)getFn(state.handle);
}

static void ZNM50CaptureManagedReturn(uintptr_t object, NSString *typeName) {
    if (!object) return;
    ZNM50ManagedReturnState *next = [ZNM50ManagedReturnState new];
    next.typeName = typeName ?: @"?";
    next.generation = ++gZNM50Generation;

    ZNM50GCHandleNewFn newFn = NULL;
    ZNM50GCHandleGetTargetFn getFn = NULL;
    ZNM50GCHandleFreeFn freeFn = NULL;
    if (ZNM50GCAPI(&newFn, &getFn, &freeFn)) {
        ZNM50GCHandle handle = newFn((void *)object, false);
        if (handle && getFn(handle)) next.handle = handle;
        else if (handle && freeFn) freeFn(handle);
    }
    if (!next.handle) next.fallbackAddress = object;

    ZNM50ManagedReturnState *old = nil;
    @synchronized (ZNIL2CPPInvokeEngine.class) {
        old = gZNM50State;
        gZNM50State = next;
    }
    ZNM50ReleaseState(old);
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m5.0-chain] captured generation=%llu type=%@ object=0x%llX lifetime=%@",
                                         (unsigned long long)next.generation,
                                         next.typeName,
                                         (unsigned long long)object,
                                         next.handle ? @"gchandle" : @"raw-fallback"]];
}

@interface ZNIL2CPPInvokeEngine (ZNM50ManagedReturnChaining)
- (NSDictionary<NSString *,id> *)znm50_executeAction:(ZNRuntimeMethodAction *)action error:(NSString **)error;
@end

@implementation ZNIL2CPPInvokeEngine (ZNM50ManagedReturnChaining)

- (NSDictionary<NSString *,id> *)znm50_executeAction:(ZNRuntimeMethodAction *)action error:(NSString **)error {
    ZNIL2CPPInstanceResolver *resolver = [ZNIL2CPPInstanceResolver sharedResolver];
    uintptr_t chain = ZNM50CurrentManagedReturn();
    uintptr_t previous = 0;
    ZNM50GCHandle previousKeepAlive = 0;
    ZNM50GCHandleGetTargetFn getFn = NULL;
    ZNM50GCHandleFreeFn freeFn = NULL;
    BOOL injected = NO;

    if (chain && action.className.length) {
        NSString *validation = nil;
        if ([resolver znm44_validateInstanceAddress:chain
                                          assembly:action.assembly ?: @""
                                         namespace:action.namespaceName ?: @""
                                         className:action.className
                                             error:&validation]) {
            previous = [resolver znm44_selectedInstanceForAssembly:action.assembly ?: @""
                                                          namespace:action.namespaceName ?: @""
                                                          className:action.className];

            if (previous && previous != chain) {
                ZNM50GCHandleNewFn newFn = NULL;
                if (ZNM50GCAPI(&newFn, &getFn, &freeFn) && newFn) {
                    previousKeepAlive = newFn((void *)previous, false);
                    if (previousKeepAlive && !getFn(previousKeepAlive)) {
                        freeFn(previousKeepAlive);
                        previousKeepAlive = 0;
                    }
                }
            }

            NSString *selectError = nil;
            injected = [resolver znm44_selectInstanceAddress:chain
                                                    assembly:action.assembly ?: @""
                                                   namespace:action.namespaceName ?: @""
                                                   className:action.className
                                                       error:&selectError];
            if (injected) {
                [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m5.0-chain] receiver injected %@ -> 0x%llX",
                                                     action.canonicalIdentity ?: @"",
                                                     (unsigned long long)chain]];
            }
        }
    }

    NSDictionary *result = [self znm50_executeAction:action error:error];

    if (injected) {
        uintptr_t restoreAddress = previous;
        if (previousKeepAlive && getFn) {
            restoreAddress = (uintptr_t)getFn(previousKeepAlive);
        }
        if (restoreAddress && restoreAddress != chain) {
            NSString *restoreError = nil;
            [resolver znm44_selectInstanceAddress:restoreAddress
                                         assembly:action.assembly ?: @""
                                        namespace:action.namespaceName ?: @""
                                        className:action.className
                                            error:&restoreError];
        } else if (!previous) {
            [resolver znm44_clearSelectedInstanceForAssembly:action.assembly ?: @""
                                                    namespace:action.namespaceName ?: @""
                                                    className:action.className];
        }
    }
    if (previousKeepAlive && freeFn) freeFn(previousKeepAlive);

    if (result) {
        NSString *kind = [result[@"returnKind"] isKindOfClass:NSString.class] ? result[@"returnKind"] : @"";
        uintptr_t raw = [result[@"returnRawObject"] respondsToSelector:@selector(unsignedLongLongValue)] ? [result[@"returnRawObject"] unsignedLongLongValue] : 0;
        NSString *type = [result[@"returnType"] isKindOfClass:NSString.class] ? result[@"returnType"] : @"?";
        if (raw && [kind containsString:@"managed reference"]) {
            ZNM50CaptureManagedReturn(raw, type);
            NSMutableDictionary *merged = [result mutableCopy];
            merged[@"managedReturnChained"] = @YES;
            merged[@"managedReturnGeneration"] = @(gZNM50Generation);
            return [merged copy];
        }
    }
    return result;
}

@end

extern "C" void ZNInstallM50ManagedReturnChainingDeferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method a = class_getInstanceMethod(ZNIL2CPPInvokeEngine.class, @selector(executeAction:error:));
        Method b = class_getInstanceMethod(ZNIL2CPPInvokeEngine.class, @selector(znm50_executeAction:error:));
        if (a && b) method_exchangeImplementations(a, b);
        [[ZNRuntimeLogger sharedLogger] log:@"[m5.0-chain] Managed-reference Return Chaining installed"];
    });
}
