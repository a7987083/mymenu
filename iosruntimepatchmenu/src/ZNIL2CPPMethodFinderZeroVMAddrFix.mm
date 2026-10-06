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

// Some iOS UnityFramework Mach-O images legitimately use __TEXT.vmaddr == 0.
// V2 originally treated a numeric zero as "segment not found". This deferred
// compatibility layer only activates when that exact V2 error is observed;
// non-zero-vmaddr devices continue to use the V2 backend unchanged.

static const NSUInteger kZN59ShardClasses = 12000;
static const NSUInteger kZN59MaxCandidates = 8;
static const CFTimeInterval kZN59WallBudgetSeconds = 6.0;
static const NSUInteger kZN59MaxExecRanges = 16;
static NSString * const kZN59ZeroVMAddrError = @"无法读取 UnityFramework Mach-O __TEXT.vmaddr";

typedef void *(*ZN59DomainGetFn)(void);
typedef const void **(*ZN59DomainGetAssembliesFn)(const void *, size_t *);
typedef const void *(*ZN59AssemblyGetImageFn)(const void *);
typedef const char *(*ZN59ImageGetNameFn)(const void *);
typedef size_t (*ZN59ImageGetClassCountFn)(const void *);
typedef void *(*ZN59ImageGetClassFn)(const void *, size_t);
typedef const char *(*ZN59ClassGetNameFn)(void *);
typedef const char *(*ZN59ClassGetNamespaceFn)(void *);
typedef const void *(*ZN59ClassGetMethodsFn)(void *, void **);
typedef const char *(*ZN59MethodGetNameFn)(const void *);
typedef uint32_t (*ZN59MethodGetParamCountFn)(const void *);
typedef void *(*ZN59MethodGetPointerFn)(const void *);

typedef struct {
    void *handle;
    uintptr_t runtimeBase;
    uint64_t preferredBase;
    uintptr_t execStarts[kZN59MaxExecRanges];
    uintptr_t execEnds[kZN59MaxExecRanges];
    NSUInteger execCount;

    ZN59DomainGetFn domainGet;
    ZN59DomainGetAssembliesFn domainGetAssemblies;
    ZN59AssemblyGetImageFn assemblyGetImage;
    ZN59ImageGetNameFn imageGetName;
    ZN59ImageGetClassCountFn imageGetClassCount;
    ZN59ImageGetClassFn imageGetClass;
    ZN59ClassGetNameFn classGetName;
    ZN59ClassGetNamespaceFn classGetNamespace;
    ZN59ClassGetMethodsFn classGetMethods;
    ZN59MethodGetNameFn methodGetName;
    ZN59MethodGetParamCountFn methodGetParamCount;
    ZN59MethodGetPointerFn methodGetPointer;
} ZN59Runtime;

static NSString *ZN59Trim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ZN59String(const char *value) {
    if (!value) return @"";
    NSString *s = [NSString stringWithUTF8String:value];
    return s ?: @"";
}

static NSString *ZN59NormalizedAssembly(NSString *value) {
    NSString *s = ZN59Trim(value).lowercaseString;
    return [s hasSuffix:@".dll"] ? [s substringToIndex:s.length - 4] : s;
}

static BOOL ZN59AssemblyMatches(NSString *actual, NSString *wanted) {
    if (!wanted.length) return YES;
    return [ZN59NormalizedAssembly(actual) isEqualToString:ZN59NormalizedAssembly(wanted)];
}

static BOOL ZN59CaseEqual(NSString *lhs, NSString *rhs) {
    return [ZN59Trim(lhs) caseInsensitiveCompare:ZN59Trim(rhs)] == NSOrderedSame;
}

static BOOL ZN59ParseRVA(NSString *input, uint64_t *value) {
    NSString *s = ZN59Trim(input);
    if ([s.lowercaseString hasPrefix:@"rva:"]) s = ZN59Trim([s substringFromIndex:4]);
    if (s.length < 3 || ![s.lowercaseString hasPrefix:@"0x"]) return NO;
    const char *c = s.UTF8String;
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(c, &end, 0);
    if (errno || end == c || (end && *end)) return NO;
    if (value) *value = (uint64_t)parsed;
    return YES;
}

static void *ZN59ResolveSymbol(ZN59Runtime *runtime, const char *name) {
    void *p = runtime->handle ? dlsym(runtime->handle, name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

static BOOL ZN59IsExecutable(const ZN59Runtime *runtime, uintptr_t address) {
    if (!address) return NO;
    for (NSUInteger i = 0; i < runtime->execCount; i++) {
        if (address >= runtime->execStarts[i] && address < runtime->execEnds[i]) return YES;
    }
    return NO;
}

static BOOL ZN59LoadZeroVMAddrRuntime(ZN59Runtime *runtime, NSString **error) {
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
    BOOL textFound = NO;
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
                textFound = YES;
                break;
            }
        }
        cursor += lc->cmdsize;
    }
    if (!textFound) {
        if (error) *error = @"UnityFramework Mach-O 缺少 __TEXT segment";
        return NO;
    }
    if (runtime->preferredBase != 0) {
        if (error) *error = @"zero-vmaddr compatibility 被调用，但 __TEXT.vmaddr 非 0";
        return NO;
    }

    cursor = (const uint8_t *)(unityHeader + 1);
    for (uint32_t i = 0; i < unityHeader->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commandsEnd) break;
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > commandsEnd) break;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if ((seg->initprot & VM_PROT_EXECUTE) && runtime->execCount < kZN59MaxExecRanges) {
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
    runtime->domainGet = (ZN59DomainGetFn)ZN59ResolveSymbol(runtime, "il2cpp_domain_get");
    runtime->domainGetAssemblies = (ZN59DomainGetAssembliesFn)ZN59ResolveSymbol(runtime, "il2cpp_domain_get_assemblies");
    runtime->assemblyGetImage = (ZN59AssemblyGetImageFn)ZN59ResolveSymbol(runtime, "il2cpp_assembly_get_image");
    runtime->imageGetName = (ZN59ImageGetNameFn)ZN59ResolveSymbol(runtime, "il2cpp_image_get_name");
    runtime->imageGetClassCount = (ZN59ImageGetClassCountFn)ZN59ResolveSymbol(runtime, "il2cpp_image_get_class_count");
    runtime->imageGetClass = (ZN59ImageGetClassFn)ZN59ResolveSymbol(runtime, "il2cpp_image_get_class");
    runtime->classGetName = (ZN59ClassGetNameFn)ZN59ResolveSymbol(runtime, "il2cpp_class_get_name");
    runtime->classGetNamespace = (ZN59ClassGetNamespaceFn)ZN59ResolveSymbol(runtime, "il2cpp_class_get_namespace");
    runtime->classGetMethods = (ZN59ClassGetMethodsFn)ZN59ResolveSymbol(runtime, "il2cpp_class_get_methods");
    runtime->methodGetName = (ZN59MethodGetNameFn)ZN59ResolveSymbol(runtime, "il2cpp_method_get_name");
    runtime->methodGetParamCount = (ZN59MethodGetParamCountFn)ZN59ResolveSymbol(runtime, "il2cpp_method_get_param_count");
    runtime->methodGetPointer = (ZN59MethodGetPointerFn)ZN59ResolveSymbol(runtime, "il2cpp_method_get_pointer");

    BOOL core = runtime->domainGet && runtime->domainGetAssemblies && runtime->assemblyGetImage && runtime->imageGetName &&
                runtime->imageGetClassCount && runtime->imageGetClass && runtime->classGetName && runtime->classGetNamespace &&
                runtime->classGetMethods && runtime->methodGetName;
    if (!core) {
        if (error) *error = @"IL2CPP Runtime 缺少分片搜索所需 API";
        if (runtime->handle) dlclose(runtime->handle);
        return NO;
    }
    return YES;
}

static void ZN59CloseRuntime(ZN59Runtime *runtime) {
    if (runtime->handle) dlclose(runtime->handle);
    runtime->handle = NULL;
}

static const void **ZN59Assemblies(ZN59Runtime *runtime, size_t *outCount) {
    if (outCount) *outCount = 0;
    void *domain = runtime->domainGet ? runtime->domainGet() : NULL;
    if (!domain) return NULL;
    size_t count = 0;
    const void **assemblies = runtime->domainGetAssemblies(domain, &count);
    if (outCount) *outCount = count;
    return assemblies;
}

static uintptr_t ZN59MethodPointer(ZN59Runtime *runtime, const void *method, NSString **source, NSString **kind) {
    if (source) *source = @"unavailable";
    if (kind) *kind = @"unavailable";
    if (!method) return 0;
    if (runtime->methodGetPointer) {
        uintptr_t p = (uintptr_t)runtime->methodGetPointer(method);
        if (ZN59IsExecutable(runtime, p)) {
            if (source) *source = @"il2cpp_method_get_pointer";
            if (kind) *kind = @"direct-api";
            return p;
        }
    }
    uintptr_t words[2] = {0, 0};
    memcpy(words, method, sizeof(words));
    if (ZN59IsExecutable(runtime, words[0])) {
        if (source) *source = @"MethodInfo[0]";
        if (kind) *kind = @"direct-fallback";
        return words[0];
    }
    if (ZN59IsExecutable(runtime, words[1])) {
        if (source) *source = @"MethodInfo[1]";
        if (kind) *kind = @"virtual-fallback";
        return words[1];
    }
    return 0;
}

static NSDictionary<NSString *, id> *ZN59Candidate(ZN59Runtime *runtime,
                                                    const void *method,
                                                    NSString *assembly,
                                                    NSString *namespaceName,
                                                    NSString *className,
                                                    NSString *methodName,
                                                    NSInteger argumentCount) {
    NSString *source = nil;
    NSString *kind = nil;
    uintptr_t pointer = ZN59MethodPointer(runtime, method, &source, &kind);
    uint64_t rva = (pointer >= runtime->runtimeBase) ? (uint64_t)(pointer - runtime->runtimeBase) : 0;
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
        @"methodPreferredVA": @(runtime->preferredBase + rva),
        @"methodRuntimeVA": @(pointer),
        @"pointerSource": source ?: @"unavailable",
        @"pointerKind": kind ?: @"unavailable",
        @"canonical": canonical,
    };
}

static NSDictionary *ZN59Stats(NSString *mode, CFAbsoluteTime began, NSUInteger assemblies, NSUInteger classes, NSUInteger shards, NSUInteger candidates, BOOL timedOut, BOOL candidateLimit) {
    return @{
        @"mode": mode ?: @"unknown",
        @"assemblyPriority": @"Assembly-CSharp-first",
        @"assembliesScanned": @(assemblies),
        @"classesScanned": @(classes),
        @"shardsScanned": @(shards),
        @"shardSize": @(kZN59ShardClasses),
        @"candidateCount": @(candidates),
        @"candidateLimit": @(kZN59MaxCandidates),
        @"elapsedMs": @((CFAbsoluteTimeGetCurrent() - began) * 1000.0),
        @"timeLimitHit": @(timedOut),
        @"candidateLimitHit": @(candidateLimit),
        @"zeroTextVMAddrCompat": @YES,
        @"truncated": @(timedOut || candidateLimit),
    };
}

static NSArray<NSDictionary *> *ZN59Search(ZN59Runtime *runtime, NSDictionary *parsed, BOOL reverseMode, uint64_t targetRVA, NSDictionary **outStats, NSString **error) {
    NSString *assemblyWanted = parsed[@"assembly"] ?: @"";
    NSString *namespaceWanted = parsed[@"namespace"] ?: @"";
    NSString *classWanted = parsed[@"class"] ?: @"";
    NSString *methodWanted = parsed[@"method"] ?: @"";
    BOOL namespaceSpecified = [parsed[@"namespaceSpecified"] boolValue];
    BOOL argumentSpecified = [parsed[@"argumentSpecified"] boolValue];
    NSInteger wantedArguments = argumentSpecified ? [parsed[@"argumentCount"] integerValue] : -1;
    if (argumentSpecified && !runtime->methodGetParamCount) {
        if (error) *error = @"当前 IL2CPP 未导出参数数量 API，无法安全匹配 /参数数量";
        return nil;
    }

    if (reverseMode) {
        if ((targetRVA & 3ULL) != 0) {
            if (error) *error = @"RVA 反查要求 4-byte ARM64 对齐";
            return nil;
        }
        uintptr_t target = runtime->runtimeBase + (uintptr_t)targetRVA;
        if (!ZN59IsExecutable(runtime, target)) {
            if (error) *error = [NSString stringWithFormat:@"RVA 0x%llX 不在 UnityFramework executable segment", (unsigned long long)targetRVA];
            return nil;
        }
    }

    size_t assemblyCount = 0;
    const void **assemblies = ZN59Assemblies(runtime, &assemblyCount);
    if (!assemblies || !assemblyCount) {
        if (error) *error = @"IL2CPP Domain 尚无可用程序集";
        return nil;
    }

    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray arrayWithCapacity:kZN59MaxCandidates];
    NSUInteger assembliesScanned = 0, classesScanned = 0, shardsScanned = 0;
    BOOL timedOut = NO, candidateLimit = NO, stop = NO;
    NSUInteger passCount = reverseMode ? 2U : (assemblyWanted.length ? 1U : 2U);

    for (NSUInteger pass = 0; pass < passCount && !stop; pass++) {
        for (size_t a = 0; a < assemblyCount && !stop; a++) {
            const void *image = runtime->assemblyGetImage(assemblies[a]);
            if (!image) continue;
            NSString *assemblyName = ZN59String(runtime->imageGetName(image));
            BOOL preferred = [ZN59NormalizedAssembly(assemblyName) isEqualToString:@"assembly-csharp"];
            if (reverseMode) {
                if ((pass == 0 && !preferred) || (pass == 1 && preferred)) continue;
            } else {
                if (!ZN59AssemblyMatches(assemblyName, assemblyWanted)) continue;
                if (!assemblyWanted.length && ((pass == 0 && !preferred) || (pass == 1 && preferred))) continue;
            }
            assembliesScanned++;

            size_t classCount = runtime->imageGetClassCount(image);
            for (size_t shardStart = 0; shardStart < classCount && !stop; shardStart += kZN59ShardClasses) {
                size_t shardEnd = MIN(classCount, shardStart + kZN59ShardClasses);
                shardsScanned++;
                for (size_t c = shardStart; c < shardEnd; c++) {
                    if ((classesScanned & 0x3F) == 0 && CFAbsoluteTimeGetCurrent() - began >= kZN59WallBudgetSeconds) {
                        timedOut = YES;
                        stop = YES;
                        break;
                    }
                    classesScanned++;
                    @autoreleasepool {
                        void *klass = runtime->imageGetClass(image, c);
                        if (!klass) continue;
                        NSString *className = ZN59String(runtime->classGetName(klass));
                        NSString *namespaceName = ZN59String(runtime->classGetNamespace(klass));
                        if (!reverseMode) {
                            if (classWanted.length && !ZN59CaseEqual(className, classWanted)) continue;
                            if (namespaceSpecified && !ZN59CaseEqual(namespaceName, namespaceWanted)) continue;
                        }

                        void *iter = NULL;
                        const void *method = NULL;
                        while ((method = runtime->classGetMethods(klass, &iter)) != NULL) {
                            NSString *actualName = ZN59String(runtime->methodGetName(method));
                            NSInteger argc = runtime->methodGetParamCount ? (NSInteger)runtime->methodGetParamCount(method) : -1;
                            if (reverseMode) {
                                uintptr_t pointer = ZN59MethodPointer(runtime, method, NULL, NULL);
                                if (!pointer || pointer < runtime->runtimeBase || (uint64_t)(pointer - runtime->runtimeBase) != targetRVA) continue;
                            } else {
                                if (!ZN59CaseEqual(actualName, methodWanted)) continue;
                                if (argumentSpecified && argc != wantedArguments) continue;
                            }
                            [matches addObject:ZN59Candidate(runtime, method, assemblyName, namespaceName, className, actualName, argc)];
                            if (matches.count >= kZN59MaxCandidates) {
                                candidateLimit = YES;
                                stop = YES;
                                break;
                            }
                        }
                    }
                }
            }
        }
        if (!reverseMode && !assemblyWanted.length && pass == 0 && !timedOut && matches.count > 0) break;
    }

    if (outStats) *outStats = ZN59Stats(reverseMode ? @"reverse-rva-zero-vmaddr" : @"sharded-stream-zero-vmaddr", began, assembliesScanned, classesScanned, shardsScanned, matches.count, timedOut, candidateLimit);
    if (timedOut) {
        if (error) *error = [NSString stringWithFormat:@"Method Finder 已扫描 %lu 个 Class（%lu 个分片）后达到 %.0fms 安全预算",
                             (unsigned long)classesScanned, (unsigned long)shardsScanned, kZN59WallBudgetSeconds * 1000.0];
        return nil;
    }
    return matches;
}

static NSString *ZN59Ambiguous(NSArray<NSDictionary *> *matches, NSString *prefix) {
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSUInteger i = 0; i < MIN((NSUInteger)5, matches.count); i++) [labels addObject:matches[i][@"canonical"] ?: @"?"];
    return [NSString stringWithFormat:@"%@不唯一（%lu 个候选）：%@", prefix ?: @"Method Finder ", (unsigned long)matches.count, [labels componentsJoinedByString:@" | "]];
}

static NSDictionary *ZN59Finalize(ZN59Runtime *runtime, NSDictionary *candidate, int64_t delta, NSString *mode, NSDictionary *stats, NSString **error) {
    uintptr_t pointer = (uintptr_t)[candidate[@"methodPointer"] unsignedLongLongValue];
    uint64_t methodRVA = [candidate[@"methodRVA"] unsignedLongLongValue];
    if (!pointer || !methodRVA) {
        if (error) *error = @"已找到方法，但无法取得可验证的 UnityFramework 代码指针";
        return nil;
    }
    uint64_t resolved = methodRVA;
    if (delta < 0) {
        uint64_t mag = (uint64_t)(-delta);
        if (mag > methodRVA) { if (error) *error = @"Method Finder delta 导致 RVA 下溢"; return nil; }
        resolved -= mag;
    } else if (delta > 0) {
        uint64_t mag = (uint64_t)delta;
        if (methodRVA > UINT64_MAX - mag) { if (error) *error = @"Method Finder delta 导致 RVA 上溢"; return nil; }
        resolved += mag;
    }
    if ((resolved & 3ULL) != 0 || !ZN59IsExecutable(runtime, runtime->runtimeBase + (uintptr_t)resolved)) {
        if (error) *error = @"解析后的 RVA 未通过 ARM64 对齐或 executable segment 验证";
        return nil;
    }

    NSMutableDictionary *result = [candidate mutableCopy];
    result[@"target"] = @"UnityFramework";
    result[@"rva"] = @(resolved);
    result[@"rvaText"] = [NSString stringWithFormat:@"0x%llX", (unsigned long long)resolved];
    result[@"preferredVA"] = @(runtime->preferredBase + resolved);
    result[@"runtimeVA"] = @((uint64_t)(runtime->runtimeBase + (uintptr_t)resolved));
    result[@"preferredTextVMAddr"] = @(runtime->preferredBase);
    result[@"runtimeImageBase"] = @((uint64_t)runtime->runtimeBase);
    result[@"slide"] = @((int64_t)runtime->runtimeBase - (int64_t)runtime->preferredBase);
    result[@"delta"] = @(delta);
    result[@"searchMode"] = mode ?: @"unknown";
    result[@"searchStats"] = stats ?: @{};
    return [result copy];
}

@interface ZNIL2CPPHybridFinder (ZN59PrivateSetters)
- (void)setLastError:(NSString *)value;
- (void)setLastSearchStats:(NSDictionary<NSString *, id> *)value;
@end

@interface ZNIL2CPPHybridFinder (ZNIL2CPPMethodFinderZeroVMAddrFix)
- (nullable NSDictionary<NSString *, id> *)zn59_resolveExpression:(NSString *)expression error:(NSString * _Nullable * _Nullable)error;
@end

@implementation ZNIL2CPPHybridFinder (ZNIL2CPPMethodFinderZeroVMAddrFix)

- (NSDictionary<NSString *, id> *)zn59_resolveExpression:(NSString *)expression error:(NSString **)error {
    NSString *priorError = nil;
    NSDictionary *prior = [self zn59_resolveExpression:expression error:&priorError];
    if (prior || ![priorError isEqualToString:kZN59ZeroVMAddrError]) {
        if (error) *error = priorError;
        return prior;
    }

    NSString *query = ZN59Trim(expression);
    uint64_t reverseRVA = 0;
    BOOL reverseMode = ZN59ParseRVA(query, &reverseRVA);
    NSString *parseError = nil;
    NSDictionary *parsed = reverseMode ? @{} : [ZNIL2CPPResolver parseNamedOffsetExpression:query error:&parseError];
    if (!reverseMode && !parsed) {
        [self setLastError:parseError ?: @"Method Finder 表达式解析失败"];
        if (error) *error = self.lastError;
        return nil;
    }

    ZN59Runtime runtime;
    NSString *runtimeError = nil;
    if (!ZN59LoadZeroVMAddrRuntime(&runtime, &runtimeError)) {
        [self setLastError:runtimeError ?: kZN59ZeroVMAddrError];
        if (error) *error = self.lastError;
        return nil;
    }

    NSDictionary *stats = nil;
    NSString *searchError = nil;
    NSArray<NSDictionary *> *matches = ZN59Search(&runtime, parsed ?: @{}, reverseMode, reverseRVA, &stats, &searchError);
    [self setLastSearchStats:stats ?: @{}];
    if (!matches) {
        ZN59CloseRuntime(&runtime);
        [self setLastError:searchError ?: @"Method Finder 搜索失败"];
        if (error) *error = self.lastError;
        return nil;
    }
    if (!matches.count) {
        ZN59CloseRuntime(&runtime);
        NSString *message = reverseMode
            ? [NSString stringWithFormat:@"找不到 RVA 0x%llX 对应的 IL2CPP MethodInfo", (unsigned long long)reverseRVA]
            : [NSString stringWithFormat:@"找不到 IL2CPP 方法：%@", query];
        [self setLastError:message];
        if (error) *error = message;
        return nil;
    }
    if (matches.count != 1) {
        ZN59CloseRuntime(&runtime);
        NSString *message = ZN59Ambiguous(matches, reverseMode ? @"RVA 反查 " : @"Method Finder ");
        [self setLastError:message];
        if (error) *error = message;
        return nil;
    }

    int64_t delta = reverseMode ? 0 : [parsed[@"delta"] longLongValue];
    NSString *mode = reverseMode ? @"reverse-rva-zero-vmaddr" : @"sharded-stream-zero-vmaddr";
    NSDictionary *result = ZN59Finalize(&runtime, matches.firstObject, delta, mode, stats, &searchError);
    ZN59CloseRuntime(&runtime);
    if (!result) {
        [self setLastError:searchError ?: @"Method Finder 地址验证失败"];
        if (error) *error = self.lastError;
        return nil;
    }
    [self setLastError:@""];
    if (error) *error = nil;
    return result;
}

@end

extern "C" void ZNInstallIL2CPPMethodFinderZeroVMAddrFixDeferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = ZNIL2CPPHybridFinder.class;
        Method original = class_getInstanceMethod(cls, @selector(resolveExpression:error:));
        Method replacement = class_getInstanceMethod(cls, @selector(zn59_resolveExpression:error:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}
