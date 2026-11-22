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
typedef const void *(*ZNIRMethodGetReturnTypeFn)(const void *);
typedef void *(*ZNIRClassFromTypeFn)(const void *);
typedef void *(*ZNIRRuntimeInvokeFn)(const void *, void *, void **, void **);
typedef void *(*ZNIRThreadCurrentFn)(void);
typedef void *(*ZNIRThreadAttachFn)(void *);
typedef void *(*ZNIRGetFieldFn)(void *, const char *);
typedef int (*ZNIRFieldGetFlagsFn)(const void *);
typedef const void *(*ZNIRFieldGetTypeFn)(const void *);
typedef void (*ZNIRStaticFieldGetValueFn)(const void *, void *);

typedef struct {
    void *klass;
    void *(*parent)(void *);
    const char *(*name)(void *);
    const void *(*method)(void *,const char *,int);
    uint32_t (*methodFlags)(const void *,uint32_t *);
    const void *(*methodReturnType)(const void *);
    void *(*classFromType)(const void *);
    ZNIRRuntimeInvokeFn invoke;
    ZNIRObjectGetClassFn objectClass;
    ZNIRClassIsAssignableFromFn assignable;
    ZNIRGetFieldFn field;
    ZNIRFieldGetFlagsFn fieldFlags;
    ZNIRFieldGetTypeFn fieldType;
    ZNIRStaticFieldGetValueFn staticFieldValue;
} ZNIRSingletonAPI;

static BOOL ZNIRSupportedSingletonBase(const char *name) {
    if (!name) return NO;
    static const char *patterns[] = {"PersistentSingleton", "MonoSingleton", "Singleton"};
    for (size_t i=0;i<sizeof(patterns)/sizeof(patterns[0]);i++) {
        size_t n=strlen(patterns[i]);
        if (strncmp(name,patterns[i],n)==0 &&
            (name[n]=='\0'||name[n]=='`'||name[n]=='<')) return YES;
    }
    return NO;
}

static BOOL ZNIRValidateSingleton(void *object, ZNIRSingletonAPI *api) {
    if (!object || !api->objectClass || !api->assignable) return NO;
    void *actual=api->objectClass(object);
    return actual && api->assignable(api->klass,actual);
}

// Read-only static fields first. Never initialize or allocate an object.
static void *ZNIRReadSingletonField(ZNIRSingletonAPI *api, void *owner, NSString **strategy) {
    if (!api->field || !api->fieldFlags || !api->fieldType ||
        !api->classFromType || !api->staticFieldValue) return NULL;
    const char *names[]={"Instance","instance","_instance","s_Instance","s_instance"};
    for (size_t i=0;i<sizeof(names)/sizeof(names[0]);i++) {
        void *field=api->field(owner,names[i]);
        if (!field || !(api->fieldFlags(field)&0x10)) continue;
        const void *type=api->fieldType(field);
        void *fieldClass=type?api->classFromType(type):NULL;
        // Prevent reading primitive/struct static fields as Il2CppObject*.
        if (!fieldClass || !api->assignable(fieldClass,api->klass)) continue;
        void *object=NULL;
        api->staticFieldValue(field,&object);
        if (!ZNIRValidateSingleton(object,api)) continue;
        if (strategy) *strategy=[NSString stringWithFormat:@"static-field:%s",names[i]];
        return object;
    }
    return NULL;
}

static void *ZNIRResolveSingletonManually(NSString *assembly, NSString *ns, NSString *className,
                                           NSString **diagnostics, NSString **error) {
    ZNIL2CPPResolver *resolver=[ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    NSDictionary *info=[resolver resolveClassAssembly:assembly namespace:ns?:@"" className:className];
    void *klass=(void *)(uintptr_t)[info[@"class"] unsignedLongLongValue];
    if (!klass) { if(error)*error=@"FAILED_SINGLETON_CLASS：无法解析目标类"; return NULL; }
    NSString *path=resolver.unityPath?:@"";
    ZNIRSingletonAPI api={};
    api.klass=klass;
    api.parent=(ZNIRClassGetParentFn)ZNIRResolveSymbol(path,"il2cpp_class_get_parent");
    api.name=(ZNIRClassGetNameFn)ZNIRResolveSymbol(path,"il2cpp_class_get_name");
    api.method=(ZNIRGetMethodFn)ZNIRResolveSymbol(path,"il2cpp_class_get_method_from_name");
    api.methodFlags=(ZNIRMethodGetFlagsFn)ZNIRResolveSymbol(path,"il2cpp_method_get_flags");
    api.methodReturnType=(ZNIRMethodGetReturnTypeFn)ZNIRResolveSymbol(path,"il2cpp_method_get_return_type");
    api.classFromType=(ZNIRClassFromTypeFn)ZNIRResolveSymbol(path,"il2cpp_class_from_type");
    api.invoke=(ZNIRRuntimeInvokeFn)ZNIRResolveSymbol(path,"il2cpp_runtime_invoke");
    api.objectClass=(ZNIRObjectGetClassFn)ZNIRResolveSymbol(path,"il2cpp_object_get_class");
    api.assignable=(ZNIRClassIsAssignableFromFn)ZNIRResolveSymbol(path,"il2cpp_class_is_assignable_from");
    api.field=(ZNIRGetFieldFn)ZNIRResolveSymbol(path,"il2cpp_class_get_field_from_name");
    api.fieldFlags=(ZNIRFieldGetFlagsFn)ZNIRResolveSymbol(path,"il2cpp_field_get_flags");
    api.fieldType=(ZNIRFieldGetTypeFn)ZNIRResolveSymbol(path,"il2cpp_field_get_type");
    api.staticFieldValue=(ZNIRStaticFieldGetValueFn)ZNIRResolveSymbol(path,"il2cpp_field_static_get_value");
    if (!api.parent || !api.name || !api.objectClass || !api.assignable) {
        if(error)*error=@"FAILED_SINGLETON_API：类型校验 API 不完整";
        return NULL;
    }

    BOOL trustedBase=NO;
    NSString *fieldStrategy=nil;
    void *object=NULL;
    void *owner=klass;
    // A short, bounded walk avoids cyclic/corrupt hierarchy metadata.
    for (NSUInteger depth=0; owner && depth<32; depth++) {
        if (depth && ZNIRSupportedSingletonBase(api.name(owner))) trustedBase=YES;
        object=ZNIRReadSingletonField(&api,owner,&fieldStrategy);
        if(object) {
            if(diagnostics)*diagnostics=[NSString stringWithFormat:@"Singleton %@ (%@)",
                                        fieldStrategy?:@"static field",className?:@""];
            if(error)*error=nil;
            return object;
        }
        void *next=api.parent(owner);
        if(next==owner) break;
        owner=next;
    }

    // Explicit-button getter fallback ONLY for known singleton base patterns.
    // Getters can create instances; arbitrary properties must never be invoked.
    if (!trustedBase) {
        if(error)*error=@"FAILED_SINGLETON_UNSUPPORTED：未找到有效静态实例字段或已识别 Singleton 基类";
        return NULL;
    }
    if(!api.method||!api.methodFlags||!api.invoke||!api.methodReturnType||!api.classFromType) {
        if(error)*error=@"FAILED_SINGLETON_GETTER_API：getter 元数据 API 不完整";
        return NULL;
    }
    const void *getter=api.method(klass,"get_Instance",0);
    uint32_t impl=0;
    if(!getter||!(api.methodFlags(getter,&impl)&0x10u)) {
        if(error)*error=@"FAILED_SINGLETON_GETTER：静态 get_Instance 不存在";
        return NULL;
    }
    const void *returnType=api.methodReturnType(getter);
    void *returnClass=returnType?api.classFromType(returnType):NULL;
    if(!returnClass || !api.assignable(returnClass,klass)) {
        if(error)*error=@"FAILED_SINGLETON_RETURN_TYPE：getter 返回类型不兼容目标类";
        return NULL;
    }
    ZNIRThreadCurrentFn current=(ZNIRThreadCurrentFn)ZNIRResolveSymbol(path,"il2cpp_thread_current");
    ZNIRThreadAttachFn attach=(ZNIRThreadAttachFn)ZNIRResolveSymbol(path,"il2cpp_thread_attach");
    void *(*domainGet)(void)=(void *(*)(void))ZNIRResolveSymbol(path,"il2cpp_domain_get");
    if(!current||!attach||!domainGet) {
        if(error)*error=@"FAILED_SINGLETON_THREAD_API：线程 API 不完整";
        return NULL;
    }
    if(!current()) {
        void *domain=domainGet();
        if(!domain||!attach(domain)) {
            if(error)*error=@"FAILED_SINGLETON_THREAD：无法附加当前线程";
            return NULL;
        }
    }
    void *exception=NULL;
    object=api.invoke(getter,NULL,NULL,&exception);
    if(exception || !ZNIRValidateSingleton(object,&api)) {
        if(error)*error=exception?@"FAILED_SINGLETON_EXCEPTION：get_Instance 抛出异常":
                                  @"FAILED_SINGLETON_NULL_OR_TYPE：getter 返回空或类型不匹配";
        return NULL;
    }
    if(diagnostics)*diagnostics=[NSString stringWithFormat:@"Singleton known-base getter (%@)",className?:@""];
    if(error)*error=nil;
    return object;
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

- (void *)resolveSingletonForAssembly:(NSString *)assembly
                                      namespace:(NSString *)namespaceName
                                      className:(NSString *)className
                                    diagnostics:(NSString **)diagnostics
                                          error:(NSString **)error {
    // Explicit UI action only; never invoked from normal instance resolution.
    return ZNIRResolveSingletonManually(assembly, namespaceName, className, diagnostics, error);
}

@end
