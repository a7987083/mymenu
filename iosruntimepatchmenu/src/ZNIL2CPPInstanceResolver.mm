#import "ZNIL2CPPInstanceResolver.h"
#import "ZNIL2CPPResolver.h"
#import "ZNPatchCore.h"
#import <dlfcn.h>
#include <stdlib.h>

// M4.3 Instance Resolver V1
// - Prefer the legacy begin/end liveness path when Unity exports it.
// - Fall back to allocate/finalize/free with GC world stop/start sequencing.
// - Never guess when zero or multiple instances are returned.

typedef void *(*ZNIRObjectGetClassFn)(void *);
typedef bool (*ZNIRClassIsAssignableFromFn)(void *, void *);
typedef void (*ZNIRRegisterObjectCallback)(void **objects, int count, void *userdata);
typedef void (*ZNIRWorldChangedCallback)(void);
typedef void *(*ZNIRLivenessBeginFn)(void *filter, int maxObjectCount, ZNIRRegisterObjectCallback callback, void *userdata, ZNIRWorldChangedCallback onWorldStarted, ZNIRWorldChangedCallback onWorldStopped);
typedef void (*ZNIRLivenessEndFn)(void *state);
typedef void (*ZNIRLivenessFromStaticsFn)(void *state);
typedef void *(*ZNIRLivenessReallocateCallback)(void *ptr, size_t size, void *userdata);
typedef void *(*ZNIRLivenessAllocateStructFn)(void *filter, int maxObjectCount, ZNIRRegisterObjectCallback callback, void *userdata, ZNIRLivenessReallocateCallback reallocCallback);
typedef void (*ZNIRLivenessFinalizeFn)(void *state);
typedef void (*ZNIRLivenessFreeStructFn)(void *state);
typedef void (*ZNIRGCWorldFn)(void);

typedef struct {
    __unsafe_unretained NSMutableArray<NSNumber *> *items;
    NSUInteger limit;
} ZNIRCallbackContext;

static NSString *ZNIRTrim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static void *ZNIRResolveSymbol(NSString *unityPath, const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p || !unityPath.length) return p;
#ifdef RTLD_NOLOAD
    void *handle = dlopen(unityPath.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
#else
    void *handle = dlopen(unityPath.fileSystemRepresentation, RTLD_LAZY);
#endif
    return handle ? dlsym(handle, name) : NULL;
}

static void ZNIRCollectObjects(void **objects, int count, void *userdata) {
    if (!objects || count <= 0 || !userdata) return;
    ZNIRCallbackContext *ctx = (ZNIRCallbackContext *)userdata;
    NSMutableArray<NSNumber *> *items = ctx->items;
    if (!items) return;
    for (int i = 0; i < count && items.count < ctx->limit; i++) {
        uintptr_t address = (uintptr_t)objects[i];
        if (!address) continue;
        NSNumber *boxed = @(address);
        if (![items containsObject:boxed]) [items addObject:boxed];
    }
}

static void ZNIRWorldChanged(void) {
}

static void *ZNIRReallocate(void *ptr, size_t size, void *userdata) {
    (void)userdata;
    if (size == 0) {
        free(ptr);
        return NULL;
    }
    return realloc(ptr, size);
}

@implementation ZNIL2CPPInstanceResolver

+ (instancetype)sharedResolver {
    static ZNIL2CPPInstanceResolver *resolver;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ resolver = [ZNIL2CPPInstanceResolver new]; });
    return resolver;
}

- (NSDictionary<NSString *,id> *)capabilities {
    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    NSString *path = resolver.unityPath ?: @"";
    BOOL legacy = ZNIRResolveSymbol(path, "il2cpp_unity_liveness_calculation_begin") &&
                  ZNIRResolveSymbol(path, "il2cpp_unity_liveness_calculation_from_statics") &&
                  ZNIRResolveSymbol(path, "il2cpp_unity_liveness_calculation_end");
    BOOL modernCore = ZNIRResolveSymbol(path, "il2cpp_unity_liveness_allocate_struct") &&
                      ZNIRResolveSymbol(path, "il2cpp_unity_liveness_calculation_from_statics") &&
                      ZNIRResolveSymbol(path, "il2cpp_unity_liveness_finalize") &&
                      ZNIRResolveSymbol(path, "il2cpp_unity_liveness_free_struct");
    BOOL worldControl = ZNIRResolveSymbol(path, "il2cpp_stop_gc_world") &&
                        ZNIRResolveSymbol(path, "il2cpp_start_gc_world");
    BOOL modern = modernCore && worldControl;
    return @{
        @"resolver": @(resolver.isAvailable),
        @"legacyLiveness": @(legacy),
        @"modernLiveness": @(modern),
        @"gcWorldControl": @(worldControl),
        @"available": @(resolver.isAvailable && (legacy || modern)),
    };
}

- (NSArray<NSNumber *> *)candidateAddressesForAssembly:(NSString *)assembly
                                             namespace:(NSString *)namespaceName
                                             className:(NSString *)className
                                                 limit:(NSUInteger)limit
                                           diagnostics:(NSString **)diagnostics
                                                 error:(NSString **)error {
    limit = MAX((NSUInteger)1, MIN(limit ?: 32, (NSUInteger)128));
    NSString *wantedClass = ZNIRTrim(className);
    if (!wantedClass.length) {
        if (error) *error = @"FAILED_INSTANCE_CLASS：Class 为空";
        return @[];
    }

    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    if (!resolver.isAvailable) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_INSTANCE_RESOLVER：%@", resolver.lastError ?: @"IL2CPP unavailable"];
        return @[];
    }
    NSString *unityPath = resolver.unityPath ?: @"";
    NSDictionary<NSString *, id> *resolvedClass = [resolver resolveClassAssembly:assembly
                                                                         namespace:namespaceName ?: @""
                                                                         className:wantedClass];
    if (!resolvedClass) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_INSTANCE_CLASS：%@", resolver.lastError ?: @"无法解析目标类"];
        return @[];
    }
    void *targetClass = (void *)(uintptr_t)[resolvedClass[@"class"] unsignedLongLongValue];
    NSString *resolvedAssembly = assembly ?: @"";
    NSString *wantedNamespace = namespaceName ?: @"";

    ZNIRLivenessFromStaticsFn fromStatics = (ZNIRLivenessFromStaticsFn)ZNIRResolveSymbol(unityPath, "il2cpp_unity_liveness_calculation_from_statics");
    ZNIRLivenessAllocateStructFn allocateStruct = (ZNIRLivenessAllocateStructFn)ZNIRResolveSymbol(unityPath, "il2cpp_unity_liveness_allocate_struct");
    ZNIRLivenessFinalizeFn finalize = (ZNIRLivenessFinalizeFn)ZNIRResolveSymbol(unityPath, "il2cpp_unity_liveness_finalize");
    ZNIRLivenessFreeStructFn freeStruct = (ZNIRLivenessFreeStructFn)ZNIRResolveSymbol(unityPath, "il2cpp_unity_liveness_free_struct");
    ZNIRLivenessBeginFn begin = (ZNIRLivenessBeginFn)ZNIRResolveSymbol(unityPath, "il2cpp_unity_liveness_calculation_begin");
    ZNIRLivenessEndFn end = (ZNIRLivenessEndFn)ZNIRResolveSymbol(unityPath, "il2cpp_unity_liveness_calculation_end");
    ZNIRGCWorldFn stopWorld = (ZNIRGCWorldFn)ZNIRResolveSymbol(unityPath, "il2cpp_stop_gc_world");
    ZNIRGCWorldFn startWorld = (ZNIRGCWorldFn)ZNIRResolveSymbol(unityPath, "il2cpp_start_gc_world");

    BOOL legacy = fromStatics && begin && end;
    BOOL modern = fromStatics && allocateStruct && finalize && freeStruct && stopWorld && startWorld;
    if (!legacy && !modern) {
        if (error) *error = @"FAILED_INSTANCE_LIVENESS：当前 Unity 没有可安全使用的 liveness API";
        return @[];
    }

    NSMutableArray<NSNumber *> *items = [NSMutableArray array];
    ZNIRCallbackContext context = { items, limit };
    NSString *mode = @"legacy";

    if (legacy) {
        void *state = begin(targetClass, 0, ZNIRCollectObjects, &context, ZNIRWorldChanged, ZNIRWorldChanged);
        if (!state) {
            if (error) *error = @"FAILED_INSTANCE_LIVENESS：calculation_begin 返回 NULL";
            return @[];
        }
        fromStatics(state);
        end(state);
    } else {
        mode = @"modern";
        stopWorld();
        void *state = allocateStruct(targetClass, 0, ZNIRCollectObjects, &context, ZNIRReallocate);
        if (!state) {
            startWorld();
            if (error) *error = @"FAILED_INSTANCE_LIVENESS：allocate_struct 返回 NULL";
            return @[];
        }
        fromStatics(state);
        finalize(state);
        startWorld();
        freeStruct(state);
    }

    ZNIRObjectGetClassFn objectGetClass = (ZNIRObjectGetClassFn)ZNIRResolveSymbol(unityPath, "il2cpp_object_get_class");
    ZNIRClassIsAssignableFromFn assignable = (ZNIRClassIsAssignableFromFn)ZNIRResolveSymbol(unityPath, "il2cpp_class_is_assignable_from");
    if (objectGetClass && assignable && items.count) {
        NSMutableArray<NSNumber *> *verified = [NSMutableArray arrayWithCapacity:items.count];
        for (NSNumber *boxed in items) {
            void *object = (void *)(uintptr_t)boxed.unsignedLongLongValue;
            void *actual = object ? objectGetClass(object) : NULL;
            if (actual && assignable(targetClass, actual)) [verified addObject:boxed];
        }
        items = verified;
    }

    NSString *diag = [NSString stringWithFormat:@"%@ liveness · %@!%@.%@ · %lu instance(s)",
                      mode,
                      resolvedAssembly.length ? resolvedAssembly : assembly ?: @"",
                      wantedNamespace,
                      wantedClass,
                      (unsigned long)items.count];
    if (diagnostics) *diagnostics = diag;
    [[ZNRuntimeLogger sharedLogger] log:[@"[instance-resolver] " stringByAppendingString:diag]];
    if (error) *error = nil;
    return [items copy];
}

- (void *)resolveUniqueInstanceForAssembly:(NSString *)assembly
                                 namespace:(NSString *)namespaceName
                                 className:(NSString *)className
                               diagnostics:(NSString **)diagnostics
                                     error:(NSString **)error {
    NSString *diag = nil;
    NSString *innerError = nil;
    NSArray<NSNumber *> *items = [self candidateAddressesForAssembly:assembly
                                                            namespace:namespaceName
                                                            className:className
                                                                limit:64
                                                          diagnostics:&diag
                                                                error:&innerError];
    if (diagnostics) *diagnostics = diag;
    if (!items.count) {
        if (error) *error = innerError ?: [NSString stringWithFormat:@"FAILED_INSTANCE_NOT_FOUND：%@.%@ 没有活实例", namespaceName ?: @"", className ?: @""];
        return NULL;
    }
    if (items.count != 1) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_INSTANCE_AMBIGUOUS：发现 %lu 个 %@ 实例；M4.3 V1 不猜测选择", (unsigned long)items.count, className ?: @"object"];
        return NULL;
    }
    if (error) *error = nil;
    return (void *)(uintptr_t)items.firstObject.unsignedLongLongValue;
}

@end
