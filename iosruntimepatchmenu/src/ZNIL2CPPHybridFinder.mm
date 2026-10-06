#import "ZNIL2CPPHybridFinder.h"
#import "ZNIL2CPPResolver.h"

#import <CoreFoundation/CoreFoundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#import <dlfcn.h>
#import <stdint.h>
#import <string.h>

static const NSUInteger kZN57FinderMaxCandidates = 8;
static const NSUInteger kZN57FinderMaxClasses = 12000;
static const CFTimeInterval kZN57FinderTimeBudgetSeconds = 0.75;

typedef void *(*ZN57DomainGetFn)(void);
typedef const void **(*ZN57DomainGetAssembliesFn)(const void *, size_t *);
typedef const void *(*ZN57AssemblyGetImageFn)(const void *);
typedef const char *(*ZN57ImageGetNameFn)(const void *);
typedef size_t (*ZN57ImageGetClassCountFn)(const void *);
typedef void *(*ZN57ImageGetClassFn)(const void *, size_t);
typedef void *(*ZN57ClassFromNameFn)(const void *, const char *, const char *);
typedef const char *(*ZN57ClassGetNameFn)(void *);
typedef const char *(*ZN57ClassGetNamespaceFn)(void *);
typedef const void *(*ZN57ClassGetMethodsFn)(void *, void **);
typedef const void *(*ZN57ClassGetMethodFromNameFn)(void *, const char *, int);
typedef const char *(*ZN57MethodGetNameFn)(const void *);
typedef uint32_t (*ZN57MethodGetParamCountFn)(const void *);
typedef void *(*ZN57MethodGetPointerFn)(const void *);

static NSString *ZN57FinderTrim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ZN57FinderString(const char *value) {
    if (!value) return @"";
    NSString *s = [NSString stringWithUTF8String:value];
    return s ?: @"";
}

static NSString *ZN57FinderNormalizedAssembly(NSString *value) {
    NSString *s = ZN57FinderTrim(value).lowercaseString;
    return [s hasSuffix:@".dll"] ? [s substringToIndex:s.length - 4] : s;
}

static BOOL ZN57FinderAssemblyMatches(NSString *actual, NSString *wanted) {
    if (!wanted.length) return YES;
    return [ZN57FinderNormalizedAssembly(actual) isEqualToString:ZN57FinderNormalizedAssembly(wanted)];
}

static BOOL ZN57FinderCaseEqual(NSString *lhs, NSString *rhs) {
    return [ZN57FinderTrim(lhs) caseInsensitiveCompare:ZN57FinderTrim(rhs)] == NSOrderedSame;
}

@interface ZNIL2CPPHybridFinder ()
@property(nonatomic,copy,readwrite) NSString *lastError;
@property(nonatomic,copy,readwrite) NSDictionary<NSString *, id> *lastSearchStats;
@end

@implementation ZNIL2CPPHybridFinder {
    NSString *_unityPath;
    void *_handle;
    ZN57DomainGetFn _domainGet;
    ZN57DomainGetAssembliesFn _domainGetAssemblies;
    ZN57AssemblyGetImageFn _assemblyGetImage;
    ZN57ImageGetNameFn _imageGetName;
    ZN57ImageGetClassCountFn _imageGetClassCount;
    ZN57ImageGetClassFn _imageGetClass;
    ZN57ClassFromNameFn _classFromName;
    ZN57ClassGetNameFn _classGetName;
    ZN57ClassGetNamespaceFn _classGetNamespace;
    ZN57ClassGetMethodsFn _classGetMethods;
    ZN57ClassGetMethodFromNameFn _classGetMethodFromName;
    ZN57MethodGetNameFn _methodGetName;
    ZN57MethodGetParamCountFn _methodGetParamCount;
    ZN57MethodGetPointerFn _methodGetPointer;
}

+ (instancetype)sharedFinder {
    static ZNIL2CPPHybridFinder *finder;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ finder = [ZNIL2CPPHybridFinder new]; });
    return finder;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _unityPath = @"";
    _lastError = @"尚未搜索";
    _lastSearchStats = @{};
    return self;
}

- (NSString *)findUnityPath {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *cpath = _dyld_get_image_name(i);
        if (!cpath) continue;
        NSString *path = [NSString stringWithUTF8String:cpath];
        NSString *leaf = path.lastPathComponent;
        if ([leaf isEqualToString:@"UnityFramework"] ||
            [path rangeOfString:@"UnityFramework.framework/UnityFramework" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return path;
        }
    }
    return @"";
}

- (void *)resolveSymbol:(const char *)name {
    if (!name) return NULL;
    void *p = _handle ? dlsym(_handle, name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

- (BOOL)refreshRuntimeAPI:(NSString **)error {
    _unityPath = [self findUnityPath];
    if (!_unityPath.length) {
        if (error) *error = @"UnityFramework 尚未加载";
        return NO;
    }
#ifdef RTLD_NOLOAD
    _handle = dlopen(_unityPath.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
#else
    _handle = dlopen(_unityPath.fileSystemRepresentation, RTLD_LAZY);
#endif
    _domainGet = (ZN57DomainGetFn)[self resolveSymbol:"il2cpp_domain_get"];
    _domainGetAssemblies = (ZN57DomainGetAssembliesFn)[self resolveSymbol:"il2cpp_domain_get_assemblies"];
    _assemblyGetImage = (ZN57AssemblyGetImageFn)[self resolveSymbol:"il2cpp_assembly_get_image"];
    _imageGetName = (ZN57ImageGetNameFn)[self resolveSymbol:"il2cpp_image_get_name"];
    _imageGetClassCount = (ZN57ImageGetClassCountFn)[self resolveSymbol:"il2cpp_image_get_class_count"];
    _imageGetClass = (ZN57ImageGetClassFn)[self resolveSymbol:"il2cpp_image_get_class"];
    _classFromName = (ZN57ClassFromNameFn)[self resolveSymbol:"il2cpp_class_from_name"];
    _classGetName = (ZN57ClassGetNameFn)[self resolveSymbol:"il2cpp_class_get_name"];
    _classGetNamespace = (ZN57ClassGetNamespaceFn)[self resolveSymbol:"il2cpp_class_get_namespace"];
    _classGetMethods = (ZN57ClassGetMethodsFn)[self resolveSymbol:"il2cpp_class_get_methods"];
    _classGetMethodFromName = (ZN57ClassGetMethodFromNameFn)[self resolveSymbol:"il2cpp_class_get_method_from_name"];
    _methodGetName = (ZN57MethodGetNameFn)[self resolveSymbol:"il2cpp_method_get_name"];
    _methodGetParamCount = (ZN57MethodGetParamCountFn)[self resolveSymbol:"il2cpp_method_get_param_count"];
    _methodGetPointer = (ZN57MethodGetPointerFn)[self resolveSymbol:"il2cpp_method_get_pointer"];

    BOOL core = _domainGet && _domainGetAssemblies && _assemblyGetImage && _imageGetName &&
                _classFromName && _classGetMethodFromName;
    if (!core) {
        if (error) *error = @"IL2CPP Runtime API 不完整或已被隐藏";
        return NO;
    }
    return YES;
}

- (const void **)currentAssemblies:(size_t *)outCount {
    if (outCount) *outCount = 0;
    if (!_domainGet || !_domainGetAssemblies) return NULL;
    void *domain = _domainGet();
    if (!domain) return NULL;
    size_t count = 0;
    const void **assemblies = _domainGetAssemblies(domain, &count);
    if (outCount) *outCount = count;
    return assemblies;
}

- (BOOL)unityLayoutRuntimeBase:(uintptr_t *)runtimeBase preferredBase:(uint64_t *)preferredBase {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *cpath = _dyld_get_image_name(i);
        if (!cpath) continue;
        NSString *path = [NSString stringWithUTF8String:cpath];
        BOOL match = _unityPath.length && [path isEqualToString:_unityPath];
        if (!match) {
            NSString *leaf = path.lastPathComponent;
            match = [leaf isEqualToString:@"UnityFramework"] ||
                    [path rangeOfString:@"UnityFramework.framework/UnityFramework" options:NSCaseInsensitiveSearch].location != NSNotFound;
        }
        if (!match) continue;

        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) return NO;
        const uint8_t *cursor = (const uint8_t *)(mh + 1);
        const uint8_t *end = cursor + mh->sizeofcmds;
        for (uint32_t c = 0; c < mh->ncmds; c++) {
            if (cursor + sizeof(struct load_command) > end) return NO;
            const struct load_command *lc = (const struct load_command *)cursor;
            if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > end) return NO;
            if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
                if (strncmp(seg->segname, SEG_TEXT, 16) == 0) {
                    if (runtimeBase) *runtimeBase = (uintptr_t)mh;
                    if (preferredBase) *preferredBase = seg->vmaddr;
                    return YES;
                }
            }
            cursor += lc->cmdsize;
        }
        return NO;
    }
    return NO;
}

- (BOOL)isExecutableUnityAddress:(uintptr_t)address {
    uintptr_t runtimeBase = 0;
    uint64_t preferredBase = 0;
    if (![self unityLayoutRuntimeBase:&runtimeBase preferredBase:&preferredBase] || !address) return NO;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)runtimeBase;
    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    const uint8_t *end = cursor + mh->sizeofcmds;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > end) return NO;
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > end) return NO;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if (seg->initprot & VM_PROT_EXECUTE) {
                uintptr_t start = runtimeBase + (uintptr_t)(seg->vmaddr - preferredBase);
                uintptr_t endAddress = start + (uintptr_t)seg->vmsize;
                if (address >= start && address < endAddress) return YES;
            }
        }
        cursor += lc->cmdsize;
    }
    return NO;
}

- (uintptr_t)codePointerForMethod:(const void *)method source:(NSString **)source kind:(NSString **)kind {
    if (source) *source = @"unavailable";
    if (kind) *kind = @"unavailable";
    if (!method) return 0;

    if (_methodGetPointer) {
        uintptr_t pointer = (uintptr_t)_methodGetPointer(method);
        if ([self isExecutableUnityAddress:pointer]) {
            if (source) *source = @"il2cpp_method_get_pointer";
            if (kind) *kind = @"direct-api";
            return pointer;
        }
    }

    uintptr_t words[2] = {0, 0};
    memcpy(words, method, sizeof(words));
    if ([self isExecutableUnityAddress:words[0]]) {
        if (source) *source = @"MethodInfo[0]";
        if (kind) *kind = @"direct-fallback";
        return words[0];
    }
    if ([self isExecutableUnityAddress:words[1]]) {
        if (source) *source = @"MethodInfo[1]";
        if (kind) *kind = @"virtual-fallback";
        return words[1];
    }
    return 0;
}

- (NSDictionary<NSString *, id> *)candidateForMethod:(const void *)method
                                             assembly:(NSString *)assembly
                                            namespace:(NSString *)namespaceName
                                            className:(NSString *)className
                                           methodName:(NSString *)methodName
                                        argumentCount:(NSInteger)argumentCount {
    NSString *pointerSource = nil;
    NSString *pointerKind = nil;
    uintptr_t pointer = [self codePointerForMethod:method source:&pointerSource kind:&pointerKind];
    uintptr_t runtimeBase = 0;
    uint64_t preferredBase = 0;
    [self unityLayoutRuntimeBase:&runtimeBase preferredBase:&preferredBase];
    uint64_t rva = (pointer && runtimeBase && pointer >= runtimeBase) ? (uint64_t)(pointer - runtimeBase) : 0;
    uint64_t preferredVA = (preferredBase && rva) ? preferredBase + rva : 0;
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
        @"methodRVA": @(rva),
        @"methodPreferredVA": @(preferredVA),
        @"methodRuntimeVA": @(pointer),
        @"pointerSource": pointerSource ?: @"unavailable",
        @"pointerKind": pointerKind ?: @"unavailable",
        @"canonical": canonical,
    };
}

- (NSArray<NSDictionary<NSString *, id> *> *)methodsInClass:(void *)klass
                                                   assembly:(NSString *)assembly
                                                  namespace:(NSString *)namespaceName
                                                  className:(NSString *)className
                                                 methodName:(NSString *)methodName
                                              argumentCount:(NSInteger)argumentCount
                                         argumentSpecified:(BOOL)argumentSpecified
                                                     error:(NSString **)error {
    NSMutableArray *matches = [NSMutableArray array];
    if (_classGetMethods && _methodGetName) {
        void *iter = NULL;
        const void *method = NULL;
        while ((method = _classGetMethods(klass, &iter)) != NULL && matches.count < kZN57FinderMaxCandidates) {
            NSString *actualName = ZN57FinderString(_methodGetName(method));
            if (!ZN57FinderCaseEqual(actualName, methodName)) continue;
            NSInteger count = _methodGetParamCount ? (NSInteger)_methodGetParamCount(method) : -1;
            if (argumentSpecified) {
                if (!_methodGetParamCount) {
                    if (error) *error = @"当前 IL2CPP 未导出参数数量 API，无法安全匹配 /参数数量";
                    return nil;
                }
                if (count != argumentCount) continue;
            }
            [matches addObject:[self candidateForMethod:method
                                               assembly:assembly
                                              namespace:namespaceName
                                              className:className
                                             methodName:actualName
                                          argumentCount:count]];
        }
        return matches;
    }

    if (!argumentSpecified) {
        if (error) *error = @"该 IL2CPP 未导出方法枚举 API；请补充 /参数数量";
        return nil;
    }
    const void *method = _classGetMethodFromName(klass, methodName.UTF8String, (int)argumentCount);
    if (!method) return @[];
    NSString *actualName = _methodGetName ? ZN57FinderString(_methodGetName(method)) : methodName;
    return @[[self candidateForMethod:method
                             assembly:assembly
                            namespace:namespaceName
                            className:className
                           methodName:actualName
                        argumentCount:argumentCount]];
}

- (NSArray<NSDictionary<NSString *, id> *> *)qualifiedCandidates:(NSDictionary<NSString *, id> *)parsed
                                                            error:(NSString **)error {
    NSString *assemblyWanted = parsed[@"assembly"] ?: @"";
    NSString *namespaceName = parsed[@"namespace"] ?: @"";
    NSString *className = parsed[@"class"] ?: @"";
    NSString *methodName = parsed[@"method"] ?: @"";
    BOOL argumentSpecified = [parsed[@"argumentSpecified"] boolValue];
    NSInteger argumentCount = argumentSpecified ? [parsed[@"argumentCount"] integerValue] : -1;

    size_t assemblyCount = 0;
    const void **assemblies = [self currentAssemblies:&assemblyCount];
    if (!assemblies || !assemblyCount) {
        if (error) *error = @"IL2CPP Domain 尚无可用程序集";
        return nil;
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSMutableArray *matches = [NSMutableArray array];
    NSUInteger assembliesChecked = 0;
    for (NSUInteger pass = 0; pass < (assemblyWanted.length ? 1U : 2U) && matches.count < kZN57FinderMaxCandidates; pass++) {
        for (size_t i = 0; i < assemblyCount && matches.count < kZN57FinderMaxCandidates; i++) {
            const void *image = _assemblyGetImage(assemblies[i]);
            if (!image) continue;
            NSString *assemblyName = ZN57FinderString(_imageGetName(image));
            if (!ZN57FinderAssemblyMatches(assemblyName, assemblyWanted)) continue;
            if (!assemblyWanted.length) {
                BOOL preferred = [ZN57FinderNormalizedAssembly(assemblyName) isEqualToString:@"assembly-csharp"];
                if ((pass == 0 && !preferred) || (pass == 1 && preferred)) continue;
            }
            assembliesChecked++;
            void *klass = _classFromName(image, namespaceName.UTF8String, className.UTF8String);
            if (!klass) continue;
            NSString *localError = nil;
            NSArray *local = [self methodsInClass:klass
                                        assembly:assemblyName
                                       namespace:namespaceName
                                       className:className
                                      methodName:methodName
                                   argumentCount:argumentCount
                              argumentSpecified:argumentSpecified
                                          error:&localError];
            if (!local) {
                if (error) *error = localError;
                return nil;
            }
            for (NSDictionary *candidate in local) {
                if (matches.count >= kZN57FinderMaxCandidates) break;
                [matches addObject:candidate];
            }
        }
    }
    CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - started;
    self.lastSearchStats = @{
        @"mode": @"qualified",
        @"assembliesScanned": @(assembliesChecked),
        @"classesScanned": @(matches.count ? 1 : 0),
        @"elapsedMs": @(elapsed * 1000.0),
        @"candidateCount": @(matches.count),
        @"candidateLimit": @(kZN57FinderMaxCandidates),
        @"truncated": @(matches.count >= kZN57FinderMaxCandidates),
    };
    return matches;
}

- (NSArray<NSDictionary<NSString *, id> *> *)streamingCandidates:(NSDictionary<NSString *, id> *)parsed
                                                             error:(NSString **)error {
    if (!_imageGetClassCount || !_imageGetClass || !_classGetName || !_classGetNamespace || !_classGetMethods || !_methodGetName) {
        if (error) *error = @"当前 IL2CPP 未导出 bounded streaming 搜索所需 API；请使用完整 Namespace.Class::Method/参数数 或数字 RVA";
        return nil;
    }

    NSString *assemblyWanted = parsed[@"assembly"] ?: @"";
    NSString *namespaceWanted = parsed[@"namespace"] ?: @"";
    NSString *classWanted = parsed[@"class"] ?: @"";
    NSString *methodWanted = parsed[@"method"] ?: @"";
    BOOL namespaceSpecified = [parsed[@"namespaceSpecified"] boolValue];
    BOOL argumentSpecified = [parsed[@"argumentSpecified"] boolValue];
    NSInteger wantedArgumentCount = argumentSpecified ? [parsed[@"argumentCount"] integerValue] : -1;
    if (argumentSpecified && !_methodGetParamCount) {
        if (error) *error = @"当前 IL2CPP 未导出参数数量 API；bounded streaming 不能安全匹配 /参数数量";
        return nil;
    }

    size_t assemblyCount = 0;
    const void **assemblies = [self currentAssemblies:&assemblyCount];
    if (!assemblies || !assemblyCount) {
        if (error) *error = @"IL2CPP Domain 尚无可用程序集";
        return nil;
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSMutableArray *matches = [NSMutableArray arrayWithCapacity:kZN57FinderMaxCandidates];
    NSUInteger assembliesScanned = 0;
    NSUInteger classesScanned = 0;
    BOOL timeLimitHit = NO;
    BOOL classLimitHit = NO;
    BOOL candidateLimitHit = NO;

    NSUInteger passCount = assemblyWanted.length ? 1U : 2U;
    for (NSUInteger pass = 0; pass < passCount; pass++) {
        for (size_t a = 0; a < assemblyCount; a++) {
            if (matches.count >= kZN57FinderMaxCandidates) { candidateLimitHit = YES; goto done; }
            if (classesScanned >= kZN57FinderMaxClasses) { classLimitHit = YES; goto done; }
            if (CFAbsoluteTimeGetCurrent() - started >= kZN57FinderTimeBudgetSeconds) { timeLimitHit = YES; goto done; }

            const void *image = _assemblyGetImage(assemblies[a]);
            if (!image) continue;
            NSString *assemblyName = ZN57FinderString(_imageGetName(image));
            if (!ZN57FinderAssemblyMatches(assemblyName, assemblyWanted)) continue;
            if (!assemblyWanted.length) {
                BOOL preferred = [ZN57FinderNormalizedAssembly(assemblyName) isEqualToString:@"assembly-csharp"];
                if ((pass == 0 && !preferred) || (pass == 1 && preferred)) continue;
            }
            assembliesScanned++;

            size_t classCount = _imageGetClassCount(image);
            for (size_t c = 0; c < classCount; c++) {
                if (matches.count >= kZN57FinderMaxCandidates) { candidateLimitHit = YES; goto done; }
                if (classesScanned >= kZN57FinderMaxClasses) { classLimitHit = YES; goto done; }
                if ((classesScanned & 0x1F) == 0 && CFAbsoluteTimeGetCurrent() - started >= kZN57FinderTimeBudgetSeconds) {
                    timeLimitHit = YES;
                    goto done;
                }
                classesScanned++;

                @autoreleasepool {
                    void *klass = _imageGetClass(image, c);
                    if (!klass) continue;
                    NSString *className = ZN57FinderString(_classGetName(klass));
                    NSString *namespaceName = ZN57FinderString(_classGetNamespace(klass));
                    if (classWanted.length && !ZN57FinderCaseEqual(className, classWanted)) continue;
                    if (namespaceSpecified && !ZN57FinderCaseEqual(namespaceName, namespaceWanted)) continue;

                    void *iter = NULL;
                    const void *method = NULL;
                    while ((method = _classGetMethods(klass, &iter)) != NULL) {
                        NSString *actualName = ZN57FinderString(_methodGetName(method));
                        if (!ZN57FinderCaseEqual(actualName, methodWanted)) continue;
                        NSInteger argumentCount = _methodGetParamCount ? (NSInteger)_methodGetParamCount(method) : -1;
                        if (argumentSpecified && argumentCount != wantedArgumentCount) continue;
                        [matches addObject:[self candidateForMethod:method
                                                           assembly:assemblyName
                                                          namespace:namespaceName
                                                          className:className
                                                         methodName:actualName
                                                      argumentCount:argumentCount]];
                        if (matches.count >= kZN57FinderMaxCandidates) {
                            candidateLimitHit = YES;
                            goto done;
                        }
                    }
                }
            }
        }
    }

done:
    CFTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - started;
    BOOL incomplete = timeLimitHit || classLimitHit;
    self.lastSearchStats = @{
        @"mode": @"bounded-stream",
        @"assemblyPriority": @"Assembly-CSharp-first",
        @"assembliesScanned": @(assembliesScanned),
        @"classesScanned": @(classesScanned),
        @"elapsedMs": @(elapsed * 1000.0),
        @"candidateCount": @(matches.count),
        @"candidateLimit": @(kZN57FinderMaxCandidates),
        @"classLimit": @(kZN57FinderMaxClasses),
        @"timeBudgetMs": @(kZN57FinderTimeBudgetSeconds * 1000.0),
        @"candidateLimitHit": @(candidateLimitHit),
        @"classLimitHit": @(classLimitHit),
        @"timeLimitHit": @(timeLimitHit),
        @"truncated": @(incomplete || candidateLimitHit),
    };

    if (incomplete && matches.count < 2) {
        NSString *reason = timeLimitHit ? @"耗时预算" : @"类扫描预算";
        if (error) {
            *error = [NSString stringWithFormat:@"Method Finder 达到%@上限（classes=%lu, %.0fms），无法确认结果唯一；请补充 Class/Namespace 或 Assembly",
                      reason,
                      (unsigned long)classesScanned,
                      elapsed * 1000.0];
        }
        return nil;
    }
    return matches;
}

- (NSDictionary<NSString *, id> *)resolveExpression:(NSString *)expression error:(NSString **)error {
    self.lastError = @"";
    self.lastSearchStats = @{};

    NSString *parseError = nil;
    NSDictionary *parsed = [ZNIL2CPPResolver parseNamedOffsetExpression:expression error:&parseError];
    if (!parsed) {
        self.lastError = parseError ?: @"Method Finder 表达式解析失败";
        if (error) *error = self.lastError;
        return nil;
    }

    NSString *runtimeError = nil;
    if (![self refreshRuntimeAPI:&runtimeError]) {
        self.lastError = runtimeError ?: @"IL2CPP Runtime 不可用";
        if (error) *error = self.lastError;
        return nil;
    }

    NSString *className = parsed[@"class"] ?: @"";
    BOOL namespaceSpecified = [parsed[@"namespaceSpecified"] boolValue];
    NSString *searchError = nil;
    NSArray<NSDictionary<NSString *, id> *> *matches = nil;
    NSString *searchMode = nil;
    if (className.length && namespaceSpecified) {
        searchMode = @"qualified";
        matches = [self qualifiedCandidates:parsed error:&searchError];
    } else {
        searchMode = @"bounded-stream";
        matches = [self streamingCandidates:parsed error:&searchError];
    }

    if (!matches) {
        self.lastError = searchError ?: @"Method Finder 搜索失败";
        if (error) *error = self.lastError;
        return nil;
    }
    if (!matches.count) {
        self.lastError = [NSString stringWithFormat:@"找不到 IL2CPP 方法：%@", parsed[@"raw"] ?: expression ?: @""];
        if (error) *error = self.lastError;
        return nil;
    }
    if (matches.count != 1) {
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        for (NSUInteger i = 0; i < MIN((NSUInteger)5, matches.count); i++) {
            [labels addObject:matches[i][@"canonical"] ?: @"?"];
        }
        NSString *suffix = matches.count >= kZN57FinderMaxCandidates
            ? [NSString stringWithFormat:@"至少 %lu", (unsigned long)kZN57FinderMaxCandidates]
            : [NSString stringWithFormat:@"%lu", (unsigned long)matches.count];
        self.lastError = [NSString stringWithFormat:@"Method Finder 不唯一（%@ 个候选）：%@。请补充 Class::Method/参数数 或 Assembly-CSharp.dll!Namespace.Class::Method/参数数",
                          suffix,
                          [labels componentsJoinedByString:@" | "]];
        if (error) *error = self.lastError;
        return nil;
    }

    NSDictionary *candidate = matches.firstObject;
    uintptr_t methodPointer = (uintptr_t)[candidate[@"methodPointer"] unsignedLongLongValue];
    uint64_t methodRVA = [candidate[@"methodRVA"] unsignedLongLongValue];
    if (!methodPointer || !methodRVA) {
        self.lastError = [NSString stringWithFormat:@"已找到 %@，但无法取得可验证的 UnityFramework 代码指针",
                          candidate[@"canonical"] ?: parsed[@"raw"] ?: @"方法"];
        if (error) *error = self.lastError;
        return nil;
    }

    int64_t delta = [parsed[@"delta"] longLongValue];
    uint64_t resolvedRVA = methodRVA;
    if (delta < 0) {
        uint64_t magnitude = (uint64_t)(-delta);
        if (magnitude > methodRVA) {
            self.lastError = @"Method Finder delta 导致 RVA 下溢";
            if (error) *error = self.lastError;
            return nil;
        }
        resolvedRVA = methodRVA - magnitude;
    } else if (delta > 0) {
        uint64_t magnitude = (uint64_t)delta;
        if (methodRVA > UINT64_MAX - magnitude) {
            self.lastError = @"Method Finder delta 导致 RVA 上溢";
            if (error) *error = self.lastError;
            return nil;
        }
        resolvedRVA = methodRVA + magnitude;
    }
    if ((resolvedRVA & 3ULL) != 0) {
        self.lastError = [NSString stringWithFormat:@"Method Finder 解析到 0x%llX，不是 4-byte ARM64 对齐", (unsigned long long)resolvedRVA];
        if (error) *error = self.lastError;
        return nil;
    }

    uintptr_t runtimeBase = 0;
    uint64_t preferredBase = 0;
    if (![self unityLayoutRuntimeBase:&runtimeBase preferredBase:&preferredBase]) {
        self.lastError = @"无法读取 UnityFramework Mach-O __TEXT.vmaddr";
        if (error) *error = self.lastError;
        return nil;
    }
    uintptr_t runtimeVA = runtimeBase + (uintptr_t)resolvedRVA;
    uint64_t preferredVA = preferredBase + resolvedRVA;
    if (![self isExecutableUnityAddress:runtimeVA]) {
        self.lastError = [NSString stringWithFormat:@"解析地址 0x%llX 不在 UnityFramework executable segment", (unsigned long long)resolvedRVA];
        if (error) *error = self.lastError;
        return nil;
    }

    NSString *canonical = candidate[@"canonical"] ?: parsed[@"raw"] ?: @"";
    NSString *rvaText = [NSString stringWithFormat:@"0x%llX", (unsigned long long)resolvedRVA];
    self.lastError = @"";
    return @{
        @"target": @"UnityFramework",
        @"rva": @(resolvedRVA),
        @"rvaText": rvaText,
        @"preferredVA": @(preferredVA),
        @"runtimeVA": @((uint64_t)runtimeVA),
        @"preferredTextVMAddr": @(preferredBase),
        @"runtimeImageBase": @((uint64_t)runtimeBase),
        @"slide": @((int64_t)runtimeBase - (int64_t)preferredBase),
        @"methodRVA": @(methodRVA),
        @"methodPreferredVA": candidate[@"methodPreferredVA"] ?: @0,
        @"methodRuntimeVA": candidate[@"methodRuntimeVA"] ?: @0,
        @"methodPointer": @(methodPointer),
        @"methodInfo": candidate[@"methodInfo"] ?: @0,
        @"canonical": canonical,
        @"pointerSource": candidate[@"pointerSource"] ?: @"unavailable",
        @"pointerKind": candidate[@"pointerKind"] ?: @"unavailable",
        @"delta": @(delta),
        @"searchMode": searchMode ?: @"unknown",
        @"searchStats": self.lastSearchStats ?: @{},
        @"assembly": candidate[@"assembly"] ?: @"",
        @"namespace": candidate[@"namespace"] ?: @"",
        @"class": candidate[@"class"] ?: @"",
        @"method": candidate[@"method"] ?: @"",
        @"argumentCount": candidate[@"argumentCount"] ?: @(-1),
    };
}

@end
