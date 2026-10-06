#import "ZNIL2CPPInstanceSelectionV2.h"
#import "ZNIL2CPPInstanceResolver.h"
#import "ZNIL2CPPResolver.h"
#import "ZNIL2CPPRuntimeCommon.h"
#import "ZNPatchCore.h"
#import <objc/runtime.h>

typedef void *(*ZNM44DomainGetFn)(void);
typedef const void **(*ZNM44DomainGetAssembliesFn)(const void *, size_t *);
typedef const void *(*ZNM44AssemblyGetImageFn)(const void *);
typedef const char *(*ZNM44ImageGetNameFn)(const void *);
typedef void *(*ZNM44ClassFromNameFn)(const void *, const char *, const char *);
typedef void *(*ZNM44ObjectGetClassFn)(void *);
typedef bool (*ZNM44ClassAssignableFn)(void *, void *);

static NSMutableDictionary<NSString *, NSNumber *> *ZNM44SelectionStore(void) {
    static NSMutableDictionary<NSString *, NSNumber *> *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ store = [NSMutableDictionary dictionary]; });
    return store;
}

static NSString *ZNM44String(const char *raw) {
    if (!raw) return @"";
    NSString *value = [NSString stringWithUTF8String:raw];
    return value ?: @"";
}

static void *ZNM44ResolveClass(NSString *assembly,
                               NSString *namespaceName,
                               NSString *className,
                               NSString **error) {
    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    if (!resolver.isAvailable) {
        if (error) *error = resolver.lastError ?: @"IL2CPP Resolver unavailable";
        return NULL;
    }
    NSString *path = resolver.unityPath ?: @"";
    ZNM44DomainGetFn domainGet = (ZNM44DomainGetFn)ZNIL2CPPResolveSymbol(path, "il2cpp_domain_get");
    ZNM44DomainGetAssembliesFn getAssemblies = (ZNM44DomainGetAssembliesFn)ZNIL2CPPResolveSymbol(path, "il2cpp_domain_get_assemblies");
    ZNM44AssemblyGetImageFn getImage = (ZNM44AssemblyGetImageFn)ZNIL2CPPResolveSymbol(path, "il2cpp_assembly_get_image");
    ZNM44ImageGetNameFn getName = (ZNM44ImageGetNameFn)ZNIL2CPPResolveSymbol(path, "il2cpp_image_get_name");
    ZNM44ClassFromNameFn classFromName = (ZNM44ClassFromNameFn)ZNIL2CPPResolveSymbol(path, "il2cpp_class_from_name");
    if (!domainGet || !getAssemblies || !getImage || !getName || !classFromName) {
        if (error) *error = @"缺少 IL2CPP class validation API";
        return NULL;
    }
    void *domain = domainGet();
    size_t count = 0;
    const void **assemblies = domain ? getAssemblies(domain, &count) : NULL;
    NSString *wanted = ZNIL2CPPNormalizedAssembly(assembly);
    for (size_t i = 0; assemblies && i < count; i++) {
        const void *image = getImage(assemblies[i]);
        if (!image) continue;
        NSString *imageName = ZNM44String(getName(image));
        if (wanted.length && ![ZNIL2CPPNormalizedAssembly(imageName) isEqualToString:wanted]) continue;
        void *klass = classFromName(image,
                                    (namespaceName ?: @"").UTF8String ?: "",
                                    (className ?: @"").UTF8String ?: "");
        if (klass) return klass;
    }
    if (error) *error = [NSString stringWithFormat:@"Class 不存在：%@!%@.%@", assembly ?: @"", namespaceName ?: @"", className ?: @""];
    return NULL;
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
    return [self znm44_originalResolveUniqueInstanceForAssembly:assembly
                                                      namespace:namespaceName
                                                      className:className
                                                    diagnostics:diagnostics
                                                          error:error];
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
