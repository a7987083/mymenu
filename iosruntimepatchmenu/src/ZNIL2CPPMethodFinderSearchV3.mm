#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <errno.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>

#import "ZNIL2CPPHybridFinder.h"
#import "ZNIL2CPPMethodFinderSearchV3.h"
#import "ZNIL2CPPResolver.h"

// Method Finder V3 interactive search backend.
// Important: this does NOT replace/swizzle resolveExpression:error:. Named
// Offset and already-device-verified V2 resolution remain untouched. V3 adds a
// candidate-list API for the debugger UI, including overloads and RVA aliases.

static const NSUInteger kZN60ShardClasses = 12000;
static const NSUInteger kZN60DefaultLimit = 32;
static const NSUInteger kZN60HardLimit = 1024;
static const NSUInteger kZN60MaxExecRanges = 16;
static const CFTimeInterval kZN60WallBudgetSeconds = 6.0;

typedef void *(*ZN60DomainGetFn)(void);
typedef const void **(*ZN60DomainGetAssembliesFn)(const void *, size_t *);
typedef const void *(*ZN60AssemblyGetImageFn)(const void *);
typedef const char *(*ZN60ImageGetNameFn)(const void *);
typedef size_t (*ZN60ImageGetClassCountFn)(const void *);
typedef void *(*ZN60ImageGetClassFn)(const void *, size_t);
typedef void *(*ZN60ClassFromNameFn)(const void *, const char *, const char *);
typedef const char *(*ZN60ClassGetNameFn)(void *);
typedef const char *(*ZN60ClassGetNamespaceFn)(void *);
typedef const void *(*ZN60ClassGetMethodsFn)(void *, void **);
typedef const char *(*ZN60MethodGetNameFn)(const void *);
typedef uint32_t (*ZN60MethodGetParamCountFn)(const void *);
typedef void *(*ZN60MethodGetPointerFn)(const void *);

typedef struct {
    void *handle;
    uintptr_t runtimeBase;
    uint64_t preferredBase;
    uintptr_t execStarts[kZN60MaxExecRanges];
    uintptr_t execEnds[kZN60MaxExecRanges];
    NSUInteger execCount;

    ZN60DomainGetFn domainGet;
    ZN60DomainGetAssembliesFn domainGetAssemblies;
    ZN60AssemblyGetImageFn assemblyGetImage;
    ZN60ImageGetNameFn imageGetName;
    ZN60ImageGetClassCountFn imageGetClassCount;
    ZN60ImageGetClassFn imageGetClass;
    ZN60ClassFromNameFn classFromName;
    ZN60ClassGetNameFn classGetName;
    ZN60ClassGetNamespaceFn classGetNamespace;
    ZN60ClassGetMethodsFn classGetMethods;
    ZN60MethodGetNameFn methodGetName;
    ZN60MethodGetParamCountFn methodGetParamCount;
    ZN60MethodGetPointerFn methodGetPointer;
} ZN60Runtime;

static NSString *ZN60Trim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ZN60String(const char *value) {
    if (!value) return @"";
    NSString *s = [NSString stringWithUTF8String:value];
    return s ?: @"";
}

static NSString *ZN60NormalizedAssembly(NSString *value) {
    NSString *s = ZN60Trim(value).lowercaseString;
    return [s hasSuffix:@".dll"] ? [s substringToIndex:s.length - 4] : s;
}

static BOOL ZN60AssemblyMatches(NSString *actual, NSString *wanted) {
    if (!wanted.length) return YES;
    return [ZN60NormalizedAssembly(actual) isEqualToString:ZN60NormalizedAssembly(wanted)];
}

static BOOL ZN60CaseEqual(NSString *lhs, NSString *rhs) {
    return [ZN60Trim(lhs) caseInsensitiveCompare:ZN60Trim(rhs)] == NSOrderedSame;
}

static BOOL ZN60ParseRVA(NSString *input, uint64_t *value) {
    NSString *s = ZN60Trim(input);
    if ([s.lowercaseString hasPrefix:@"rva:"]) s = ZN60Trim([s substringFromIndex:4]);
    if (s.length < 3 || ![s.lowercaseString hasPrefix:@"0x"]) return NO;
    const char *c = s.UTF8String;
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(c, &end, 0);
    if (errno || end == c || (end && *end)) return NO;
    if (value) *value = (uint64_t)parsed;
    return YES;
}

static void *ZN60ResolveSymbol(ZN60Runtime *runtime, const char *name) {
    void *p = runtime->handle ? dlsym(runtime->handle, name) : NULL;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

static BOOL ZN60IsExecutable(const ZN60Runtime *runtime, uintptr_t address) {
    if (!address) return NO;
    for (NSUInteger i = 0; i < runtime->execCount; i++) {
        if (address >= runtime->execStarts[i] && address < runtime->execEnds[i]) return YES;
    }
    return NO;
}

static BOOL ZN60LoadRuntime(ZN60Runtime *runtime, NSString **error) {
    memset(runtime, 0, sizeof(*runtime));
    NSString *unityPath = @"";
    const struct mach_header_64 *unityHeader = NULL;

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *raw = _dyld_get_image_name(i);
        if (!raw) continue;
        NSString *path = [NSString stringWithUTF8String:raw] ?: @"";
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

    cursor = (const uint8_t *)(unityHeader + 1);
    for (uint32_t i = 0; i < unityHeader->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commandsEnd) break;
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > commandsEnd) break;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if ((seg->initprot & VM_PROT_EXECUTE) && seg->vmaddr >= runtime->preferredBase && runtime->execCount < kZN60MaxExecRanges) {
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

    runtime->domainGet = (ZN60DomainGetFn)ZN60ResolveSymbol(runtime, "il2cpp_domain_get");
    runtime->domainGetAssemblies = (ZN60DomainGetAssembliesFn)ZN60ResolveSymbol(runtime, "il2cpp_domain_get_assemblies");
    runtime->assemblyGetImage = (ZN60AssemblyGetImageFn)ZN60ResolveSymbol(runtime, "il2cpp_assembly_get_image");
    runtime->imageGetName = (ZN60ImageGetNameFn)ZN60ResolveSymbol(runtime, "il2cpp_image_get_name");
    runtime->imageGetClassCount = (ZN60ImageGetClassCountFn)ZN60ResolveSymbol(runtime, "il2cpp_image_get_class_count");
    runtime->imageGetClass = (ZN60ImageGetClassFn)ZN60ResolveSymbol(runtime, "il2cpp_image_get_class");
    runtime->classFromName = (ZN60ClassFromNameFn)ZN60ResolveSymbol(runtime, "il2cpp_class_from_name");
    runtime->classGetName = (ZN60ClassGetNameFn)ZN60ResolveSymbol(runtime, "il2cpp_class_get_name");
    runtime->classGetNamespace = (ZN60ClassGetNamespaceFn)ZN60ResolveSymbol(runtime, "il2cpp_class_get_namespace");
    runtime->classGetMethods = (ZN60ClassGetMethodsFn)ZN60ResolveSymbol(runtime, "il2cpp_class_get_methods");
    runtime->methodGetName = (ZN60MethodGetNameFn)ZN60ResolveSymbol(runtime, "il2cpp_method_get_name");
    runtime->methodGetParamCount = (ZN60MethodGetParamCountFn)ZN60ResolveSymbol(runtime, "il2cpp_method_get_param_count");
    runtime->methodGetPointer = (ZN60MethodGetPointerFn)ZN60ResolveSymbol(runtime, "il2cpp_method_get_pointer");

    BOOL core = runtime->domainGet && runtime->domainGetAssemblies && runtime->assemblyGetImage && runtime->imageGetName &&
                runtime->imageGetClassCount && runtime->imageGetClass && runtime->classGetName && runtime->classGetNamespace &&
                runtime->classGetMethods && runtime->methodGetName;
    if (!core) {
        if (error) *error = @"IL2CPP Runtime 缺少 V3 搜索所需 API";
        if (runtime->handle) dlclose(runtime->handle);
        memset(runtime, 0, sizeof(*runtime));
        return NO;
    }
    return YES;
}

static void ZN60CloseRuntime(ZN60Runtime *runtime) {
    if (runtime->handle) dlclose(runtime->handle);
    runtime->handle = NULL;
}

static const void **ZN60Assemblies(ZN60Runtime *runtime, size_t *outCount) {
    if (outCount) *outCount = 0;
    void *domain = runtime->domainGet ? runtime->domainGet() : NULL;
    if (!domain || !runtime->domainGetAssemblies) return NULL;
    size_t count = 0;
    const void **assemblies = runtime->domainGetAssemblies(domain, &count);
    if (outCount) *outCount = count;
    return assemblies;
}

static uintptr_t ZN60MethodPointer(ZN60Runtime *runtime,
                                   const void *method,
                                   NSString **source,
                                   NSString **kind) {
    if (source) *source = @"unavailable";
    if (kind) *kind = @"unavailable";
    if (!method) return 0;

    if (runtime->methodGetPointer) {
        uintptr_t pointer = (uintptr_t)runtime->methodGetPointer(method);
        if (ZN60IsExecutable(runtime, pointer)) {
            if (source) *source = @"il2cpp_method_get_pointer";
            if (kind) *kind = @"direct-api";
            return pointer;
        }
    }

    uintptr_t words[2] = {0, 0};
    memcpy(words, method, sizeof(words));
    if (ZN60IsExecutable(runtime, words[0])) {
        if (source) *source = @"MethodInfo[0]";
        if (kind) *kind = @"direct-fallback";
        return words[0];
    }
    if (ZN60IsExecutable(runtime, words[1])) {
        if (source) *source = @"MethodInfo[1]";
        if (kind) *kind = @"virtual-fallback";
        return words[1];
    }
    return 0;
}

static NSString *ZN60CodePreview(uintptr_t address) {
    if (!address) return @"";
    uint8_t bytes[16] = {};
    vm_size_t readSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         (vm_address_t)address,
                                         (vm_size_t)sizeof(bytes),
                                         (vm_address_t)bytes,
                                         &readSize);
    if (kr != KERN_SUCCESS || readSize != sizeof(bytes)) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:sizeof(bytes)];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [parts addObject:[NSString stringWithFormat:@"%02X", bytes[i]]];
    return [parts componentsJoinedByString:@" "];
}

static NSDictionary<NSString *, id> *ZN60Candidate(ZN60Runtime *runtime,
                                                    const void *method,
                                                    NSString *assembly,
                                                    NSString *namespaceName,
                                                    NSString *className,
                                                    NSString *methodName,
                                                    NSInteger argumentCount,
                                                    int64_t delta) {
    NSString *pointerSource = nil;
    NSString *pointerKind = nil;
    uintptr_t pointer = ZN60MethodPointer(runtime, method, &pointerSource, &pointerKind);
    uint64_t methodRVA = (pointer >= runtime->runtimeBase) ? (uint64_t)(pointer - runtime->runtimeBase) : 0;
    uint64_t resolvedRVA = methodRVA;
    BOOL deltaValid = YES;
    if (methodRVA) {
        if (delta < 0) {
            uint64_t mag = (uint64_t)(-delta);
            if (mag > methodRVA) deltaValid = NO;
            else resolvedRVA = methodRVA - mag;
        } else if (delta > 0) {
            uint64_t mag = (uint64_t)delta;
            if (methodRVA > UINT64_MAX - mag) deltaValid = NO;
            else resolvedRVA = methodRVA + mag;
        }
    }
    if (!deltaValid || (resolvedRVA && (resolvedRVA & 3ULL))) resolvedRVA = 0;
    uintptr_t runtimeVA = resolvedRVA ? runtime->runtimeBase + (uintptr_t)resolvedRVA : 0;
    BOOL addressResolved = pointer && resolvedRVA && ZN60IsExecutable(runtime, runtimeVA);

    NSString *classPath = namespaceName.length ? [NSString stringWithFormat:@"%@.%@", namespaceName, className] : className;
    NSString *canonical = [NSString stringWithFormat:@"%@!%@::%@%@",
                           assembly.length ? assembly : @"?",
                           classPath.length ? classPath : @"?",
                           methodName.length ? methodName : @"?",
                           argumentCount >= 0 ? [NSString stringWithFormat:@"/%ld", (long)argumentCount] : @""];

    return @{
        @"target": @"UnityFramework",
        @"assembly": assembly ?: @"",
        @"namespace": namespaceName ?: @"",
        @"class": className ?: @"",
        @"method": methodName ?: @"",
        @"argumentCount": @(argumentCount),
        @"methodInfo": @((uintptr_t)method),
        @"methodPointer": @(pointer),
        @"methodRVA": @(methodRVA),
        @"rva": @(resolvedRVA),
        @"rvaText": resolvedRVA ? [NSString stringWithFormat:@"0x%llX", (unsigned long long)resolvedRVA] : @"—",
        @"preferredVA": @(resolvedRVA ? runtime->preferredBase + resolvedRVA : 0),
        @"runtimeVA": @((uint64_t)runtimeVA),
        @"preferredTextVMAddr": @(runtime->preferredBase),
        @"runtimeImageBase": @((uint64_t)runtime->runtimeBase),
        @"slide": @((int64_t)runtime->runtimeBase - (int64_t)runtime->preferredBase),
        @"pointerSource": pointerSource ?: @"unavailable",
        @"pointerKind": pointerKind ?: @"unavailable",
        @"canonical": canonical,
        @"delta": @(delta),
        @"addressResolved": @(addressResolved),
        @"codePreview": addressResolved ? ZN60CodePreview(runtimeVA) : @"",
    };
}

static NSDictionary<NSString *, id> *ZN60Stats(NSString *mode,
                                                CFAbsoluteTime started,
                                                NSUInteger assemblies,
                                                NSUInteger classes,
                                                NSUInteger shards,
                                                NSUInteger candidates,
                                                NSUInteger limit,
                                                BOOL timedOut,
                                                BOOL limitHit) {
    return @{
        @"mode": mode ?: @"unknown",
        @"assemblyPriority": @"Assembly-CSharp-first",
        @"assembliesScanned": @(assemblies),
        @"classesScanned": @(classes),
        @"shardsScanned": @(shards),
        @"shardSize": @(kZN60ShardClasses),
        @"candidateCount": @(candidates),
        @"candidateLimit": @(limit),
        @"elapsedMs": @((CFAbsoluteTimeGetCurrent() - started) * 1000.0),
        @"timeLimitHit": @(timedOut),
        @"candidateLimitHit": @(limitHit),
        @"truncated": @(timedOut || limitHit),
        @"v3CandidateList": @YES,
    };
}

static BOOL ZN60MethodMatches(ZN60Runtime *runtime,
                              const void *method,
                              NSString *wantedName,
                              BOOL argumentSpecified,
                              NSInteger wantedArguments,
                              NSInteger *outArguments) {
    NSString *actual = ZN60String(runtime->methodGetName(method));
    if (!ZN60CaseEqual(actual, wantedName)) return NO;
    NSInteger argc = runtime->methodGetParamCount ? (NSInteger)runtime->methodGetParamCount(method) : -1;
    if (argumentSpecified && argc != wantedArguments) return NO;
    if (outArguments) *outArguments = argc;
    return YES;
}

@interface ZNIL2CPPHybridFinder (ZN60PrivateSetters)
- (void)setLastError:(NSString *)value;
- (void)setLastSearchStats:(NSDictionary<NSString *, id> *)value;
@end

@implementation ZNIL2CPPHybridFinder (ZNMethodFinderV3Search)

- (NSArray<NSDictionary<NSString *,id> *> *)zn60_searchCandidates:(NSString *)expression
                                                             limit:(NSUInteger)limit
                                                             error:(NSString **)error {
    NSString *query = ZN60Trim(expression);
    if (!query.length) {
        if (error) *error = @"请输入方法名、Class::Method 或 0xRVA";
        return nil;
    }
    limit = MAX((NSUInteger)1, MIN(limit ?: kZN60DefaultLimit, kZN60HardLimit));

    uint64_t reverseRVA = 0;
    BOOL reverse = ZN60ParseRVA(query, &reverseRVA);
    NSString *parseError = nil;
    NSDictionary<NSString *, id> *parsed = reverse ? nil : [ZNIL2CPPResolver parseNamedOffsetExpression:query error:&parseError];
    if (!reverse && !parsed) {
        if (error) *error = parseError ?: @"搜索表达式无效";
        return nil;
    }

    ZN60Runtime runtime;
    NSString *runtimeError = nil;
    if (!ZN60LoadRuntime(&runtime, &runtimeError)) {
        [self setLastError:runtimeError ?: @"IL2CPP Runtime 不可用"];
        if (error) *error = runtimeError ?: @"IL2CPP Runtime 不可用";
        return nil;
    }

    size_t assemblyCount = 0;
    const void **assemblies = ZN60Assemblies(&runtime, &assemblyCount);
    if (!assemblies || !assemblyCount) {
        ZN60CloseRuntime(&runtime);
        if (error) *error = @"IL2CPP Domain 尚无可用程序集";
        return nil;
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSMutableArray<NSDictionary<NSString *, id> *> *matches = [NSMutableArray arrayWithCapacity:MIN(limit, (NSUInteger)16)];
    NSUInteger assembliesScanned = 0, classesScanned = 0, shardsScanned = 0;
    BOOL timedOut = NO, limitHit = NO, stop = NO;
    NSString *mode = reverse ? @"v3-reverse-rva" : @"v3-candidate-list";

    NSString *assemblyWanted = parsed[@"assembly"] ?: @"";
    NSString *namespaceWanted = parsed[@"namespace"] ?: @"";
    NSString *classWanted = parsed[@"class"] ?: @"";
    NSString *methodWanted = parsed[@"method"] ?: @"";
    BOOL namespaceSpecified = [parsed[@"namespaceSpecified"] boolValue];
    BOOL argumentSpecified = [parsed[@"argumentSpecified"] boolValue];
    NSInteger wantedArguments = argumentSpecified ? [parsed[@"argumentCount"] integerValue] : -1;
    int64_t delta = reverse ? 0 : [parsed[@"delta"] longLongValue];

    if (!reverse && argumentSpecified && !runtime.methodGetParamCount) {
        ZN60CloseRuntime(&runtime);
        if (error) *error = @"当前 IL2CPP 未导出参数数量 API，无法安全匹配 /参数数量";
        return nil;
    }

    if (!reverse && classWanted.length && namespaceSpecified && runtime.classFromName) {
        mode = @"v3-qualified-candidates";
        NSUInteger passes = assemblyWanted.length ? 1 : 2;
        for (NSUInteger pass = 0; pass < passes && !stop; pass++) {
            for (size_t a = 0; a < assemblyCount && !stop; a++) {
                const void *image = runtime.assemblyGetImage(assemblies[a]);
                if (!image) continue;
                NSString *assemblyName = ZN60String(runtime.imageGetName(image));
                if (!ZN60AssemblyMatches(assemblyName, assemblyWanted)) continue;
                if (!assemblyWanted.length) {
                    BOOL preferred = [ZN60NormalizedAssembly(assemblyName) isEqualToString:@"assembly-csharp"];
                    if ((pass == 0 && !preferred) || (pass == 1 && preferred)) continue;
                }
                assembliesScanned++;
                void *klass = runtime.classFromName(image, namespaceWanted.UTF8String ?: "", classWanted.UTF8String ?: "");
                if (!klass) continue;
                classesScanned++;
                void *iter = NULL;
                const void *method = NULL;
                while ((method = runtime.classGetMethods(klass, &iter)) != NULL) {
                    NSInteger argc = -1;
                    if (!ZN60MethodMatches(&runtime, method, methodWanted, argumentSpecified, wantedArguments, &argc)) continue;
                    NSString *actual = ZN60String(runtime.methodGetName(method));
                    [matches addObject:ZN60Candidate(&runtime, method, assemblyName, namespaceWanted, classWanted, actual, argc, delta)];
                    if (matches.count >= limit) { limitHit = YES; stop = YES; break; }
                }
            }
        }
    } else {
        NSUInteger passCount = (!reverse && assemblyWanted.length) ? 1 : 2;
        for (NSUInteger pass = 0; pass < passCount && !stop; pass++) {
            for (size_t a = 0; a < assemblyCount && !stop; a++) {
                const void *image = runtime.assemblyGetImage(assemblies[a]);
                if (!image) continue;
                NSString *assemblyName = ZN60String(runtime.imageGetName(image));
                if (!reverse && !ZN60AssemblyMatches(assemblyName, assemblyWanted)) continue;
                if ((reverse || !assemblyWanted.length)) {
                    BOOL preferred = [ZN60NormalizedAssembly(assemblyName) isEqualToString:@"assembly-csharp"];
                    if ((pass == 0 && !preferred) || (pass == 1 && preferred)) continue;
                }
                assembliesScanned++;
                size_t classCount = runtime.imageGetClassCount(image);
                for (size_t shardStart = 0; shardStart < classCount && !stop; shardStart += kZN60ShardClasses) {
                    size_t shardEnd = MIN(classCount, shardStart + kZN60ShardClasses);
                    shardsScanned++;
                    for (size_t c = shardStart; c < shardEnd; c++) {
                        if ((classesScanned & 0x3F) == 0 && CFAbsoluteTimeGetCurrent() - started >= kZN60WallBudgetSeconds) {
                            timedOut = YES;
                            stop = YES;
                            break;
                        }
                        classesScanned++;
                        @autoreleasepool {
                            void *klass = runtime.imageGetClass(image, c);
                            if (!klass) continue;
                            NSString *className = ZN60String(runtime.classGetName(klass));
                            NSString *namespaceName = ZN60String(runtime.classGetNamespace(klass));
                            if (!reverse) {
                                if (classWanted.length && !ZN60CaseEqual(className, classWanted)) continue;
                                if (namespaceSpecified && !ZN60CaseEqual(namespaceName, namespaceWanted)) continue;
                            }

                            void *iter = NULL;
                            const void *method = NULL;
                            while ((method = runtime.classGetMethods(klass, &iter)) != NULL) {
                                NSInteger argc = runtime.methodGetParamCount ? (NSInteger)runtime.methodGetParamCount(method) : -1;
                                if (reverse) {
                                    uintptr_t pointer = ZN60MethodPointer(&runtime, method, NULL, NULL);
                                    if (!pointer || pointer < runtime.runtimeBase || (uint64_t)(pointer - runtime.runtimeBase) != reverseRVA) continue;
                                } else {
                                    if (!ZN60MethodMatches(&runtime, method, methodWanted, argumentSpecified, wantedArguments, &argc)) continue;
                                }
                                NSString *actual = ZN60String(runtime.methodGetName(method));
                                [matches addObject:ZN60Candidate(&runtime, method, assemblyName, namespaceName, className, actual, argc, delta)];
                                if (matches.count >= limit) { limitHit = YES; stop = YES; break; }
                            }
                        }
                    }
                }
            }
        }
    }

    NSDictionary *stats = ZN60Stats(mode, started, assembliesScanned, classesScanned, shardsScanned,
                                     matches.count, limit, timedOut, limitHit);
    [self setLastSearchStats:stats];
    ZN60CloseRuntime(&runtime);

    if (!matches.count) {
        NSString *message = nil;
        if (timedOut) message = [NSString stringWithFormat:@"V3 搜索达到 %.0fms 安全预算，尚未发现候选", kZN60WallBudgetSeconds * 1000.0];
        else if (reverse) message = [NSString stringWithFormat:@"找不到 RVA 0x%llX 对应的 IL2CPP MethodInfo", (unsigned long long)reverseRVA];
        else message = [NSString stringWithFormat:@"找不到 IL2CPP 方法：%@", query];
        [self setLastError:message];
        if (error) *error = message;
        return nil;
    }

    NSMutableArray *annotated = [NSMutableArray arrayWithCapacity:matches.count];
    for (NSDictionary *candidate in matches) {
        NSMutableDictionary *item = [candidate mutableCopy];
        item[@"searchMode"] = mode;
        item[@"searchStats"] = stats;
        [annotated addObject:[item copy]];
    }
    [self setLastError:@""];
    if (error) *error = nil;
    return [annotated copy];
}

@end
