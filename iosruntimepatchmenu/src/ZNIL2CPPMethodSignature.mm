#import "ZNIL2CPPMethodSignature.h"

#import "ZNIL2CPPABIMetadata.h"
#import "ZNIL2CPPResolver.h"
#import "ZNPatchCore.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>

namespace {
using DomainGetFn = void *(*)();
using DomainGetAssembliesFn = const void **(*)(const void *, size_t *);
using AssemblyGetImageFn = const void *(*)(const void *);
using ImageGetNameFn = const char *(*)(const void *);
using ClassFromNameFn = void *(*)(const void *, const char *, const char *);
using ClassGetMethodsFn = const void *(*)(void *, void **);
using MethodGetNameFn = const char *(*)(const void *);
using MethodGetParamCountFn = uint32_t (*)(const void *);
using MethodGetParamFn = const void *(*)(const void *, uint32_t);
using TypeGetNameFn = char *(*)(const void *);
using MethodGetPointerFn = void *(*)(const void *);
using Il2CppFreeFn = void (*)(void *);

static NSString *ZNM46Trim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ZNM46NormalizeAssembly(NSString *value) {
    NSString *s = ZNM46Trim(value).lowercaseString;
    return [s hasSuffix:@".dll"] ? [s substringToIndex:s.length - 4] : s;
}

static BOOL ZNM46AssemblyMatches(NSString *actual, NSString *wanted) {
    return [ZNM46NormalizeAssembly(actual) isEqualToString:ZNM46NormalizeAssembly(wanted)];
}

static NSString *ZNM46String(const char *raw) {
    if (!raw) return @"";
    return [NSString stringWithUTF8String:raw] ?: @"";
}

static void *ZNM46Symbol(NSString *unityPath, const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p || !unityPath.length) return p;
#ifdef RTLD_NOLOAD
    void *handle = dlopen(unityPath.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
#else
    void *handle = dlopen(unityPath.fileSystemRepresentation, RTLD_LAZY);
#endif
    return handle ? dlsym(handle, name) : nullptr;
}

static NSString *ZNM46TypeName(TypeGetNameFn typeGetName, Il2CppFreeFn il2cppFree, const void *type) {
    if (!typeGetName || !type) return @"?";
    char *raw = typeGetName(type);
    if (!raw) return @"?";
    NSString *value = [NSString stringWithUTF8String:raw] ?: @"?";
    if (il2cppFree) il2cppFree(raw);
    return ZNM46Trim(value);
}

static NSString *ZNM46ClassPath(NSString *namespaceName, NSString *className) {
    return namespaceName.length ? [NSString stringWithFormat:@"%@.%@", namespaceName, className] : className;
}

static NSString *ZNM46ShortType(NSString *typeName) {
    NSString *value = ZNM46Trim(typeName);
    if (!value.length) return @"?";
    NSRange generic = [value rangeOfString:@"<"];
    NSString *head = generic.location == NSNotFound ? value : [value substringToIndex:generic.location];
    NSArray<NSString *> *parts = [head componentsSeparatedByString:@"."];
    NSString *shortHead = parts.lastObject.length ? parts.lastObject : head;
    return generic.location == NSNotFound ? shortHead : [shortHead stringByAppendingString:[value substringFromIndex:generic.location]];
}
}

NSString *ZNIL2CPPEncodeParameterTypeNames(NSArray<NSString *> *types) {
    NSMutableArray<NSString *> *clean = [NSMutableArray arrayWithCapacity:types.count];
    for (NSString *raw in types ?: @[]) {
        NSString *value = ZNM46Trim(raw);
        if ([value rangeOfString:@"\x1F"].location != NSNotFound) return @"";
        [clean addObject:value];
    }
    return [clean componentsJoinedByString:@"\x1F"];
}

NSArray<NSString *> *ZNIL2CPPDecodeParameterTypeNames(NSString *encoded) {
    if (!encoded.length) return @[];
    NSMutableArray<NSString *> *types = [NSMutableArray array];
    for (NSString *raw in [encoded componentsSeparatedByString:@"\x1F"]) {
        [types addObject:ZNM46Trim(raw)];
    }
    return types;
}

NSArray<NSString *> *ZNIL2CPPParameterTypeNamesForCandidate(NSDictionary<NSString *,id> *candidate, NSString **error) {
    if (![candidate isKindOfClass:NSDictionary.class]) {
        if (error) *error = @"M4.6 signature：candidate 为空";
        return nil;
    }
    NSDictionary *abi = ZNIL2CPPDescribeMethodABI(candidate);
    if (![abi[@"available"] boolValue]) {
        if (error) *error = [NSString stringWithFormat:@"M4.6 signature：%@", abi[@"reason"] ?: @"ABI metadata unavailable"];
        return nil;
    }
    NSArray *parameters = [abi[@"parameters"] isKindOfClass:NSArray.class] ? abi[@"parameters"] : @[];
    NSUInteger declaredCount = [candidate[@"argumentCount"] unsignedIntegerValue];
    if (parameters.count != declaredCount) {
        if (error) *error = [NSString stringWithFormat:@"M4.6 signature：parameter count mismatch candidate=%lu metadata=%lu",
                             (unsigned long)declaredCount, (unsigned long)parameters.count];
        return nil;
    }
    NSMutableArray<NSString *> *types = [NSMutableArray arrayWithCapacity:parameters.count];
    for (NSDictionary *param in parameters) {
        NSString *name = [param[@"name"] isKindOfClass:NSString.class] ? ZNM46Trim(param[@"name"]) : @"";
        if (!name.length || [name isEqualToString:@"?"]) {
            if (error) *error = @"M4.6 signature：parameter type name unavailable";
            return nil;
        }
        [types addObject:name];
    }
    if (error) *error = nil;
    return types;
}

NSString *ZNIL2CPPFullMethodIdentity(NSString *assembly,
                                     NSString *namespaceName,
                                     NSString *className,
                                     NSString *methodName,
                                     NSArray<NSString *> *parameterTypeNames) {
    NSString *classPath = ZNM46ClassPath(ZNM46Trim(namespaceName), ZNM46Trim(className));
    NSString *types = [[parameterTypeNames ?: @[] valueForKey:@"description"] componentsJoinedByString:@","];
    // valueForKey:description is safe for NSString but normalize explicitly to avoid mutable subclasses.
    NSMutableArray<NSString *> *normalized = [NSMutableArray arrayWithCapacity:parameterTypeNames.count];
    for (NSString *raw in parameterTypeNames ?: @[]) [normalized addObject:ZNM46Trim(raw)];
    types = [normalized componentsJoinedByString:@","];
    return [NSString stringWithFormat:@"%@!%@::%@(%@)",
            ZNM46Trim(assembly), classPath, ZNM46Trim(methodName), types];
}

NSString *ZNIL2CPPShortSignature(NSString *methodName, NSArray<NSString *> *parameterTypeNames) {
    NSMutableArray<NSString *> *types = [NSMutableArray arrayWithCapacity:parameterTypeNames.count];
    for (NSString *raw in parameterTypeNames ?: @[]) [types addObject:ZNM46ShortType(raw)];
    return [NSString stringWithFormat:@"%@(%@)", ZNM46Trim(methodName), [types componentsJoinedByString:@", "]];
}

@implementation ZNIL2CPPFullSignatureResolver

+ (instancetype)sharedResolver {
    static ZNIL2CPPFullSignatureResolver *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [ZNIL2CPPFullSignatureResolver new]; });
    return s;
}

- (NSDictionary<NSString *,id> *)resolveAssembly:(NSString *)assembly
                                        namespace:(NSString *)namespaceName
                                        className:(NSString *)className
                                           method:(NSString *)methodName
                               parameterTypeNames:(NSArray<NSString *> *)parameterTypeNames
                                            error:(NSString **)error {
    ZNIL2CPPResolver *base = [ZNIL2CPPResolver sharedResolver];
    [base refresh];
    if (!base.isAvailable) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_SIGNATURE_RESOLVER：%@", base.lastError ?: @"IL2CPP unavailable"];
        return nil;
    }

    DomainGetFn domainGet = (DomainGetFn)ZNM46Symbol(base.unityPath, "il2cpp_domain_get");
    DomainGetAssembliesFn domainGetAssemblies = (DomainGetAssembliesFn)ZNM46Symbol(base.unityPath, "il2cpp_domain_get_assemblies");
    AssemblyGetImageFn assemblyGetImage = (AssemblyGetImageFn)ZNM46Symbol(base.unityPath, "il2cpp_assembly_get_image");
    ImageGetNameFn imageGetName = (ImageGetNameFn)ZNM46Symbol(base.unityPath, "il2cpp_image_get_name");
    ClassFromNameFn classFromName = (ClassFromNameFn)ZNM46Symbol(base.unityPath, "il2cpp_class_from_name");
    ClassGetMethodsFn classGetMethods = (ClassGetMethodsFn)ZNM46Symbol(base.unityPath, "il2cpp_class_get_methods");
    MethodGetNameFn methodGetName = (MethodGetNameFn)ZNM46Symbol(base.unityPath, "il2cpp_method_get_name");
    MethodGetParamCountFn methodGetParamCount = (MethodGetParamCountFn)ZNM46Symbol(base.unityPath, "il2cpp_method_get_param_count");
    MethodGetParamFn methodGetParam = (MethodGetParamFn)ZNM46Symbol(base.unityPath, "il2cpp_method_get_param");
    TypeGetNameFn typeGetName = (TypeGetNameFn)ZNM46Symbol(base.unityPath, "il2cpp_type_get_name");
    MethodGetPointerFn methodGetPointer = (MethodGetPointerFn)ZNM46Symbol(base.unityPath, "il2cpp_method_get_pointer");
    Il2CppFreeFn il2cppFree = (Il2CppFreeFn)ZNM46Symbol(base.unityPath, "il2cpp_free");

    if (!domainGet || !domainGetAssemblies || !assemblyGetImage || !imageGetName || !classFromName ||
        !classGetMethods || !methodGetName || !methodGetParamCount || !methodGetParam || !typeGetName) {
        if (error) *error = @"FAILED_SIGNATURE_RESOLVER：完整签名解析所需 IL2CPP API 不完整";
        return nil;
    }

    void *domain = domainGet();
    size_t assemblyCount = 0;
    const void **assemblies = domain ? domainGetAssemblies(domain, &assemblyCount) : nullptr;
    if (!assemblies || !assemblyCount) {
        if (error) *error = @"FAILED_SIGNATURE_RESOLVER：IL2CPP Domain 没有程序集";
        return nil;
    }

    const void *wantedImage = nullptr;
    NSString *actualAssembly = @"";
    for (size_t i = 0; i < assemblyCount; i++) {
        const void *image = assemblyGetImage(assemblies[i]);
        NSString *imageName = ZNM46String(image ? imageGetName(image) : nullptr);
        if (image && ZNM46AssemblyMatches(imageName, assembly)) {
            wantedImage = image;
            actualAssembly = imageName;
            break;
        }
    }
    if (!wantedImage) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_SIGNATURE_NOT_FOUND：Assembly %@", assembly ?: @""];
        return nil;
    }

    void *klass = classFromName(wantedImage,
                                (namespaceName ?: @"").UTF8String ?: "",
                                (className ?: @"").UTF8String ?: "");
    if (!klass) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_SIGNATURE_NOT_FOUND：Class %@.%@", namespaceName ?: @"", className ?: @""];
        return nil;
    }

    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    void *iter = nullptr;
    const void *method = nullptr;
    while ((method = classGetMethods(klass, &iter)) != nullptr) {
        NSString *actualName = ZNM46String(methodGetName(method));
        if (![actualName isEqualToString:methodName ?: @""]) continue;
        uint32_t count = methodGetParamCount(method);
        if (count != parameterTypeNames.count) continue;

        BOOL same = YES;
        NSMutableArray<NSString *> *actualTypes = [NSMutableArray arrayWithCapacity:count];
        for (uint32_t p = 0; p < count; p++) {
            NSString *actualType = ZNM46TypeName(typeGetName, il2cppFree, methodGetParam(method, p));
            [actualTypes addObject:actualType];
            NSString *wanted = p < parameterTypeNames.count ? ZNM46Trim(parameterTypeNames[p]) : @"";
            if (![actualType isEqualToString:wanted]) same = NO;
        }
        if (!same) continue;

        uintptr_t pointer = methodGetPointer ? (uintptr_t)methodGetPointer(method) : 0;
        [matches addObject:@{
            @"assembly": actualAssembly ?: assembly ?: @"",
            @"namespace": namespaceName ?: @"",
            @"class": className ?: @"",
            @"method": actualName ?: methodName ?: @"",
            @"argumentCount": @(count),
            @"methodInfo": @((uintptr_t)method),
            @"methodPointer": @(pointer),
            @"pointerSource": methodGetPointer ? @"il2cpp_method_get_pointer" : @"unavailable",
            @"parameterTypeNames": actualTypes,
            @"signatureIdentity": ZNIL2CPPFullMethodIdentity(actualAssembly ?: assembly ?: @"",
                                                               namespaceName ?: @"",
                                                               className ?: @"",
                                                               actualName ?: methodName ?: @"",
                                                               actualTypes),
            @"signatureMatched": @YES,
        }];
        if (matches.count > 1) break;
    }

    if (matches.count == 1) {
        if (error) *error = nil;
        NSDictionary *result = matches.firstObject;
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m4.6-signature] exact resolve %@", result[@"signatureIdentity"] ?: @""]];
        return result;
    }
    if (matches.count > 1) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_SIGNATURE_AMBIGUOUS：%@", ZNIL2CPPFullMethodIdentity(assembly, namespaceName, className, methodName, parameterTypeNames)];
        return nil;
    }
    if (error) *error = [NSString stringWithFormat:@"FAILED_SIGNATURE_NOT_FOUND：%@", ZNIL2CPPFullMethodIdentity(assembly, namespaceName, className, methodName, parameterTypeNames)];
    return nil;
}

@end
