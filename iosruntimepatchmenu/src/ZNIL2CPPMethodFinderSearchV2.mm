#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import <CoreFoundation/CoreFoundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#import <dlfcn.h>
#import <errno.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

#import "ZNIL2CPPHybridFinder.h"
#import "ZNIL2CPPResolver.h"

// Method Finder V2 keeps the low-memory runtime-metadata approach but changes
// 12k classes from a total hard-stop into a shard size. Bare-name searches walk
// shard after shard without rescanning earlier classes. A strict overall wall
// clock guard remains to avoid pathological UI stalls on malformed runtimes.
// Hex-only input (0x...) is interpreted as a UnityFramework RVA reverse lookup.

static const NSUInteger kZN58FinderShardClasses = 12000;
static const NSUInteger kZN58FinderMaxCandidates = 8;
static const CFTimeInterval kZN58FinderWallBudgetSeconds = 6.0;
static const NSUInteger kZN58FinderMaxExecRanges = 16;

typedef void *(*ZN58DomainGetFn)(void);
typedef const void **(*ZN58DomainGetAssembliesFn)(const void *, size_t *);
typedef const void *(*ZN58AssemblyGetImageFn)(const void *);
typedef const char *(*ZN58ImageGetNameFn)(const void *);
typedef size_t (*ZN58ImageGetClassCountFn)(const void *);
typedef void *(*ZN58ImageGetClassFn)(const void *, size_t);
typedef const char *(*ZN58ClassGetNameFn)(void *);
typedef const char *(*ZN58ClassGetNamespaceFn)(void *);
typedef const void *(*ZN58ClassGetMethodsFn)(void *, void **);
typedef const char *(*ZN58MethodGetNameFn)(const void *);
typedef uint32_t (*ZN58MethodGetParamCountFn)(const void *);
typedef void *(*ZN58MethodGetPointerFn)(const void *);

typedef struct {
    void *handle;
    uintptr_t runtimeBase;
    uint64_t preferredBase;
    uintptr_t execStarts[kZN58FinderMaxExecRanges];
    uintptr_t execEnds[kZN58FinderMaxExecRanges];
    NSUInteger execCount;

    ZN58DomainGetFn domainGet;
    ZN58DomainGetAssembliesFn domainGetAssemblies;
    ZN58AssemblyGetImageFn assemblyGetImage;
    ZN58ImageGetNameFn imageGetName;
    ZN58ImageGetClassCountFn imageGetClassCount;
    ZN58ImageGetClassFn imageGetClass;
    ZN58ClassGetNameFn classGetName;
    ZN58ClassGetNamespaceFn classGetNamespace;
    ZN58ClassGetMethodsFn classGetMethods;
    ZN58MethodGetNameFn methodGetName;
    ZN58MethodGetParamCountFn methodGetParamCount;
    ZN58MethodGetPointerFn methodGetPointer;
} ZN58Runtime;

static NSString *ZN58Trim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ZN58String(const char *value) {
    if (!value) return @"";
    NSString *s = [NSString stringWithUTF8String:value];
    return s ?: @"";
}

static NSString *ZN58NormalizedAssembly(NSString *value) {
    NSString *s = ZN58Trim(value).lowercaseString;
    return [s hasSuffix:@".dll"] ? [s substringToIndex:s.length - 4] : s;
}

static BOOL ZN58AssemblyMatches(NSString *actual, NSString *wanted) {
    if (!wanted.length) return YES;
    return [ZN58NormalizedAssembly(actual) isEqualToString:ZN58NormalizedAssembly(wanted)];
}

static BOOL ZN58CaseEqual(NSString *lhs, NSString *rhs) {
    return [ZN58Trim(lhs) caseInsensitiveCompare:ZN58Trim(rhs)] == NSOrderedSame;
}

static BOOL ZN58ParseRVAInput(NSString *input, uint64_t *value) {
    NSString *s = ZN58Trim(input);
    if ([s.lowercaseString hasPrefix:@"rva:"]) s = ZN58Trim([s substringFromIndex:4]);
    if (s.length < 3 || ![s.lowercaseString hasPrefix:@"0x"]) return NO;

    const char *c = s.UTF8String;
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(c, &end, 0);
    if (errno || end == c || (end && *end)) return NO;
    if (value) *value = (uint64_t)parsed;
    return YES;
}

static void *ZN58ResolveSymbol(ZN58Runtime *runtime, const char *name) {
    if (!name) return NULL;
    void *p = runtime->handle ? dlsym(runtime->handle, name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

static BOOL ZN58IsExecutable(const ZN58Runtime *runtime, uintptr_t address) {
    if (!address) return NO;
    for (NSUInteger i = 0; i < runtime->execCount; i++) {
        if (address >= runtime->execStarts[i] && address < runtime->execEnds[i]) return YES;
    }
    return NO;
}

static BOOL ZN58LoadRuntime(ZN58Runtime *runtime, NSString **error) {
    memset(runtime, 0, sizeof(*runtime));

    NSString *unityPath = @"";
    const struct mach_header_64 *unityHeader = NULL;
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *cpath = _dyld_get_image_name(i);
        if (!cpath) continue;
        NSString *path = [NSString stringWithUTF8String:cpath] ?: @"";
        NSString *leaf = path.lastPathComponent;
        if ([leaf isEqualToString:@"UnityFramework"] ||
            [path rangeOfString:@"UnityFramework.framework/UnityFramework" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            unityPath = path;
            unityHeader = (const struct mach_header_64 *)_dyld_get_image_header(i);
            break;
        }
    }

    if (!unityPath.length || !unityHeader || unityHeader->magic != MH_MAGIC_64) {
        if (error) *error = @"UnityFramework 尚未加载或不是 arm64 Mach-O";
        return NO;
    }

    runtime->runtimeBase = (uintptr_t)unityHeader;

    const uint8_t *cursor = (const uint8_t *)(unityHeader + 1);
    const uint8_t *commandsEnd = cursor + unityHeader->sizeofcmds;
    for (uint32_t i = 0; i < unityHeader->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commandsEnd) break;
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > commandsEnd) break;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if (strncmp(seg->segname, SEG_TEXT, 16) == 0) {
                runtime->preferredBase = seg->vmaddr;
                break;
            }
        }
        cursor += lc->cmdsize;
    }

    if (!runtime->preferredBase) {
        if (error) *error = @"无法读取 UnityFramework Mach-O __TEXT.vmaddr";
        return NO;
    }

    cursor = (const uint8_t *)(unityHeader + 1);
    for (uint32_t i = 0; i < unityHeader->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commandsEnd) break;
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > commandsEnd) break;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if ((seg->initprot & VM_PROT_EXECUTE) && seg->vmaddr >= runtime->preferredBase && runtime->execCount < kZN58FinderMaxExecRanges) {
                uintptr_t start = runtime->runtimeBase + (uintptr_t)(seg->vmaddr - runtime->preferredBase);
                runtime->execStarts[runtime->execCount] = start;
                runtime->execEnds[runtime->execCount] = start + (uintptr_t)seg->vmsize;
                runtime->execCount++;
            }
        }
        cursor += lc->cmdsize;
    }

    if (!runtime->execCount) {
        if (error) *error = @"UnityFramework 没有可验证的 executable segment";
        return NO;
    }

#ifdef RTLD_NOLOAD
    runtime->handle = dlopen(unityPath.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
#else
    runtime->handle = dlopen(unityPath.fileSystemRepresentation, RTLD_LAZY);
#endif

    runtime->domainGet = (ZN58DomainGetFn)ZN58ResolveSymbol(runtime, "il2cpp_domain_get");
    runtime->domainGetAssemblies = (ZN58DomainGetAssembliesFn)ZN58ResolveSymbol(runtime, "il2cpp_domain_get_assemblies");
    runtime->assemblyGetImage = (ZN58AssemblyGetImageFn)ZN58ResolveSymbol(runtime, "il2cpp_assembly_get_image");
    runtime->imageGetName = (ZN58ImageGetNameFn)ZN58ResolveSymbol(runtime, "il2cpp_image_get_name");
    runtime->imageGetClassCount = (ZN58ImageGetClassCountFn)ZN58ResolveSymbol(runtime, "il2cpp_image_get_class_count");
    runtime->imageGetClass = (ZN58ImageGetClassFn)ZN58ResolveSymbol(runtime, "il2cpp_image_get_class");
    runtime->classGetName = (ZN58ClassGetNameFn)ZN58ResolveSymbol(runtime, "il2cpp_class_get_name");
    runtime->classGetNamespace = (ZN58ClassGetNamespaceFn)ZN58ResolveSymbol(runtime, "il2cpp_class_get_namespace");
    runtime->classGetMethods = (ZN58ClassGetMethodsFn)ZN58ResolveSymbol(runtime, "il2cpp_class_get_methods");
    runtime->methodGetName = (ZN58MethodGetNameFn)ZN58ResolveSymbol(runtime, "il2cpp_method_get_name");
    runtime->methodGetParamCount = (ZN58MethodGetParamCountFn)ZN58ResolveSymbol(runtime, "il2cpp_method_get_param_count");
    runtime->methodGetPointer = (ZN58MethodGetPointerFn)ZN58ResolveSymbol(runtime, "il2cpp_method_get_pointer");

    BOOL core = runtime->domainGet && runtime->domainGetAssemblies && runtime->assemblyGetImage && runtime->imageGetName &&
                runtime->imageGetClassCount && runtime->imageGetClass && runtime->classGetName && runtime->classGetNamespace &&
                runtime->classGetMethods && runtime->methodGetName;
    if (!core) {
        if (error) *error = @"IL2CPP Runtime 缺少分片搜索所需 API";
        if (runtime->handle) dlclose(runtime->handle);
        memset(runtime, 0, sizeof(*runtime));
        return NO;
    }
    return YES;
}

static void ZN58CloseRuntime(ZN58Runtime *runtime) {
    if (runtime->handle) dlclose(runtime->handle);
    runtime->handle = NULL;
}

static const void **ZN58Assemblies(ZN58Runtime *runtime, size_t *outCount) {
    if (outCount) *outCount = 0;
    void *domain = runtime->domainGet ? runtime->domainGet() : NULL;
    if (!domain || !runtime->domainGetAssemblies) return NULL;
    size_t count = 0;
    const void **assemblies = runtime->domainGetAssemblies(domain, &count);
    if (outCount) *outCount = count;
    return assemblies;
}

static uintptr_t ZN58MethodPointer(ZN58Runtime *runtime,
                                   const void *method,
                                   NSString **source,
                                   NSString **kind) {
    if (source) *source = @"unavailable";
    if (kind) *kind = @"unavailable";
    if (!method) return 0;

    if (runtime->methodGetPointer) {
        uintptr_t pointer = (uintptr_t)runtime->methodGetPointer(method);
        if (ZN58IsExecutable(runtime, pointer)) {
            if (source) *source = @"il2cpp_method_get_pointer";
            if (kind) *kind = @"direct-api";
            return pointer;
        }
    }

    uintptr_t words[2] = {0, 0};
    memcpy(words, method, sizeof(words));
    if (ZN58IsExecutable(runtime, words[0])) {
        if (source) *source = @"MethodInfo[0]";
        if (kind) *kind = @"direct-fallback";
        return words[0];
    }
    if (ZN58IsExecutable(runtime, words[1])) {
        if (source) *source = @"MethodInfo[1]";
        if (kind) *kind = @"virtual-fallback";
        return words[1];
    }
    return 0;
}

static NSDictionary<NSString *, id> *ZN58Candidate(ZN58Runtime *runtime,
                                                    const void *method,
                                                    NSString *assembly,
                                                    NSString *namespaceName,
                                                    NSString *className,
                                                    NSString *methodName,
                                                    NSInteger argumentCount) {
    NSString *pointerSource = nil;
    NSString *pointerKind = nil;
    uintptr_t pointer = ZN58MethodPointer(runtime, method, &pointerSource, &pointerKind);
    uint64_t rva = (pointer >= runtime->runtimeBase) ? (uint64_t)(pointer - runtime->runtimeBase) : 0;
    uint64_t preferredVA = (rva && runtime->preferredBase) ? runtime->preferredBase + rva : 0;
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

static NSDictionary<NSString *, id> *ZN58Stats(NSString *mode,
                                                CFAbsoluteTime started,
                                                NSUInteger assembliesScanned,
                                                NSUInteger classesScanned,
                                                NSUInteger shardsScanned,
                                                NSUInteger candidateCount,
                                                BOOL timedOut,
                                                BOOL candidateLimitHit,
                                                BOOL stoppedAtPreferredAssembly) {
    return @{
        @"mode": mode ?: @"unknown",
        @"assemblyPriority": @"Assembly-CSharp-first",
        @"assembliesScanned": @(assembliesScanned),
        @"classesScanned": @(classesScanned),
        @"shardsScanned": @(shardsScanned),
        @"shardSize": @(kZN58FinderShardClasses),
        @"elapsedMs": @((CFAbsoluteTimeGetCurrent() - started) * 1000.0),
        @"candidateCount": @(candidateCount),
        @"candidateLimit": @(kZN58FinderMaxCandidates),
        @"wallBudgetMs": @(kZN58FinderWallBudgetSeconds * 1000.0),
        @"timeLimitHit": @(timedOut),
        @"candidateLimitHit": @(candidateLimitHit),
        @"stoppedAtPreferredAssembly": @(stoppedAtPreferredAssembly),
        @"truncated": @(timedOut || candidateLimitHit),
    };
}

static NSArray<NSDictionary<NSString *, id> *> *ZN58ShardedNameSearch(ZN58Runtime *runtime,
                                                                       NSDictionary<NSString *, id> *parsed,
                                                                       NSDictionary<NSString *, id> **outStats,
                                                                       NSString **error) {
    NSString *assemblyWanted = parsed[@"assembly"] ?: @"";
    NSString *namespaceWanted = parsed[@"namespace"] ?: @"";
    NSString *classWanted = parsed[@"class"] ?: @"";
    NSString *methodWanted = parsed[@"method"] ?: @"";
    BOOL namespaceSpecified = [parsed[@"namespaceSpecified"] boolValue];
    BOOL argumentSpecified = [parsed[@"argumentSpecified"] boolValue];
    NSInteger wantedArgumentCount = argumentSpecified ? [parsed[@"argumentCount"] integerValue] : -1;

    if (argumentSpecified && !runtime->methodGetParamCount) {
        if (error) *error = @"当前 IL2CPP 未导出参数数量 API，无法安全匹配 /参数数量";
        return nil;
    }

    size_t assemblyCount = 0;
    const void **assemblies = ZN58Assemblies(runtime, &assemblyCount);
    if (!assemblies || !assemblyCount) {
        if (error) *error = @"IL2CPP Domain 尚无可用程序集";
        return nil;
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSMutableArray<NSDictionary<NSString *, id> *> *matches = [NSMutableArray arrayWithCapacity:kZN58FinderMaxCandidates];
    NSUInteger assembliesScanned = 0;
    NSUInteger classesScanned = 0;
    NSUInteger shardsScanned = 0;
    BOOL timedOut = NO;
    BOOL candidateLimitHit = NO;
    BOOL stoppedAtPreferredAssembly = NO;
    BOOL stop = NO;

    NSUInteger passCount = assemblyWanted.length ? 1U : 2U;
    for (NSUInteger pass = 0; pass < passCount && !stop; pass++) {
        for (size_t a = 0; a < assemblyCount && !stop; a++) {
            const void *image = runtime->assemblyGetImage(assemblies[a]);
            if (!image) continue;
            NSString *assemblyName = ZN58String(runtime->imageGetName(image));
            if (!ZN58AssemblyMatches(assemblyName, assemblyWanted)) continue;
            if (!assemblyWanted.length) {
                BOOL preferred = [ZN58NormalizedAssembly(assemblyName) isEqualToString:@"assembly-csharp"];
                if ((pass == 0 && !preferred) || (pass == 1 && preferred)) continue;
            }

            assembliesScanned++;
            size_t classCount = runtime->imageGetClassCount(image);
            for (size_t shardStart = 0; shardStart < classCount && !stop; shardStart += kZN58FinderShardClasses) {
                size_t shardEnd = MIN(classCount, shardStart + kZN58FinderShardClasses);
                shardsScanned++;

                for (size_t c = shardStart; c < shardEnd; c++) {
                    if ((classesScanned & 0x3F) == 0 && CFAbsoluteTimeGetCurrent() - started >= kZN58FinderWallBudgetSeconds) {
                        timedOut = YES;
                        stop = YES;
                        break;
                    }
                    classesScanned++;

                    @autoreleasepool {
                        void *klass = runtime->imageGetClass(image, c);
                        if (!klass) continue;
                        NSString *className = ZN58String(runtime->classGetName(klass));
                        NSString *namespaceName = ZN58String(runtime->classGetNamespace(klass));
                        if (classWanted.length && !ZN58CaseEqual(className, classWanted)) continue;
                        if (namespaceSpecified && !ZN58CaseEqual(namespaceName, namespaceWanted)) continue;

                        void *iter = NULL;
                        const void *method = NULL;
                        while ((method = runtime->classGetMethods(klass, &iter)) != NULL) {
                            NSString *actualName = ZN58String(runtime->methodGetName(method));
                            if (!ZN58CaseEqual(actualName, methodWanted)) continue;
                            NSInteger argumentCount = runtime->methodGetParamCount ? (NSInteger)runtime->methodGetParamCount(method) : -1;
                            if (argumentSpecified && argumentCount != wantedArgumentCount) continue;

                            [matches addObject:ZN58Candidate(runtime,
                                                            method,
                                                            assemblyName,
                                                            namespaceName,
                                                            className,
                                                            actualName,
                                                            argumentCount)];
                            if (matches.count >= kZN58FinderMaxCandidates) {
                                candidateLimitHit = YES;
                                stop = YES;
                                break;
                            }
                        }
                    }
                }
            }
        }

        // Bare-name search semantics deliberately prioritize Assembly-CSharp.
        // Once that preferred assembly has been exhaustively scanned and has at
        // least one candidate, do not scan unrelated framework assemblies just
        // to manufacture global-name ambiguity.
        if (!assemblyWanted.length && pass == 0 && !timedOut && matches.count > 0) {
            stoppedAtPreferredAssembly = YES;
            break;
        }
    }

    NSDictionary *stats = ZN58Stats(@"sharded-stream",
                                     started,
                                     assembliesScanned,
                                     classesScanned,
                                     shardsScanned,
                                     matches.count,
                                     timedOut,
                                     candidateLimitHit,
                                     stoppedAtPreferredAssembly);
    if (outStats) *outStats = stats;

    if (timedOut) {
        if (error) {
            *error = [NSString stringWithFormat:@"Method Finder 已连续扫描 %lu 个 Class（%lu 个分片）但达到 %.0fms 安全预算；没有重扫前 12000 类。请补充 Class/Namespace/Assembly 或使用 RVA 反查",
                      (unsigned long)classesScanned,
                      (unsigned long)shardsScanned,
                      kZN58FinderWallBudgetSeconds * 1000.0];
        }
        return nil;
    }
    return matches;
}

static NSArray<NSDictionary<NSString *, id> *> *ZN58ReverseRVASearch(ZN58Runtime *runtime,
                                                                      uint64_t targetRVA,
                                                                      NSDictionary<NSString *, id> **outStats,
                                                                      NSString **error) {
    if ((targetRVA & 3ULL) != 0) {
        if (error) *error = @"RVA 反查要求 4-byte ARM64 对齐";
        return nil;
    }
    if (targetRVA > UINTPTR_MAX - runtime->runtimeBase) {
        if (error) *error = @"RVA 超出当前进程地址范围";
        return nil;
    }
    uintptr_t targetRuntime = runtime->runtimeBase + (uintptr_t)targetRVA;
    if (!ZN58IsExecutable(runtime, targetRuntime)) {
        if (error) *error = [NSString stringWithFormat:@"RVA 0x%llX 不在 UnityFramework executable segment", (unsigned long long)targetRVA];
        return nil;
    }

    size_t assemblyCount = 0;
    const void **assemblies = ZN58Assemblies(runtime, &assemblyCount);
    if (!assemblies || !assemblyCount) {
        if (error) *error = @"IL2CPP Domain 尚无可用程序集";
        return nil;
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSMutableArray<NSDictionary<NSString *, id> *> *matches = [NSMutableArray arrayWithCapacity:kZN58FinderMaxCandidates];
    NSUInteger assembliesScanned = 0;
    NSUInteger classesScanned = 0;
    NSUInteger shardsScanned = 0;
    BOOL timedOut = NO;
    BOOL candidateLimitHit = NO;
    BOOL stop = NO;

    // Two passes keep Assembly-CSharp results first, but unlike name search the
    // reverse lookup continues through all assemblies because generic/shared
    // methods can legally map multiple MethodInfo records to one native RVA.
    for (NSUInteger pass = 0; pass < 2 && !stop; pass++) {
        for (size_t a = 0; a < assemblyCount && !stop; a++) {
            const void *image = runtime->assemblyGetImage(assemblies[a]);
            if (!image) continue;
            NSString *assemblyName = ZN58String(runtime->imageGetName(image));
            BOOL preferred = [ZN58NormalizedAssembly(assemblyName) isEqualToString:@"assembly-csharp"];
            if ((pass == 0 && !preferred) || (pass == 1 && preferred)) continue;

            assembliesScanned++;
            size_t classCount = runtime->imageGetClassCount(image);
            for (size_t shardStart = 0; shardStart < classCount && !stop; shardStart += kZN58FinderShardClasses) {
                size_t shardEnd = MIN(classCount, shardStart + kZN58FinderShardClasses);
                shardsScanned++;

                for (size_t c = shardStart; c < shardEnd; c++) {
                    if ((classesScanned & 0x3F) == 0 && CFAbsoluteTimeGetCurrent() - started >= kZN58FinderWallBudgetSeconds) {
                        timedOut = YES;
                        stop = YES;
                        break;
                    }
                    classesScanned++;

                    @autoreleasepool {
                        void *klass = runtime->imageGetClass(image, c);
                        if (!klass) continue;

                        void *iter = NULL;
                        const void *method = NULL;
                        while ((method = runtime->classGetMethods(klass, &iter)) != NULL) {
                            uintptr_t pointer = ZN58MethodPointer(runtime, method, NULL, NULL);
                            if (!pointer || pointer < runtime->runtimeBase) continue;
                            uint64_t rva = (uint64_t)(pointer - runtime->runtimeBase);
                            if (rva != targetRVA) continue;

                            NSString *className = ZN58String(runtime->classGetName(klass));
                            NSString *namespaceName = ZN58String(runtime->classGetNamespace(klass));
                            NSString *methodName = ZN58String(runtime->methodGetName(method));
                            NSInteger argumentCount = runtime->methodGetParamCount ? (NSInteger)runtime->methodGetParamCount(method) : -1;
                            [matches addObject:ZN58Candidate(runtime,
                                                            method,
                                                            assemblyName,
                                                            namespaceName,
                                                            className,
                                                            methodName,
                                                            argumentCount)];
                            if (matches.count >= kZN58FinderMaxCandidates) {
                                candidateLimitHit = YES;
                                stop = YES;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    NSDictionary *stats = ZN58Stats(@"reverse-rva",
                                     started,
                                     assembliesScanned,
                                     classesScanned,
                                     shardsScanned,
                                     matches.count,
                                     timedOut,
                                     candidateLimitHit,
                                     NO);
    if (outStats) *outStats = stats;

    if (timedOut) {
        if (error) {
            *error = [NSString stringWithFormat:@"RVA 反查已扫描 %lu 个 Class（%lu 个分片）但达到 %.0fms 安全预算，无法确认 MethodInfo 唯一性",
                      (unsigned long)classesScanned,
                      (unsigned long)shardsScanned,
                      kZN58FinderWallBudgetSeconds * 1000.0];
        }
        return nil;
    }
    return matches;
}

static NSString *ZN58AmbiguousMessage(NSArray<NSDictionary<NSString *, id> *> *matches, NSString *prefix) {
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSUInteger i = 0; i < MIN((NSUInteger)5, matches.count); i++) {
        [labels addObject:matches[i][@"canonical"] ?: @"?"];
    }
    NSString *countText = matches.count >= kZN58FinderMaxCandidates
        ? [NSString stringWithFormat:@"至少 %lu", (unsigned long)kZN58FinderMaxCandidates]
        : [NSString stringWithFormat:@"%lu", (unsigned long)matches.count];
    return [NSString stringWithFormat:@"%@不唯一（%@ 个候选）：%@",
            prefix ?: @"Method Finder ",
            countText,
            [labels componentsJoinedByString:@" | "]];
}

static NSDictionary<NSString *, id> *ZN58Finalize(ZN58Runtime *runtime,
                                                   NSDictionary<NSString *, id> *candidate,
                                                   int64_t delta,
                                                   NSString *searchMode,
                                                   NSDictionary<NSString *, id> *stats,
                                                   NSString **error) {
    uintptr_t methodPointer = (uintptr_t)[candidate[@"methodPointer"] unsignedLongLongValue];
    uint64_t methodRVA = [candidate[@"methodRVA"] unsignedLongLongValue];
    if (!methodPointer || !methodRVA) {
        if (error) {
            *error = [NSString stringWithFormat:@"已找到 %@，但无法取得可验证的 UnityFramework 代码指针",
                      candidate[@"canonical"] ?: @"方法"];
        }
        return nil;
    }

    uint64_t resolvedRVA = methodRVA;
    if (delta < 0) {
        uint64_t magnitude = (uint64_t)(-delta);
        if (magnitude > methodRVA) {
            if (error) *error = @"Method Finder delta 导致 RVA 下溢";
            return nil;
        }
        resolvedRVA = methodRVA - magnitude;
    } else if (delta > 0) {
        uint64_t magnitude = (uint64_t)delta;
        if (methodRVA > UINT64_MAX - magnitude) {
            if (error) *error = @"Method Finder delta 导致 RVA 上溢";
            return nil;
        }
        resolvedRVA = methodRVA + magnitude;
    }

    if ((resolvedRVA & 3ULL) != 0) {
        if (error) *error = [NSString stringWithFormat:@"Method Finder 解析到 0x%llX，不是 4-byte ARM64 对齐", (unsigned long long)resolvedRVA];
        return nil;
    }
    uintptr_t runtimeVA = runtime->runtimeBase + (uintptr_t)resolvedRVA;
    if (!ZN58IsExecutable(runtime, runtimeVA)) {
        if (error) *error = [NSString stringWithFormat:@"解析地址 0x%llX 不在 UnityFramework executable segment", (unsigned long long)resolvedRVA];
        return nil;
    }

    NSMutableDictionary<NSString *, id> *result = [candidate mutableCopy];
    result[@"target"] = @"UnityFramework";
    result[@"rva"] = @(resolvedRVA);
    result[@"rvaText"] = [NSString stringWithFormat:@"0x%llX", (unsigned long long)resolvedRVA];
    result[@"preferredVA"] = @(runtime->preferredBase + resolvedRVA);
    result[@"runtimeVA"] = @((uint64_t)runtimeVA);
    result[@"preferredTextVMAddr"] = @(runtime->preferredBase);
    result[@"runtimeImageBase"] = @((uint64_t)runtime->runtimeBase);
    result[@"slide"] = @((int64_t)runtime->runtimeBase - (int64_t)runtime->preferredBase);
    result[@"delta"] = @(delta);
    result[@"searchMode"] = searchMode ?: @"unknown";
    result[@"searchStats"] = stats ?: @{};
    return [result copy];
}

@interface ZNIL2CPPHybridFinder (ZN58PrivateSetters)
- (void)setLastError:(NSString *)value;
- (void)setLastSearchStats:(NSDictionary<NSString *, id> *)value;
@end

@interface ZNIL2CPPHybridFinder (ZNIL2CPPMethodFinderSearchV2)
- (nullable NSDictionary<NSString *, id> *)zn58_resolveExpression:(NSString *)expression
                                                            error:(NSString * _Nullable * _Nullable)error;
@end

@implementation ZNIL2CPPHybridFinder (ZNIL2CPPMethodFinderSearchV2)

- (NSDictionary<NSString *, id> *)zn58_resolveExpression:(NSString *)expression error:(NSString **)error {
    NSString *query = ZN58Trim(expression);
    uint64_t reverseRVA = 0;
    BOOL isReverseRVA = ZN58ParseRVAInput(query, &reverseRVA);

    NSString *parseError = nil;
    NSDictionary<NSString *, id> *parsed = nil;
    if (!isReverseRVA) {
        parsed = [ZNIL2CPPResolver parseNamedOffsetExpression:query error:&parseError];
        if (!parsed) {
            // Preserve the baseline parser/error behavior for syntax we do not
            // recognize here.
            return [self zn58_resolveExpression:expression error:error];
        }

        NSString *className = parsed[@"class"] ?: @"";
        BOOL namespaceSpecified = [parsed[@"namespaceSpecified"] boolValue];
        if (className.length && namespaceSpecified) {
            // Fully-qualified lookups are already optimal: il2cpp_class_from_name
            // in the baseline backend avoids any class scan.
            return [self zn58_resolveExpression:expression error:error];
        }
    }

    [self setLastError:@""];
    [self setLastSearchStats:@{}];

    ZN58Runtime runtime;
    NSString *runtimeError = nil;
    if (!ZN58LoadRuntime(&runtime, &runtimeError)) {
        NSString *message = runtimeError ?: @"IL2CPP Runtime 不可用";
        [self setLastError:message];
        if (error) *error = message;
        return nil;
    }

    NSDictionary<NSString *, id> *stats = nil;
    NSString *searchError = nil;
    NSArray<NSDictionary<NSString *, id> *> *matches = nil;
    NSString *mode = nil;
    int64_t delta = 0;

    if (isReverseRVA) {
        mode = @"reverse-rva";
        matches = ZN58ReverseRVASearch(&runtime, reverseRVA, &stats, &searchError);
    } else {
        mode = @"sharded-stream";
        delta = [parsed[@"delta"] longLongValue];
        matches = ZN58ShardedNameSearch(&runtime, parsed, &stats, &searchError);
    }

    [self setLastSearchStats:stats ?: @{}];

    if (!matches) {
        ZN58CloseRuntime(&runtime);
        NSString *message = searchError ?: @"Method Finder 搜索失败";
        [self setLastError:message];
        if (error) *error = message;
        return nil;
    }

    if (!matches.count) {
        ZN58CloseRuntime(&runtime);
        NSString *message = isReverseRVA
            ? [NSString stringWithFormat:@"找不到 RVA 0x%llX 对应的 IL2CPP MethodInfo", (unsigned long long)reverseRVA]
            : [NSString stringWithFormat:@"找不到 IL2CPP 方法：%@", query];
        [self setLastError:message];
        if (error) *error = message;
        return nil;
    }

    if (matches.count != 1) {
        ZN58CloseRuntime(&runtime);
        NSString *message = isReverseRVA
            ? ZN58AmbiguousMessage(matches, [NSString stringWithFormat:@"RVA 0x%llX ", (unsigned long long)reverseRVA])
            : ZN58AmbiguousMessage(matches, @"Method Finder ");
        [self setLastError:message];
        if (error) *error = message;
        return nil;
    }

    NSDictionary<NSString *, id> *result = ZN58Finalize(&runtime,
                                                         matches.firstObject,
                                                         delta,
                                                         mode,
                                                         stats,
                                                         &searchError);
    ZN58CloseRuntime(&runtime);

    if (!result) {
        NSString *message = searchError ?: @"Method Finder 地址验证失败";
        [self setLastError:message];
        if (error) *error = message;
        return nil;
    }

    [self setLastError:@""];
    if (error) *error = nil;
    return result;
}

@end

extern "C" void ZNInstallIL2CPPMethodFinderSearchV2Deferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = ZNIL2CPPHybridFinder.class;
        Method original = class_getInstanceMethod(cls, @selector(resolveExpression:error:));
        Method replacement = class_getInstanceMethod(cls, @selector(zn58_resolveExpression:error:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}
