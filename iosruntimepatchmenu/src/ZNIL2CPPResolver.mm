#import "ZNIL2CPPResolver.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#import <dlfcn.h>
#import <errno.h>
#import <limits.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

typedef void *(*ZNIl2CppDomainGetFn)(void);
typedef const void **(*ZNIl2CppDomainGetAssembliesFn)(const void *, size_t *);
typedef const void *(*ZNIl2CppAssemblyGetImageFn)(const void *);
typedef const char *(*ZNIl2CppImageGetNameFn)(const void *);
typedef size_t (*ZNIl2CppImageGetClassCountFn)(const void *);
typedef void *(*ZNIl2CppImageGetClassFn)(const void *, size_t);
typedef void *(*ZNIl2CppClassFromNameFn)(const void *, const char *, const char *);
typedef const char *(*ZNIl2CppClassGetNameFn)(void *);
typedef const char *(*ZNIl2CppClassGetNamespaceFn)(void *);
typedef const void *(*ZNIl2CppClassGetMethodsFn)(void *, void **);
typedef const void *(*ZNIl2CppClassGetMethodFromNameFn)(void *, const char *, int);
typedef void *(*ZNIl2CppClassGetFieldFromNameFn)(void *, const char *);
typedef size_t (*ZNIl2CppFieldGetOffsetFn)(void *);
typedef const char *(*ZNIl2CppMethodGetNameFn)(const void *);
typedef uint32_t (*ZNIl2CppMethodGetParamCountFn)(const void *);
typedef void *(*ZNIl2CppMethodGetPointerFn)(const void *);
typedef void *(*ZNIl2CppRuntimeInvokeFn)(const void *, void *, void **, void **);

static NSString *ZNIL2CPPTrim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ZNIL2CPPString(const char *value) {
    if (!value) return @"";
    NSString *s = [NSString stringWithUTF8String:value];
    return s ?: @"";
}

static NSString *ZNIL2CPPNormalizedAssembly(NSString *value) {
    NSString *s = ZNIL2CPPTrim(value).lowercaseString;
    return [s hasSuffix:@".dll"] ? [s substringToIndex:s.length - 4] : s;
}

static BOOL ZNIL2CPPAssemblyMatches(NSString *actual, NSString *wanted) {
    if (!wanted.length) return YES;
    return [ZNIL2CPPNormalizedAssembly(actual) isEqualToString:ZNIL2CPPNormalizedAssembly(wanted)];
}

static BOOL ZNIL2CPPParseMagnitude(NSString *text, uint64_t *value) {
    NSString *s = ZNIL2CPPTrim(text);
    if (!s.length) return NO;
    const char *c = s.UTF8String;
    char *end = NULL;
    errno = 0;
    unsigned long long v = strtoull(c, &end, 0);
    if (errno || end == c || (end && *end)) return NO;
    if (value) *value = (uint64_t)v;
    return YES;
}

@interface ZNIL2CPPResolver ()
@property(nonatomic,assign,readwrite,getter=isAvailable) BOOL available;
@property(nonatomic,copy,readwrite) NSString *unityPath;
@property(nonatomic,copy,readwrite) NSString *lastError;
@property(nonatomic,copy,readwrite) NSString *lastNamedResolution;
@end

@implementation ZNIL2CPPResolver {
    void *_handle;
    ZNIl2CppDomainGetFn _domainGet;
    ZNIl2CppDomainGetAssembliesFn _domainGetAssemblies;
    ZNIl2CppAssemblyGetImageFn _assemblyGetImage;
    ZNIl2CppImageGetNameFn _imageGetName;
    ZNIl2CppImageGetClassCountFn _imageGetClassCount;
    ZNIl2CppImageGetClassFn _imageGetClass;
    ZNIl2CppClassFromNameFn _classFromName;
    ZNIl2CppClassGetNameFn _classGetName;
    ZNIl2CppClassGetNamespaceFn _classGetNamespace;
    ZNIl2CppClassGetMethodsFn _classGetMethods;
    ZNIl2CppClassGetMethodFromNameFn _classGetMethodFromName;
    ZNIl2CppClassGetFieldFromNameFn _classGetFieldFromName;
    ZNIl2CppFieldGetOffsetFn _fieldGetOffset;
    ZNIl2CppMethodGetNameFn _methodGetName;
    ZNIl2CppMethodGetParamCountFn _methodGetParamCount;
    ZNIl2CppMethodGetPointerFn _methodGetPointer;
    ZNIl2CppRuntimeInvokeFn _runtimeInvoke;
}

+ (instancetype)sharedResolver {
    static ZNIL2CPPResolver *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [ZNIL2CPPResolver new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _unityPath = @"";
    _lastError = @"尚未解析";
    _lastNamedResolution = @"尚未使用";
    [self refresh];
    return self;
}

- (NSString *)findUnityPath {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *cpath = _dyld_get_image_name(i);
        if (!cpath) continue;
        NSString *path = [NSString stringWithUTF8String:cpath];
        NSString *name = path.lastPathComponent;
        if ([name isEqualToString:@"UnityFramework"] ||
            [path rangeOfString:@"UnityFramework.framework/UnityFramework" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return path;
        }
    }
    return @"";
}

- (uintptr_t)unityImageBase {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *cpath = _dyld_get_image_name(i);
        if (!cpath) continue;
        NSString *path = [NSString stringWithUTF8String:cpath];
        if (!path.length) continue;
        BOOL match = self.unityPath.length && [path isEqualToString:self.unityPath];
        if (!match) {
            NSString *name = path.lastPathComponent;
            match = [name isEqualToString:@"UnityFramework"] ||
                    [path rangeOfString:@"UnityFramework.framework/UnityFramework" options:NSCaseInsensitiveSearch].location != NSNotFound;
        }
        if (match) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

- (BOOL)isExecutableUnityAddress:(uintptr_t)address {
    uintptr_t imageBase = [self unityImageBase];
    if (!imageBase || !address) return NO;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)imageBase;
    if (mh->magic != MH_MAGIC_64) return NO;

    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    const uint8_t *end = cursor + mh->sizeofcmds;
    uint64_t imageVMBase = UINT64_MAX;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > end) return NO;
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > end) return NO;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if (strncmp(seg->segname, SEG_TEXT, 16) == 0) imageVMBase = seg->vmaddr;
        }
        cursor += lc->cmdsize;
    }
    if (imageVMBase == UINT64_MAX) return NO;

    cursor = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if ((seg->initprot & VM_PROT_EXECUTE) && seg->vmaddr >= imageVMBase) {
                uintptr_t start = imageBase + (uintptr_t)(seg->vmaddr - imageVMBase);
                uintptr_t finish = start + (uintptr_t)seg->vmsize;
                if (address >= start && address < finish) return YES;
            }
        }
        cursor += lc->cmdsize;
    }
    return NO;
}

- (void *)resolveSymbol:(const char *)name {
    if (!name) return NULL;
    void *p = _handle ? dlsym(_handle, name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

- (void)clearFunctions {
    _domainGet = NULL;
    _domainGetAssemblies = NULL;
    _assemblyGetImage = NULL;
    _imageGetName = NULL;
    _imageGetClassCount = NULL;
    _imageGetClass = NULL;
    _classFromName = NULL;
    _classGetName = NULL;
    _classGetNamespace = NULL;
    _classGetMethods = NULL;
    _classGetMethodFromName = NULL;
    _classGetFieldFromName = NULL;
    _fieldGetOffset = NULL;
    _methodGetName = NULL;
    _methodGetParamCount = NULL;
    _methodGetPointer = NULL;
    _runtimeInvoke = NULL;
}

- (void)refresh {
    self.available = NO;
    self.lastError = @"";
    [self clearFunctions];

    NSString *path = [self findUnityPath];
    self.unityPath = path ?: @"";
    if (!path.length) {
        self.lastError = @"UnityFramework 尚未加载";
        return;
    }

#ifdef RTLD_NOLOAD
    _handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
#else
    _handle = dlopen(path.fileSystemRepresentation, RTLD_LAZY);
#endif
    if (!_handle) _handle = NULL;

    _domainGet = (ZNIl2CppDomainGetFn)[self resolveSymbol:"il2cpp_domain_get"];
    _domainGetAssemblies = (ZNIl2CppDomainGetAssembliesFn)[self resolveSymbol:"il2cpp_domain_get_assemblies"];
    _assemblyGetImage = (ZNIl2CppAssemblyGetImageFn)[self resolveSymbol:"il2cpp_assembly_get_image"];
    _imageGetName = (ZNIl2CppImageGetNameFn)[self resolveSymbol:"il2cpp_image_get_name"];
    _imageGetClassCount = (ZNIl2CppImageGetClassCountFn)[self resolveSymbol:"il2cpp_image_get_class_count"];
    _imageGetClass = (ZNIl2CppImageGetClassFn)[self resolveSymbol:"il2cpp_image_get_class"];
    _classFromName = (ZNIl2CppClassFromNameFn)[self resolveSymbol:"il2cpp_class_from_name"];
    _classGetName = (ZNIl2CppClassGetNameFn)[self resolveSymbol:"il2cpp_class_get_name"];
    _classGetNamespace = (ZNIl2CppClassGetNamespaceFn)[self resolveSymbol:"il2cpp_class_get_namespace"];
    _classGetMethods = (ZNIl2CppClassGetMethodsFn)[self resolveSymbol:"il2cpp_class_get_methods"];
    _classGetMethodFromName = (ZNIl2CppClassGetMethodFromNameFn)[self resolveSymbol:"il2cpp_class_get_method_from_name"];
    _classGetFieldFromName = (ZNIl2CppClassGetFieldFromNameFn)[self resolveSymbol:"il2cpp_class_get_field_from_name"];
    _fieldGetOffset = (ZNIl2CppFieldGetOffsetFn)[self resolveSymbol:"il2cpp_field_get_offset"];
    _methodGetName = (ZNIl2CppMethodGetNameFn)[self resolveSymbol:"il2cpp_method_get_name"];
    _methodGetParamCount = (ZNIl2CppMethodGetParamCountFn)[self resolveSymbol:"il2cpp_method_get_param_count"];
    _methodGetPointer = (ZNIl2CppMethodGetPointerFn)[self resolveSymbol:"il2cpp_method_get_pointer"];
    _runtimeInvoke = (ZNIl2CppRuntimeInvokeFn)[self resolveSymbol:"il2cpp_runtime_invoke"];

    BOOL core = _domainGet && _domainGetAssemblies && _assemblyGetImage && _imageGetName &&
                _classFromName && _classGetMethodFromName;
    self.available = core;
    if (!core) self.lastError = @"IL2CPP Runtime API 不完整或已被隐藏";
}

- (NSDictionary<NSString *,NSNumber *> *)capabilities {
    BOOL namedSearch = _imageGetClassCount && _imageGetClass && _classGetName && _classGetNamespace &&
                       _classGetMethods && _methodGetName;
    return @{
        @"core": @(self.available),
        @"method": @(_classGetMethodFromName != NULL),
        @"methodPointer": @(_methodGetPointer != NULL),
        @"methodPointerFallback": @YES,
        @"namedSearch": @(namedSearch),
        @"methodParamCount": @(_methodGetParamCount != NULL),
        @"field": @(_classGetFieldFromName != NULL && _fieldGetOffset != NULL),
        @"invoke": @(_runtimeInvoke != NULL),
    };
}

- (const void **)currentAssemblies:(size_t *)outCount {
    if (outCount) *outCount = 0;
    if (!self.available || !_domainGet || !_domainGetAssemblies) return NULL;
    void *domain = _domainGet();
    if (!domain) return NULL;
    size_t count = 0;
    const void **assemblies = _domainGetAssemblies(domain, &count);
    if (outCount) *outCount = count;
    return assemblies;
}

- (const void *)imageForAssembly:(NSString *)assembly {
    if (!self.available || !assembly.length) return NULL;
    size_t count = 0;
    const void **assemblies = [self currentAssemblies:&count];
    if (!assemblies || count == 0) return NULL;

    for (size_t i = 0; i < count; i++) {
        const void *image = _assemblyGetImage(assemblies[i]);
        NSString *name = ZNIL2CPPString(image ? _imageGetName(image) : NULL);
        if (ZNIL2CPPAssemblyMatches(name, assembly)) return image;
    }
    return NULL;
}

- (uintptr_t)codePointerForMethod:(const void *)method source:(NSString **)source {
    if (source) *source = @"unavailable";
    if (!method) return 0;

    if (_methodGetPointer) {
        uintptr_t p = (uintptr_t)_methodGetPointer(method);
        if ([self isExecutableUnityAddress:p]) {
            if (source) *source = @"il2cpp_method_get_pointer";
            return p;
        }
    }

    // Common IL2CPP MethodInfo layouts keep the native method pointer in the
    // first machine word (and some versions keep a virtual pointer second).
    // This fallback is accepted only when the candidate lands inside an
    // executable UnityFramework Mach-O segment; otherwise it is rejected.
    uintptr_t words[2] = {0, 0};
    memcpy(words, method, sizeof(words));
    for (NSUInteger i = 0; i < 2; i++) {
        if ([self isExecutableUnityAddress:words[i]]) {
            if (source) *source = [NSString stringWithFormat:@"MethodInfo[%lu]", (unsigned long)i];
            return words[i];
        }
    }
    return 0;
}

+ (NSDictionary<NSString *,id> *)parseNamedOffsetExpression:(NSString *)expression error:(NSString **)error {
    NSString *raw = ZNIL2CPPTrim(expression);
    if (!raw.length) {
        if (error) *error = @"Named Offset 不能为空";
        return nil;
    }

    NSString *core = raw;
    int64_t delta = 0;
    NSRegularExpression *deltaRE = [NSRegularExpression regularExpressionWithPattern:@"([+-])(0[xX][0-9A-Fa-f]+|[0-9]+)$" options:0 error:nil];
    NSTextCheckingResult *deltaMatch = [deltaRE firstMatchInString:core options:0 range:NSMakeRange(0, core.length)];
    if (deltaMatch && NSMaxRange(deltaMatch.range) == core.length) {
        NSString *sign = [core substringWithRange:[deltaMatch rangeAtIndex:1]];
        NSString *magnitudeText = [core substringWithRange:[deltaMatch rangeAtIndex:2]];
        uint64_t magnitude = 0;
        if (!ZNIL2CPPParseMagnitude(magnitudeText, &magnitude) || magnitude > (uint64_t)INT64_MAX) {
            if (error) *error = @"Named Offset delta 超出范围";
            return nil;
        }
        delta = [sign isEqualToString:@"-"] ? -(int64_t)magnitude : (int64_t)magnitude;
        core = ZNIL2CPPTrim([core substringToIndex:deltaMatch.range.location]);
    }

    NSInteger argumentCount = -1;
    BOOL argumentSpecified = NO;
    NSRegularExpression *argRE = [NSRegularExpression regularExpressionWithPattern:@"/([0-9]+)$" options:0 error:nil];
    NSTextCheckingResult *argMatch = [argRE firstMatchInString:core options:0 range:NSMakeRange(0, core.length)];
    if (argMatch && NSMaxRange(argMatch.range) == core.length) {
        NSString *argText = [core substringWithRange:[argMatch rangeAtIndex:1]];
        unsigned long long parsed = strtoull(argText.UTF8String, NULL, 10);
        if (parsed > INT_MAX) {
            if (error) *error = @"Named Offset 参数数量超出范围";
            return nil;
        }
        argumentCount = (NSInteger)parsed;
        argumentSpecified = YES;
        core = ZNIL2CPPTrim([core substringToIndex:argMatch.range.location]);
    }

    NSString *assembly = @"";
    NSRange bang = [core rangeOfString:@"!"];
    if (bang.location != NSNotFound) {
        assembly = ZNIL2CPPTrim([core substringToIndex:bang.location]);
        core = ZNIL2CPPTrim([core substringFromIndex:NSMaxRange(bang)]);
        if (!assembly.length || !core.length) {
            if (error) *error = @"Named Offset 的 Assembly!Method 格式无效";
            return nil;
        }
    }

    NSString *namespaceName = @"";
    NSString *className = @"";
    NSString *methodName = core;
    BOOL namespaceSpecified = NO;
    NSRange classSep = [core rangeOfString:@"::" options:NSBackwardsSearch];
    if (classSep.location != NSNotFound) {
        NSString *classSpec = ZNIL2CPPTrim([core substringToIndex:classSep.location]);
        methodName = ZNIL2CPPTrim([core substringFromIndex:NSMaxRange(classSep)]);
        if (!classSpec.length || !methodName.length) {
            if (error) *error = @"Named Offset 的 Class::Method 格式无效";
            return nil;
        }
        NSRange dot = [classSpec rangeOfString:@"." options:NSBackwardsSearch];
        if (dot.location != NSNotFound) {
            namespaceName = ZNIL2CPPTrim([classSpec substringToIndex:dot.location]);
            className = ZNIL2CPPTrim([classSpec substringFromIndex:NSMaxRange(dot)]);
            namespaceSpecified = YES;
        } else {
            className = classSpec;
        }
    }

    methodName = ZNIL2CPPTrim(methodName);
    if (!methodName.length) {
        if (error) *error = @"Named Offset 缺少方法名";
        return nil;
    }
    if ([methodName rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
        if (error) *error = @"Named Offset 方法名不能包含空白";
        return nil;
    }

    NSMutableDictionary *parsed = [@{
        @"raw": raw,
        @"assembly": assembly,
        @"namespace": namespaceName,
        @"class": className,
        @"method": methodName,
        @"argumentSpecified": @(argumentSpecified),
        @"namespaceSpecified": @(namespaceSpecified),
        @"delta": @(delta),
    } mutableCopy];
    if (argumentSpecified) parsed[@"argumentCount"] = @(argumentCount);
    return parsed;
}

- (NSDictionary<NSString *,id> *)candidateForMethod:(const void *)method
                                           assembly:(NSString *)assembly
                                          namespace:(NSString *)namespaceName
                                          className:(NSString *)className
                                         methodName:(NSString *)methodName
                                      argumentCount:(NSInteger)argumentCount {
    NSString *pointerSource = nil;
    uintptr_t pointer = [self codePointerForMethod:method source:&pointerSource];
    uintptr_t imageBase = [self unityImageBase];
    uint64_t rva = (pointer && imageBase && pointer >= imageBase) ? (uint64_t)(pointer - imageBase) : 0;
    NSString *classPath = namespaceName.length ? [NSString stringWithFormat:@"%@.%@", namespaceName, className] : className;
    NSString *canonical = [NSString stringWithFormat:@"%@!%@::%@%@",
                           assembly.length ? assembly : @"?",
                           classPath.length ? classPath : @"?",
                           methodName.length ? methodName : @"?",
                           argumentCount >= 0 ? [NSString stringWithFormat:@"/%ld", (long)argumentCount] : @""];
    return @{
        @"assembly": assembly ?: @"",
        @"namespace": namespaceName ?: @"",
        @"class": className ?: @"",
        @"method": methodName ?: @"",
        @"argumentCount": @(argumentCount),
        @"methodInfo": @((uintptr_t)method),
        @"methodPointer": @(pointer),
        @"rva": @(rva),
        @"pointerSource": pointerSource ?: @"unavailable",
        @"canonical": canonical,
    };
}

- (NSArray<NSDictionary<NSString *,id> *> *)qualifiedCandidates:(NSDictionary<NSString *,id> *)parsed error:(NSString **)error {
    NSString *assemblyWanted = parsed[@"assembly"] ?: @"";
    NSString *namespaceName = parsed[@"namespace"] ?: @"";
    NSString *className = parsed[@"class"] ?: @"";
    NSString *methodName = parsed[@"method"] ?: @"";
    BOOL argSpecified = [parsed[@"argumentSpecified"] boolValue];
    NSInteger argumentCount = argSpecified ? [parsed[@"argumentCount"] integerValue] : -1;

    size_t assemblyCount = 0;
    const void **assemblies = [self currentAssemblies:&assemblyCount];
    if (!assemblies || !assemblyCount) {
        if (error) *error = @"IL2CPP Domain 尚无可用程序集";
        return nil;
    }

    NSMutableArray *matches = [NSMutableArray array];
    for (size_t i = 0; i < assemblyCount && matches.count < 8; i++) {
        const void *image = _assemblyGetImage(assemblies[i]);
        if (!image) continue;
        NSString *assemblyName = ZNIL2CPPString(_imageGetName(image));
        if (!ZNIL2CPPAssemblyMatches(assemblyName, assemblyWanted)) continue;

        void *klass = _classFromName(image, namespaceName.UTF8String, className.UTF8String);
        if (!klass) continue;

        if (argSpecified) {
            const void *method = _classGetMethodFromName(klass, methodName.UTF8String, (int)argumentCount);
            if (method) {
                [matches addObject:[self candidateForMethod:method
                                                   assembly:assemblyName
                                                  namespace:namespaceName
                                                  className:className
                                                 methodName:methodName
                                              argumentCount:argumentCount]];
            }
            continue;
        }

        if (!_classGetMethods || !_methodGetName) {
            if (error) *error = @"该 IL2CPP 未导出方法枚举 API；完整类名查询请补充 /参数数量";
            return nil;
        }
        void *iter = NULL;
        const void *method = NULL;
        while ((method = _classGetMethods(klass, &iter)) != NULL && matches.count < 8) {
            NSString *actualName = ZNIL2CPPString(_methodGetName(method));
            if (![actualName isEqualToString:methodName]) continue;
            NSInteger count = _methodGetParamCount ? (NSInteger)_methodGetParamCount(method) : -1;
            [matches addObject:[self candidateForMethod:method
                                               assembly:assemblyName
                                              namespace:namespaceName
                                              className:className
                                             methodName:actualName
                                          argumentCount:count]];
        }
    }
    return matches;
}

- (NSArray<NSDictionary<NSString *,id> *> *)scannedCandidates:(NSDictionary<NSString *,id> *)parsed error:(NSString **)error {
    NSDictionary *caps = self.capabilities;
    if (![caps[@"namedSearch"] boolValue]) {
        if (error) *error = @"当前 IL2CPP 未导出全局 Named Offset 搜索所需 API；请使用 Assembly.Namespace.Class::Method/参数数 或数字 RVA";
        return nil;
    }

    NSString *assemblyWanted = parsed[@"assembly"] ?: @"";
    NSString *namespaceWanted = parsed[@"namespace"] ?: @"";
    NSString *classWanted = parsed[@"class"] ?: @"";
    NSString *methodWanted = parsed[@"method"] ?: @"";
    BOOL namespaceSpecified = [parsed[@"namespaceSpecified"] boolValue];
    BOOL argSpecified = [parsed[@"argumentSpecified"] boolValue];
    NSInteger wantedArgCount = argSpecified ? [parsed[@"argumentCount"] integerValue] : -1;
    if (argSpecified && !_methodGetParamCount) {
        if (error) *error = @"当前 IL2CPP 未导出参数数量 API；全局搜索不能安全匹配 /参数数量";
        return nil;
    }

    size_t assemblyCount = 0;
    const void **assemblies = [self currentAssemblies:&assemblyCount];
    if (!assemblies || !assemblyCount) {
        if (error) *error = @"IL2CPP Domain 尚无可用程序集";
        return nil;
    }

    NSMutableArray *matches = [NSMutableArray array];
    for (size_t a = 0; a < assemblyCount && matches.count < 8; a++) {
        const void *image = _assemblyGetImage(assemblies[a]);
        if (!image) continue;
        NSString *assemblyName = ZNIL2CPPString(_imageGetName(image));
        if (!ZNIL2CPPAssemblyMatches(assemblyName, assemblyWanted)) continue;

        size_t classCount = _imageGetClassCount(image);
        for (size_t c = 0; c < classCount && matches.count < 8; c++) {
            void *klass = _imageGetClass(image, c);
            if (!klass) continue;
            NSString *className = ZNIL2CPPString(_classGetName(klass));
            NSString *namespaceName = ZNIL2CPPString(_classGetNamespace(klass));
            if (classWanted.length && ![className isEqualToString:classWanted]) continue;
            if (namespaceSpecified && ![namespaceName isEqualToString:namespaceWanted]) continue;

            void *iter = NULL;
            const void *method = NULL;
            while ((method = _classGetMethods(klass, &iter)) != NULL && matches.count < 8) {
                NSString *methodName = ZNIL2CPPString(_methodGetName(method));
                if (![methodName isEqualToString:methodWanted]) continue;
                NSInteger argumentCount = _methodGetParamCount ? (NSInteger)_methodGetParamCount(method) : -1;
                if (argSpecified && argumentCount != wantedArgCount) continue;
                [matches addObject:[self candidateForMethod:method
                                                   assembly:assemblyName
                                                  namespace:namespaceName
                                                  className:className
                                                 methodName:methodName
                                              argumentCount:argumentCount]];
            }
        }
    }
    return matches;
}

- (NSDictionary<NSString *,id> *)resolveNamedOffsetExpression:(NSString *)expression error:(NSString **)error {
    NSString *parseError = nil;
    NSDictionary *parsed = [ZNIL2CPPResolver parseNamedOffsetExpression:expression error:&parseError];
    if (!parsed) {
        self.lastError = parseError ?: @"Named Offset 解析失败";
        self.lastNamedResolution = [NSString stringWithFormat:@"FAIL · %@", self.lastError];
        if (error) *error = self.lastError;
        return nil;
    }

    [self refresh];
    if (!self.available) {
        self.lastNamedResolution = [NSString stringWithFormat:@"FAIL · %@", self.lastError ?: @"IL2CPP 不可用"];
        if (error) *error = self.lastError;
        return nil;
    }

    NSString *className = parsed[@"class"] ?: @"";
    BOOL namespaceSpecified = [parsed[@"namespaceSpecified"] boolValue];
    NSString *searchError = nil;
    NSArray<NSDictionary<NSString *,id> *> *matches = nil;
    NSString *searchMode = nil;
    if (className.length && namespaceSpecified) {
        searchMode = @"qualified";
        matches = [self qualifiedCandidates:parsed error:&searchError];
    } else {
        searchMode = @"enumerated";
        matches = [self scannedCandidates:parsed error:&searchError];
    }
    if (!matches) {
        self.lastError = searchError ?: @"Named Offset 搜索失败";
        self.lastNamedResolution = [NSString stringWithFormat:@"FAIL · %@", self.lastError];
        if (error) *error = self.lastError;
        return nil;
    }
    if (!matches.count) {
        self.lastError = [NSString stringWithFormat:@"找不到 IL2CPP 方法：%@", parsed[@"raw"] ?: expression ?: @""];
        self.lastNamedResolution = [NSString stringWithFormat:@"FAIL · %@", self.lastError];
        if (error) *error = self.lastError;
        return nil;
    }
    if (matches.count != 1) {
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        for (NSUInteger i = 0; i < MIN((NSUInteger)5, matches.count); i++) {
            [labels addObject:matches[i][@"canonical"] ?: @"?"];
        }
        NSString *suffix = matches.count >= 8 ? @"至少 8" : [NSString stringWithFormat:@"%lu", (unsigned long)matches.count];
        self.lastError = [NSString stringWithFormat:@"Named Offset 不唯一（%@ 个候选）：%@。请补充 Class::Method/参数数 或 Assembly-CSharp.dll!Namespace.Class::Method/参数数",
                          suffix, [labels componentsJoinedByString:@" | "]];
        self.lastNamedResolution = [NSString stringWithFormat:@"AMBIGUOUS · %@", parsed[@"raw"] ?: @""];
        if (error) *error = self.lastError;
        return nil;
    }

    NSDictionary *candidate = matches.firstObject;
    uintptr_t pointer = (uintptr_t)[candidate[@"methodPointer"] unsignedLongLongValue];
    uint64_t baseRVA = [candidate[@"rva"] unsignedLongLongValue];
    if (!pointer || !baseRVA) {
        self.lastError = [NSString stringWithFormat:@"已找到 %@，但无法取得可验证的 UnityFramework 代码指针；methodPointer API 不可用且 MethodInfo fallback 未命中 executable segment",
                          candidate[@"canonical"] ?: parsed[@"raw"] ?: @"方法"];
        self.lastNamedResolution = [NSString stringWithFormat:@"NO-POINTER · %@", candidate[@"canonical"] ?: @""];
        if (error) *error = self.lastError;
        return nil;
    }

    int64_t delta = [parsed[@"delta"] longLongValue];
    uint64_t resolvedRVA = baseRVA;
    if (delta < 0) {
        uint64_t magnitude = (uint64_t)(-delta);
        if (magnitude > baseRVA) {
            self.lastError = @"Named Offset delta 导致 RVA 下溢";
            self.lastNamedResolution = [NSString stringWithFormat:@"FAIL · %@", self.lastError];
            if (error) *error = self.lastError;
            return nil;
        }
        resolvedRVA = baseRVA - magnitude;
    } else if (delta > 0) {
        uint64_t magnitude = (uint64_t)delta;
        if (baseRVA > UINT64_MAX - magnitude) {
            self.lastError = @"Named Offset delta 导致 RVA 上溢";
            self.lastNamedResolution = [NSString stringWithFormat:@"FAIL · %@", self.lastError];
            if (error) *error = self.lastError;
            return nil;
        }
        resolvedRVA = baseRVA + magnitude;
    }
    if ((resolvedRVA & 3ULL) != 0) {
        self.lastError = [NSString stringWithFormat:@"Named Offset 解析到 0x%llX，不是 4-byte ARM64 对齐", (unsigned long long)resolvedRVA];
        self.lastNamedResolution = [NSString stringWithFormat:@"FAIL · %@", self.lastError];
        if (error) *error = self.lastError;
        return nil;
    }

    NSString *canonical = candidate[@"canonical"] ?: parsed[@"raw"] ?: @"";
    NSString *rvaText = [NSString stringWithFormat:@"0x%llX", (unsigned long long)resolvedRVA];
    self.lastError = @"";
    self.lastNamedResolution = [NSString stringWithFormat:@"%@ → %@%@",
                                canonical,
                                rvaText,
                                delta ? [NSString stringWithFormat:@" (delta=%+lld)", (long long)delta] : @""];
    return @{
        @"target": @"UnityFramework",
        @"rva": @(resolvedRVA),
        @"rvaText": rvaText,
        @"methodRVA": @(baseRVA),
        @"methodPointer": @(pointer),
        @"methodInfo": candidate[@"methodInfo"] ?: @0,
        @"canonical": canonical,
        @"pointerSource": candidate[@"pointerSource"] ?: @"unavailable",
        @"delta": @(delta),
        @"searchMode": searchMode ?: @"unknown",
        @"assembly": candidate[@"assembly"] ?: @"",
        @"namespace": candidate[@"namespace"] ?: @"",
        @"class": candidate[@"class"] ?: @"",
        @"method": candidate[@"method"] ?: @"",
        @"argumentCount": candidate[@"argumentCount"] ?: @(-1),
    };
}

- (NSDictionary<NSString *,id> *)resolveMethodAssembly:(NSString *)assembly
                                              namespace:(NSString *)namespaceName
                                              className:(NSString *)className
                                                 method:(NSString *)methodName
                                          argumentCount:(NSInteger)argumentCount {
    [self refresh];
    if (!self.available) return nil;
    const void *image = [self imageForAssembly:assembly];
    if (!image) {
        self.lastError = [NSString stringWithFormat:@"找不到程序集：%@", assembly ?: @""];
        return nil;
    }

    void *klass = _classFromName(image,
                                 (namespaceName ?: @"").UTF8String,
                                 (className ?: @"").UTF8String);
    if (!klass) {
        self.lastError = [NSString stringWithFormat:@"找不到类：%@.%@", namespaceName ?: @"", className ?: @""];
        return nil;
    }

    const void *method = _classGetMethodFromName(klass, (methodName ?: @"").UTF8String, (int)argumentCount);
    if (!method) {
        self.lastError = [NSString stringWithFormat:@"找不到方法：%@/%ld", methodName ?: @"", (long)argumentCount];
        return nil;
    }

    NSString *pointerSource = nil;
    uintptr_t methodPointer = [self codePointerForMethod:method source:&pointerSource];
    self.lastError = @"";
    return @{
        @"image": @((uintptr_t)image),
        @"class": @((uintptr_t)klass),
        @"methodInfo": @((uintptr_t)method),
        @"methodPointer": @(methodPointer),
        @"pointerSource": pointerSource ?: @"unavailable",
    };
}

- (NSDictionary<NSString *,id> *)resolveFieldAssembly:(NSString *)assembly
                                             namespace:(NSString *)namespaceName
                                             className:(NSString *)className
                                                  field:(NSString *)fieldName {
    [self refresh];
    if (!self.available) return nil;
    if (!_classGetFieldFromName || !_fieldGetOffset) {
        self.lastError = @"当前 IL2CPP 未导出字段解析 API";
        return nil;
    }

    const void *image = [self imageForAssembly:assembly];
    if (!image) {
        self.lastError = [NSString stringWithFormat:@"找不到程序集：%@", assembly ?: @""];
        return nil;
    }

    void *klass = _classFromName(image,
                                 (namespaceName ?: @"").UTF8String,
                                 (className ?: @"").UTF8String);
    if (!klass) {
        self.lastError = [NSString stringWithFormat:@"找不到类：%@.%@", namespaceName ?: @"", className ?: @""];
        return nil;
    }

    void *field = _classGetFieldFromName(klass, (fieldName ?: @"").UTF8String);
    if (!field) {
        self.lastError = [NSString stringWithFormat:@"找不到字段：%@", fieldName ?: @""];
        return nil;
    }

    size_t offset = _fieldGetOffset(field);
    self.lastError = @"";
    return @{
        @"image": @((uintptr_t)image),
        @"class": @((uintptr_t)klass),
        @"fieldInfo": @((uintptr_t)field),
        @"offset": @((unsigned long long)offset),
    };
}

- (NSString *)diagnosticReport {
    NSDictionary *caps = self.capabilities;
    return [NSString stringWithFormat:
            @"IL2CPP 解析器: %@\nUnityFramework: %@\n类/方法解析: %@\n方法指针 API: %@\nMethodInfo 指针 fallback: 启用（必须落在 UnityFramework executable segment）\nNamed Offset 全局搜索: %@\n参数数量识别: %@\n字段解析: %@\nRuntime Invoke: %@\nJIT: 不依赖\n最近 Named Offset: %@\n错误: %@\n",
            self.available ? @"可用" : @"不可用",
            self.unityPath.length ? self.unityPath.lastPathComponent : @"未加载",
            [caps[@"method"] boolValue] ? @"可用" : @"不可用",
            [caps[@"methodPointer"] boolValue] ? @"可用" : @"未导出",
            [caps[@"namedSearch"] boolValue] ? @"可用" : @"不可用",
            [caps[@"methodParamCount"] boolValue] ? @"可用" : @"不可用",
            [caps[@"field"] boolValue] ? @"可用" : @"不可用",
            [caps[@"invoke"] boolValue] ? @"可用" : @"不可用",
            self.lastNamedResolution.length ? self.lastNamedResolution : @"尚未使用",
            self.lastError.length ? self.lastError : @"无"];
}
@end
