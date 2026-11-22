#import "ZNIL2CPPInstanceResolver.h"
#import "ZNIL2CPPResolver.h"
#import "ZNPatchCore.h"
#import <dlfcn.h>
#include <stdlib.h>
#include <string.h>

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


typedef void *(*ZNIRClassGetParentFn)(void *);
typedef const char *(*ZNIRClassGetNameFn)(void *);
typedef const void *(*ZNIRGetMethodFn)(void *, const char *, int);
typedef uint32_t (*ZNIRMethodGetFlagsFn)(const void *, uint32_t *);
typedef void *(*ZNIRRuntimeInvokeFn)(const void *, void *, void **, void **);
typedef void *(*ZNIRThreadCurrentFn)(void);
typedef void *(*ZNIRThreadAttachFn)(void *);

static void *ZNIRPersistentSingleton(NSString *assembly, NSString *ns, NSString *className,
                                     NSString **diagnostics, NSString **error) {
    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    NSDictionary *info = [resolver resolveClassAssembly:assembly namespace:ns ?: @"" className:className];
    void *klass = (void *)(uintptr_t)[info[@"class"] unsignedLongLongValue];
    if (!klass) {
        if(error)*error=@"FAILED_SINGLETON_CLASS：无法解析类";
        return NULL;
    }
    NSString *path=resolver.unityPath ?: @"";
    ZNIRClassGetParentFn parentFn=(ZNIRClassGetParentFn)ZNIRResolveSymbol(path,"il2cpp_class_get_parent");
    ZNIRClassGetNameFn nameFn=(ZNIRClassGetNameFn)ZNIRResolveSymbol(path,"il2cpp_class_get_name");
    ZNIRGetMethodFn getMethod=(ZNIRGetMethodFn)ZNIRResolveSymbol(path,"il2cpp_class_get_method_from_name");
    ZNIRMethodGetFlagsFn flagsFn=(ZNIRMethodGetFlagsFn)ZNIRResolveSymbol(path,"il2cpp_method_get_flags");
    ZNIRRuntimeInvokeFn invoke=(ZNIRRuntimeInvokeFn)ZNIRResolveSymbol(path,"il2cpp_runtime_invoke");
    ZNIRObjectGetClassFn objectClass=(ZNIRObjectGetClassFn)ZNIRResolveSymbol(path,"il2cpp_object_get_class");
    ZNIRClassIsAssignableFromFn assignable=(ZNIRClassIsAssignableFromFn)ZNIRResolveSymbol(path,"il2cpp_class_is_assignable_from");
    void *(*domainGet)(void)=(void *(*)(void))ZNIRResolveSymbol(path,"il2cpp_domain_get");
    ZNIRThreadCurrentFn threadCurrent=(ZNIRThreadCurrentFn)ZNIRResolveSymbol(path,"il2cpp_thread_current");
    ZNIRThreadAttachFn threadAttach=(ZNIRThreadAttachFn)ZNIRResolveSymbol(path,"il2cpp_thread_attach");
    if(!parentFn||!nameFn||!getMethod||!flagsFn||!invoke||!objectClass||!assignable||
       !threadCurrent||!threadAttach||!domainGet) {
        if(error)*error=@"FAILED_SINGLETON_API：IL2CPP 单例所需 API 不完整";
        return NULL;
    }
    // Strict first release: only a directly-derived PersistentSingleton<T>.
    // Do not invoke arbitrary Instance properties or construct Unity components.
    void *parent=parentFn(klass);
    const char *parentName=parent?nameFn(parent):NULL;
    if(!parentName||strncmp(parentName,"PersistentSingleton",19)!=0) {
        if(error)*error=@"FAILED_SINGLETON_UNSUPPORTED：不是 PersistentSingleton<T> 直接子类";
        return NULL;
    }
    const void *getter=getMethod(klass,"get_Instance",0);
    uint32_t iflags=0;
    if(!getter || !(flagsFn(getter,&iflags)&0x10u)) {
        if(error)*error=@"FAILED_SINGLETON_GETTER：缺少静态 get_Instance";
        return NULL;
    }
    if(!threadCurrent()) {
        void *domain=domainGet();
        if(!domain||!threadAttach(domain)) {
            if(error)*error=@"FAILED_SINGLETON_THREAD：线程附加失败";
            return NULL;
        }
    }
    void *exception=NULL;
    void *obj=invoke(getter,NULL,NULL,&exception);
    if(exception||!obj) {
        if(error)*error=exception?@"FAILED_SINGLETON_EXCEPTION：get_Instance 托管异常":
                                   @"FAILED_SINGLETON_NULL：get_Instance 返回空";
        return NULL;
    }
    void *actual=objectClass(obj);
    if(!actual || !assignable(klass,actual)) {
        if(error)*error=@"FAILED_SINGLETON_TYPE：返回对象类型不匹配";
        return NULL;
    }
    if(diagnostics)*diagnostics=[NSString stringWithFormat:@"PersistentSingleton<T>.Instance · %@.%@",
                                ns?:@"",className?:@""];
    if(error)*error=nil;
    return obj;
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
        // Only fall back after a genuine zero-result/unsupported liveness search.
        // Never override invalid-class or other resolver errors.
        if (!innerError || [innerError hasPrefix:@"FAILED_INSTANCE_LIVENESS"]) {
            NSString *singletonDiag=nil, *singletonError=nil;
            void *singleton=ZNIRPersistentSingleton(assembly,namespaceName,className,
                                                    &singletonDiag,&singletonError);
            if(singleton) {
                if(diagnostics)*diagnostics=singletonDiag;
                if(error)*error=nil;
                [[ZNRuntimeLogger sharedLogger] log:[@"[instance-resolver] " stringByAppendingString:singletonDiag?:@"singleton resolved"]];
                return singleton;
            }
            if(diagnostics)*diagnostics=[NSString stringWithFormat:@"%@ · %@",
                                        diag?:@"no liveness instances",singletonError?:@"singleton unavailable"];
        }
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
