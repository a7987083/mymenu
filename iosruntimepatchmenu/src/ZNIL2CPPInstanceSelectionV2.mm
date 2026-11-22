#import "ZNIL2CPPInstanceSelectionV2.h"
#import "ZNIL2CPPInstanceResolver.h"
#import "ZNIL2CPPResolver.h"
#import "ZNIL2CPPRuntimeCommon.h"
#import "ZNPatchCore.h"
#import <objc/runtime.h>
#include <string.h>

typedef void *(*ZNM44ObjectGetClassFn)(void *);
typedef bool (*ZNM44ClassAssignableFn)(void *, void *);

typedef void *(*ZNM44ClassGetParentFn)(void *);
typedef const char *(*ZNM44ClassGetNameFn)(void *);
typedef const char *(*ZNM44ClassGetNamespaceFn)(void *);
typedef void *(*ZNM44ClassGetFieldFromNameFn)(void *, const char *);
typedef void (*ZNM44FieldGetValueFn)(void *, void *, void *);

// Managed GCHandle liveness is not Unity native-object liveness.
// Check UnityEngine.Object.m_CachedPtr through exported metadata APIs only.
// Non-Unity managed classes have no native object lifetime to validate.
static BOOL ZNM44UnityNativeAlive(void *object, void *actualClass,
                                  NSString *imagePath, NSString **error) {
    ZNM44ClassGetParentFn getParent=(ZNM44ClassGetParentFn)ZNIL2CPPResolveSymbol(imagePath,"il2cpp_class_get_parent");
    ZNM44ClassGetNameFn getName=(ZNM44ClassGetNameFn)ZNIL2CPPResolveSymbol(imagePath,"il2cpp_class_get_name");
    ZNM44ClassGetNamespaceFn getNamespace=(ZNM44ClassGetNamespaceFn)ZNIL2CPPResolveSymbol(imagePath,"il2cpp_class_get_namespace");
    if (!getParent||!getName||!getNamespace) {
        // Preserve older games' existing behavior when hierarchy APIs are absent.
        return YES;
    }
    void *unityObjectClass=NULL;
    void *klass=actualClass;
    for (NSUInteger depth=0; klass && depth<64; depth++) {
        const char *name=getName(klass);
        const char *ns=getNamespace(klass);
        if (name && ns && strcmp(name,"Object")==0 && strcmp(ns,"UnityEngine")==0) {
            unityObjectClass=klass;
            break;
        }
        void *parent=getParent(klass);
        if (parent==klass) break;
        klass=parent;
    }
    if (!unityObjectClass) return YES;
    ZNM44ClassGetFieldFromNameFn getField=(ZNM44ClassGetFieldFromNameFn)
        ZNIL2CPPResolveSymbol(imagePath,"il2cpp_class_get_field_from_name");
    ZNM44FieldGetValueFn getValue=(ZNM44FieldGetValueFn)
        ZNIL2CPPResolveSymbol(imagePath,"il2cpp_field_get_value");
    if (!getField || !getValue) {
        if (error) *error=@"FAILED_INSTANCE_NATIVE_CHECK：Unity 原生对象校验 API 不可用";
        return NO;
    }
    void *field=getField(unityObjectClass,"m_CachedPtr");
    if (!field) {
        if (error) *error=@"FAILED_INSTANCE_NATIVE_CHECK：UnityEngine.Object.m_CachedPtr 不可用";
        return NO;
    }
    void *nativePointer=NULL;
    getValue(object,field,&nativePointer);
    if (!nativePointer) {
        if (error) *error=@"FAILED_INSTANCE_DESTROYED：Unity 原生对象已销毁，请重新获取实例";
        return NO;
    }
    return YES;
}


static NSMutableDictionary<NSString *, NSNumber *> *ZNM44SelectionStore(void) {
    static NSMutableDictionary<NSString *, NSNumber *> *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [NSMutableDictionary dictionary]; });
    return store;
}

static void *ZNM44ResolveClass(NSString *assembly,
                               NSString *namespaceName,
                               NSString *className,
                               NSString **error) {
    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    NSDictionary<NSString *, id> *resolved = [resolver resolveClassAssembly:assembly
                                                                 namespace:namespaceName ?: @""
                                                                 className:className ?: @""];
    if (!resolved) {
        if (error) *error = resolver.lastError.length ? resolver.lastError : @"目标 Class 无法解析";
        return NULL;
    }
    uintptr_t klass = [resolved[@"class"] unsignedLongLongValue];
    if (!klass && error) *error = @"目标 Class 地址为空";
    return (void *)klass;
}

@interface ZNIL2CPPInstanceResolver (ZNInstanceSelectionV2Private)
- (void *)znm44_originalResolveUniqueInstanceForAssembly:(NSString *)assembly
                                               namespace:(NSString *)namespaceName
                                               className:(NSString *)className
                                             diagnostics:(NSString **)diagnostics
                                                   error:(NSString **)error;
@end

@implementation ZNIL2CPPInstanceResolver (ZNInstanceSelectionV2)

- (uintptr_t)znm44_selectedInstanceForAssembly:(NSString *)assembly
                                     namespace:(NSString *)namespaceName
                                     className:(NSString *)className {
    NSString *key = ZNIL2CPPInstanceKey(assembly, namespaceName, className);
    @synchronized (ZNM44SelectionStore()) {
        return [ZNM44SelectionStore()[key] unsignedLongLongValue];
    }
}

- (void)znm44_clearSelectedInstanceForAssembly:(NSString *)assembly
                                      namespace:(NSString *)namespaceName
                                      className:(NSString *)className {
    NSString *key = ZNIL2CPPInstanceKey(assembly, namespaceName, className);
    @synchronized (ZNM44SelectionStore()) {
        [ZNM44SelectionStore() removeObjectForKey:key];
    }
}

- (BOOL)znm44_validateInstanceAddress:(uintptr_t)address
                             assembly:(NSString *)assembly
                            namespace:(NSString *)namespaceName
                            className:(NSString *)className
                                error:(NSString **)error {
    if (!address) {
        if (error) *error = @"实例地址为空";
        return NO;
    }
    NSString *classError = nil;
    void *targetClass = ZNM44ResolveClass(assembly, namespaceName, className, &classError);
    if (!targetClass) {
        if (error) *error = classError ?: @"目标 Class 无法解析";
        return NO;
    }
    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    NSString *path = resolver.unityPath ?: @"";
    ZNM44ObjectGetClassFn objectGetClass = (ZNM44ObjectGetClassFn)ZNIL2CPPResolveSymbol(path, "il2cpp_object_get_class");
    ZNM44ClassAssignableFn assignable = (ZNM44ClassAssignableFn)ZNIL2CPPResolveSymbol(path, "il2cpp_class_is_assignable_from");
    if (!objectGetClass || !assignable) {
        if (error) *error = @"缺少 il2cpp_object_get_class / il2cpp_class_is_assignable_from";
        return NO;
    }
    void *actualClass = objectGetClass((void *)address);
    if (!actualClass || !assignable(targetClass, actualClass)) {
        if (error) *error = [NSString stringWithFormat:@"实例 0x%llX 不属于 %@", (unsigned long long)address, className ?: @"target class"];
        return NO;
    }
    NSString *nativeError=nil;
    if (!ZNM44UnityNativeAlive((void *)address,actualClass,path,&nativeError)) {
        if (error) *error=nativeError ?: @"FAILED_INSTANCE_DESTROYED：对象不可用";
        return NO;
    }
    if (error) *error = nil;
    return YES;
}

- (BOOL)znm44_selectInstanceAddress:(uintptr_t)address
                           assembly:(NSString *)assembly
                          namespace:(NSString *)namespaceName
                          className:(NSString *)className
                              error:(NSString **)error {
    NSString *validationError = nil;
    if (![self znm44_validateInstanceAddress:address assembly:assembly namespace:namespaceName className:className error:&validationError]) {
        if (error) *error = validationError;
        return NO;
    }
    NSString *key = ZNIL2CPPInstanceKey(assembly, namespaceName, className);
    @synchronized (ZNM44SelectionStore()) {
        ZNM44SelectionStore()[key] = @(address);
    }
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[instance-selection-v2] selected %@!%@.%@ -> 0x%llX",
                                         assembly ?: @"", namespaceName ?: @"", className ?: @"", (unsigned long long)address]];
    if (error) *error = nil;
    return YES;
}

- (void *)znm44_originalResolveUniqueInstanceForAssembly:(NSString *)assembly
                                               namespace:(NSString *)namespaceName
                                               className:(NSString *)className
                                             diagnostics:(NSString **)diagnostics
                                                   error:(NSString **)error {
    uintptr_t selected = [self znm44_selectedInstanceForAssembly:assembly namespace:namespaceName className:className];
    if (selected) {
        NSString *validationError = nil;
        if ([self znm44_validateInstanceAddress:selected assembly:assembly namespace:namespaceName className:className error:&validationError]) {
            if (diagnostics) *diagnostics = [NSString stringWithFormat:@"selected-session-instance 0x%llX", (unsigned long long)selected];
            if (error) *error = nil;
            return (void *)selected;
        }
        [self znm44_clearSelectedInstanceForAssembly:assembly namespace:namespaceName className:className];
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[instance-selection-v2] stale selection cleared %@!%@.%@ · %@",
                                             assembly ?: @"", namespaceName ?: @"", className ?: @"", validationError ?: @"invalid"]];
    }
    // A uniquely discovered receiver becomes the session selection. Without
    // this binding, the next invocation fails when another same-class object
    // appears, even though the original receiver remains valid.
    void *unique = [self znm44_originalResolveUniqueInstanceForAssembly:assembly
                                                              namespace:namespaceName
                                                              className:className
                                                            diagnostics:diagnostics
                                                                  error:error];
    if (!unique) return NULL;

    NSString *bindingError = nil;
    if ([self znm44_selectInstanceAddress:(uintptr_t)unique
                                 assembly:assembly
                                namespace:namespaceName
                                className:className
                                    error:&bindingError]) {
        // GCHandle-backed selections can move; always use the resolved target.
        uintptr_t bound = [self znm44_selectedInstanceForAssembly:assembly
                                                        namespace:namespaceName
                                                        className:className];
        if (bound) {
            if (diagnostics) *diagnostics = [NSString stringWithFormat:
                @"auto-bound-session-instance 0x%llX", (unsigned long long)bound];
            if (error) *error = nil;
            return (void *)bound;
        }
    }

    // Preserve the previous unique-instance behavior if binding is unavailable.
    // Never resolve an ambiguous set by guessing its first address.
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:
        @"[instance-selection-v2] unique receiver binding unavailable %@!%@.%@ · %@",
        assembly ?: @"", namespaceName ?: @"", className ?: @"",
        bindingError ?: @"selection target unavailable"]];
    if (diagnostics) *diagnostics = @"unique-instance (session binding unavailable)";
    if (error) *error = nil;
    return unique;
}

@end

extern "C" void ZNInstallIL2CPPInstanceSelectionV2Deferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = ZNIL2CPPInstanceResolver.class;
        Method original = class_getInstanceMethod(cls, @selector(resolveUniqueInstanceForAssembly:namespace:className:diagnostics:error:));
        Method replacement = class_getInstanceMethod(cls, @selector(znm44_originalResolveUniqueInstanceForAssembly:namespace:className:diagnostics:error:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
        [[ZNRuntimeLogger sharedLogger] log:@"[instance-selection-v2] session instance selection installed"];
    });
}
