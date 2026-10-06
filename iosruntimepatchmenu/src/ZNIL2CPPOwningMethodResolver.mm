#import "ZNIL2CPPOwningMethodResolver.h"
#import "ZNPatchCore.h"

#import <CoreFoundation/CoreFoundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <string.h>

// M4.5 Address -> Owning Method Resolver V1
//
// Exact method-entry lookup remains valid, but an ARM64 instruction offset is
// commonly inside a method. For an interior address we scan the live IL2CPP
// method table and require a fully bounded interval:
//
//     methodStart <= targetRVA < nextKnownMethodStart
//
// Interior ownership fails closed when the scan times out or the upper bound is
// unavailable. Shared/generic native code is represented by multiple candidates
// with the same methodStart instead of guessing one MethodInfo.

static const NSUInteger kZNM45MaxExecRanges = 16;
static const NSUInteger kZNM45HardCandidateLimit = 64;
static const CFTimeInterval kZNM45WallBudgetSeconds = 6.0;

typedef void *(*ZNM45DomainGetFn)(void);
typedef const void **(*ZNM45DomainGetAssembliesFn)(const void *, size_t *);
typedef const void *(*ZNM45AssemblyGetImageFn)(const void *);
typedef const char *(*ZNM45ImageGetNameFn)(const void *);
typedef size_t (*ZNM45ImageGetClassCountFn)(const void *);
typedef void *(*ZNM45ImageGetClassFn)(const void *, size_t);
typedef const char *(*ZNM45ClassGetNameFn)(void *);
typedef const char *(*ZNM45ClassGetNamespaceFn)(void *);
typedef const void *(*ZNM45ClassGetMethodsFn)(void *, void **);
typedef const char *(*ZNM45MethodGetNameFn)(const void *);
typedef uint32_t (*ZNM45MethodGetParamCountFn)(const void *);
typedef void *(*ZNM45MethodGetPointerFn)(const void *);

typedef struct {
    void *handle;
    uintptr_t runtimeBase;
    uint64_t preferredBase;
    uintptr_t execStarts[kZNM45MaxExecRanges];
    uintptr_t execEnds[kZNM45MaxExecRanges];
    NSUInteger execCount;

    ZNM45DomainGetFn domainGet;
    ZNM45DomainGetAssembliesFn domainGetAssemblies;
    ZNM45AssemblyGetImageFn assemblyGetImage;
    ZNM45ImageGetNameFn imageGetName;
    ZNM45ImageGetClassCountFn imageGetClassCount;
    ZNM45ImageGetClassFn imageGetClass;
    ZNM45ClassGetNameFn classGetName;
    ZNM45ClassGetNamespaceFn classGetNamespace;
    ZNM45ClassGetMethodsFn classGetMethods;
    ZNM45MethodGetNameFn methodGetName;
    ZNM45MethodGetParamCountFn methodGetParamCount;
    ZNM45MethodGetPointerFn methodGetPointer;
} ZNM45Runtime;

static NSString *ZNM45String(const char *value) {
    if (!value) return @"";
    NSString *text = [NSString stringWithUTF8String:value];
    return text ?: @"";
}

static NSString *ZNM45NormalizedAssembly(NSString *value) {
    NSString *s = [[value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    return [s hasSuffix:@".dll"] ? [s substringToIndex:s.length - 4] : s;
}

static void *ZNM45ResolveSymbol(ZNM45Runtime *runtime, const char *name) {
    void *symbol = runtime->handle ? dlsym(runtime->handle, name) : NULL;
    if (!symbol) symbol = dlsym(RTLD_DEFAULT, name);
    return symbol;
}

static BOOL ZNM45Executable(const ZNM45Runtime *runtime, uintptr_t address) {
    if (!address) return NO;
    for (NSUInteger i = 0; i < runtime->execCount; i++) {
        if (address >= runtime->execStarts[i] && address < runtime->execEnds[i]) return YES;
    }
    return NO;
}

static BOOL ZNM45LoadRuntime(ZNM45Runtime *runtime, NSString **error) {
    memset(runtime, 0, sizeof(*runtime));
    NSString *unityPath = @"";
    const struct mach_header_64 *header = NULL;

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *raw = _dyld_get_image_name(i);
        if (!raw) continue;
        NSString *path = [NSString stringWithUTF8String:raw] ?: @"";
        if ([path.lastPathComponent isEqualToString:@"UnityFramework"] ||
            [path rangeOfString:@"UnityFramework.framework/UnityFramework" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            unityPath = path;
            header = (const struct mach_header_64 *)_dyld_get_image_header(i);
            break;
        }
    }
    if (!unityPath.length || !header || header->magic != MH_MAGIC_64) {
        if (error) *error = @"M4.5：UnityFramework 尚未加载或不是 arm64 Mach-O";
        return NO;
    }

    runtime->runtimeBase = (uintptr_t)header;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    const uint8_t *commandsEnd = cursor + header->sizeofcmds;
    BOOL foundText = NO;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commandsEnd) break;
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > commandsEnd) break;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if (strncmp(seg->segname, SEG_TEXT, 16) == 0) {
                runtime->preferredBase = seg->vmaddr;
                foundText = YES;
                break;
            }
        }
        cursor += lc->cmdsize;
    }
    if (!foundText) {
        if (error) *error = @"M4.5：UnityFramework 缺少 __TEXT segment";
        return NO;
    }

    cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commandsEnd) break;
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > commandsEnd) break;
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            if ((seg->initprot & VM_PROT_EXECUTE) && seg->vmaddr >= runtime->preferredBase && runtime->execCount < kZNM45MaxExecRanges) {
                uintptr_t start = runtime->runtimeBase + (uintptr_t)(seg->vmaddr - runtime->preferredBase);
                runtime->execStarts[runtime->execCount] = start;
                runtime->execEnds[runtime->execCount] = start + (uintptr_t)seg->vmsize;
                runtime->execCount++;
            }
        }
        cursor += lc->cmdsize;
    }
    if (!runtime->execCount) {
        if (error) *error = @"M4.5：UnityFramework 没有 executable segment";
        return NO;
    }

#ifdef RTLD_NOLOAD
    runtime->handle = dlopen(unityPath.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
#else
    runtime->handle = dlopen(unityPath.fileSystemRepresentation, RTLD_LAZY);
#endif

    runtime->domainGet = (ZNM45DomainGetFn)ZNM45ResolveSymbol(runtime, "il2cpp_domain_get");
    runtime->domainGetAssemblies = (ZNM45DomainGetAssembliesFn)ZNM45ResolveSymbol(runtime, "il2cpp_domain_get_assemblies");
    runtime->assemblyGetImage = (ZNM45AssemblyGetImageFn)ZNM45ResolveSymbol(runtime, "il2cpp_assembly_get_image");
    runtime->imageGetName = (ZNM45ImageGetNameFn)ZNM45ResolveSymbol(runtime, "il2cpp_image_get_name");
    runtime->imageGetClassCount = (ZNM45ImageGetClassCountFn)ZNM45ResolveSymbol(runtime, "il2cpp_image_get_class_count");
    runtime->imageGetClass = (ZNM45ImageGetClassFn)ZNM45ResolveSymbol(runtime, "il2cpp_image_get_class");
    runtime->classGetName = (ZNM45ClassGetNameFn)ZNM45ResolveSymbol(runtime, "il2cpp_class_get_name");
    runtime->classGetNamespace = (ZNM45ClassGetNamespaceFn)ZNM45ResolveSymbol(runtime, "il2cpp_class_get_namespace");
    runtime->classGetMethods = (ZNM45ClassGetMethodsFn)ZNM45ResolveSymbol(runtime, "il2cpp_class_get_methods");
    runtime->methodGetName = (ZNM45MethodGetNameFn)ZNM45ResolveSymbol(runtime, "il2cpp_method_get_name");
    runtime->methodGetParamCount = (ZNM45MethodGetParamCountFn)ZNM45ResolveSymbol(runtime, "il2cpp_method_get_param_count");
    runtime->methodGetPointer = (ZNM45MethodGetPointerFn)ZNM45ResolveSymbol(runtime, "il2cpp_method_get_pointer");

    BOOL complete = runtime->domainGet && runtime->domainGetAssemblies && runtime->assemblyGetImage && runtime->imageGetName &&
                    runtime->imageGetClassCount && runtime->imageGetClass && runtime->classGetName && runtime->classGetNamespace &&
                    runtime->classGetMethods && runtime->methodGetName;
    if (!complete) {
        if (runtime->handle) dlclose(runtime->handle);
        runtime->handle = NULL;
        if (error) *error = @"M4.5：IL2CPP Runtime 缺少 Owning Method 扫描 API";
        return NO;
    }
    return YES;
}

static void ZNM45CloseRuntime(ZNM45Runtime *runtime) {
    if (runtime->handle) dlclose(runtime->handle);
    runtime->handle = NULL;
}

static uintptr_t ZNM45MethodPointer(ZNM45Runtime *runtime, const void *method, NSString **source) {
    if (source) *source = @"unavailable";
    if (!method) return 0;
    if (runtime->methodGetPointer) {
        uintptr_t pointer = (uintptr_t)runtime->methodGetPointer(method);
        if (ZNM45Executable(runtime, pointer)) {
            if (source) *source = @"il2cpp_method_get_pointer";
            return pointer;
        }
    }

    uintptr_t words[2] = {0, 0};
    memcpy(words, method, sizeof(words));
    for (NSUInteger i = 0; i < 2; i++) {
        if (ZNM45Executable(runtime, words[i])) {
            if (source) *source = [NSString stringWithFormat:@"MethodInfo[%lu]", (unsigned long)i];
            return words[i];
        }
    }
    return 0;
}

static NSString *ZNM45CodePreview(uintptr_t address) {
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

static NSDictionary<NSString *, id> *ZNM45RawCandidate(const void *method,
                                                        uintptr_t pointer,
                                                        NSString *pointerSource,
                                                        NSString *assembly,
                                                        NSString *namespaceName,
                                                        NSString *className,
                                                        NSString *methodName,
                                                        NSInteger argumentCount) {
    return @{
        @"methodInfo": @((uintptr_t)method),
        @"methodPointer": @(pointer),
        @"pointerSource": pointerSource ?: @"unavailable",
        @"assembly": assembly ?: @"",
        @"namespace": namespaceName ?: @"",
        @"class": className ?: @"",
        @"method": methodName ?: @"",
        @"argumentCount": @(argumentCount),
    };
}

static NSDictionary<NSString *, id> *ZNM45FinishedCandidate(ZNM45Runtime *runtime,
                                                             NSDictionary<NSString *, id> *raw,
                                                             uint64_t queryRVA,
                                                             uint64_t methodRVA,
                                                             uint64_t nextMethodRVA,
                                                             NSDictionary<NSString *, id> *stats) {
    uint64_t intra = queryRVA >= methodRVA ? queryRVA - methodRVA : 0;
    uintptr_t queryRuntimeVA = runtime->runtimeBase + (uintptr_t)queryRVA;
    uintptr_t methodRuntimeVA = runtime->runtimeBase + (uintptr_t)methodRVA;
    NSInteger argc = [raw[@"argumentCount"] integerValue];
    NSString *namespaceName = raw[@"namespace"] ?: @"";
    NSString *className = raw[@"class"] ?: @"";
    NSString *classPath = namespaceName.length ? [NSString stringWithFormat:@"%@.%@", namespaceName, className] : className;
    NSString *canonical = [NSString stringWithFormat:@"%@!%@::%@%@%@",
                           raw[@"assembly"] ?: @"?",
                           classPath.length ? classPath : @"?",
                           raw[@"method"] ?: @"?",
                           argc >= 0 ? [NSString stringWithFormat:@"/%ld", (long)argc] : @"",
                           intra ? [NSString stringWithFormat:@"+0x%llX", (unsigned long long)intra] : @""];
    BOOL exact = intra == 0;
    uint64_t span = nextMethodRVA > methodRVA ? nextMethodRVA - methodRVA : 0;

    return @{
        @"target": @"UnityFramework",
        @"assembly": raw[@"assembly"] ?: @"",
        @"namespace": namespaceName,
        @"class": className,
        @"method": raw[@"method"] ?: @"",
        @"argumentCount": raw[@"argumentCount"] ?: @(-1),
        @"methodInfo": raw[@"methodInfo"] ?: @0,
        @"methodPointer": raw[@"methodPointer"] ?: @0,
        @"methodRVA": @(methodRVA),
        @"methodRVAText": [NSString stringWithFormat:@"0x%llX", (unsigned long long)methodRVA],
        @"methodRuntimeVA": @((uint64_t)methodRuntimeVA),
        @"queryRVA": @(queryRVA),
        @"queryRVAText": [NSString stringWithFormat:@"0x%llX", (unsigned long long)queryRVA],
        @"rva": @(queryRVA),
        @"rvaText": [NSString stringWithFormat:@"0x%llX", (unsigned long long)queryRVA],
        @"preferredVA": @(runtime->preferredBase + queryRVA),
        @"runtimeVA": @((uint64_t)queryRuntimeVA),
        @"preferredTextVMAddr": @(runtime->preferredBase),
        @"runtimeImageBase": @((uint64_t)runtime->runtimeBase),
        @"slide": @((int64_t)runtime->runtimeBase - (int64_t)runtime->preferredBase),
        @"pointerSource": raw[@"pointerSource"] ?: @"unavailable",
        @"pointerKind": @"owning-method",
        @"canonical": canonical,
        @"delta": @((int64_t)intra),
        @"intraMethodOffset": @(intra),
        @"intraMethodOffsetText": [NSString stringWithFormat:@"+0x%llX", (unsigned long long)intra],
        @"nextMethodRVA": @(nextMethodRVA),
        @"nextMethodRVAText": nextMethodRVA ? [NSString stringWithFormat:@"0x%llX", (unsigned long long)nextMethodRVA] : @"—",
        @"methodSpan": @(span),
        @"ownershipKind": exact ? @"exact-method-entry" : @"bounded-method-interval",
        @"ownershipConfidence": exact ? @"exact" : @"bounded-by-next-known-method",
        @"addressResolved": @YES,
        @"codePreview": ZNM45CodePreview(queryRuntimeVA),
        @"searchMode": @"m4.5-owning-method",
        @"searchStats": stats ?: @{},
    };
}

@implementation ZNIL2CPPOwningMethodResolver

+ (instancetype)sharedResolver {
    static ZNIL2CPPOwningMethodResolver *resolver;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ resolver = [ZNIL2CPPOwningMethodResolver new]; });
    return resolver;
}

- (NSArray<NSDictionary<NSString *,id> *> *)resolveRVA:(uint64_t)rva
                                                  limit:(NSUInteger)limit
                                                  error:(NSString **)error {
    limit = MAX((NSUInteger)1, MIN(limit ?: 16, kZNM45HardCandidateLimit));
    if (rva & 3ULL) {
        if (error) *error = [NSString stringWithFormat:@"M4.5：ARM64 instruction RVA 必须 4 字节对齐：0x%llX", (unsigned long long)rva];
        return nil;
    }

    ZNM45Runtime runtime;
    NSString *runtimeError = nil;
    if (!ZNM45LoadRuntime(&runtime, &runtimeError)) {
        if (error) *error = runtimeError ?: @"M4.5：IL2CPP Runtime 不可用";
        return nil;
    }

    uintptr_t queryRuntimeVA = runtime.runtimeBase + (uintptr_t)rva;
    if (!ZNM45Executable(&runtime, queryRuntimeVA)) {
        ZNM45CloseRuntime(&runtime);
        if (error) *error = [NSString stringWithFormat:@"M4.5：RVA 0x%llX 不在 UnityFramework executable segment", (unsigned long long)rva];
        return nil;
    }

    void *domain = runtime.domainGet();
    size_t assemblyCount = 0;
    const void **assemblies = domain ? runtime.domainGetAssemblies(domain, &assemblyCount) : NULL;
    if (!assemblies || !assemblyCount) {
        ZNM45CloseRuntime(&runtime);
        if (error) *error = @"M4.5：IL2CPP Domain 尚无程序集";
        return nil;
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    NSUInteger assembliesScanned = 0;
    NSUInteger classesScanned = 0;
    NSUInteger methodsScanned = 0;
    BOOL timedOut = NO;
    uint64_t bestStart = 0;
    uint64_t nextStart = 0;
    NSMutableArray<NSDictionary<NSString *, id> *> *best = [NSMutableArray array];

    for (NSUInteger pass = 0; pass < 2 && !timedOut; pass++) {
        for (size_t a = 0; a < assemblyCount && !timedOut; a++) {
            const void *image = runtime.assemblyGetImage(assemblies[a]);
            if (!image) continue;
            NSString *assemblyName = ZNM45String(runtime.imageGetName(image));
            BOOL preferred = [ZNM45NormalizedAssembly(assemblyName) isEqualToString:@"assembly-csharp"];
            if ((pass == 0 && !preferred) || (pass == 1 && preferred)) continue;
            assembliesScanned++;

            size_t classCount = runtime.imageGetClassCount(image);
            for (size_t c = 0; c < classCount; c++) {
                if ((classesScanned & 0x3FULL) == 0 && CFAbsoluteTimeGetCurrent() - started >= kZNM45WallBudgetSeconds) {
                    timedOut = YES;
                    break;
                }
                classesScanned++;
                @autoreleasepool {
                    void *klass = runtime.imageGetClass(image, c);
                    if (!klass) continue;
                    NSString *className = ZNM45String(runtime.classGetName(klass));
                    NSString *namespaceName = ZNM45String(runtime.classGetNamespace(klass));
                    void *iter = NULL;
                    const void *method = NULL;
                    while ((method = runtime.classGetMethods(klass, &iter)) != NULL) {
                        methodsScanned++;
                        NSString *pointerSource = nil;
                        uintptr_t pointer = ZNM45MethodPointer(&runtime, method, &pointerSource);
                        if (!pointer || pointer < runtime.runtimeBase) continue;
                        uint64_t methodRVA = (uint64_t)(pointer - runtime.runtimeBase);
                        NSInteger argc = runtime.methodGetParamCount ? (NSInteger)runtime.methodGetParamCount(method) : -1;
                        NSString *methodName = ZNM45String(runtime.methodGetName(method));

                        if (methodRVA <= rva) {
                            if (methodRVA > bestStart) {
                                bestStart = methodRVA;
                                [best removeAllObjects];
                            }
                            if (methodRVA == bestStart && best.count < limit) {
                                NSDictionary *raw = ZNM45RawCandidate(method, pointer, pointerSource, assemblyName, namespaceName, className, methodName, argc);
                                BOOL duplicate = NO;
                                for (NSDictionary *existing in best) {
                                    if ([existing[@"methodInfo"] unsignedLongLongValue] == [raw[@"methodInfo"] unsignedLongLongValue]) { duplicate = YES; break; }
                                }
                                if (!duplicate) [best addObject:raw];
                            }
                        } else if (!nextStart || methodRVA < nextStart) {
                            nextStart = methodRVA;
                        }
                    }
                }
            }
        }
    }

    BOOL exact = bestStart == rva && best.count > 0;
    BOOL boundedInterior = bestStart < rva && best.count > 0 && nextStart > rva;
    NSDictionary *stats = @{
        @"mode": @"m4.5-owning-method",
        @"assembliesScanned": @(assembliesScanned),
        @"classesScanned": @(classesScanned),
        @"methodsScanned": @(methodsScanned),
        @"candidateCount": @(best.count),
        @"candidateLimit": @(limit),
        @"elapsedMs": @((CFAbsoluteTimeGetCurrent() - started) * 1000.0),
        @"timeLimitHit": @(timedOut),
        @"queryRVA": @(rva),
        @"bestMethodStart": @(bestStart),
        @"nextMethodStart": @(nextStart),
        @"exactMethodEntry": @(exact),
        @"boundedInterior": @(boundedInterior),
    };

    if (!exact && timedOut) {
        ZNM45CloseRuntime(&runtime);
        if (error) *error = [NSString stringWithFormat:@"M4.5：扫描达到 %.0fms 安全预算；内部地址需要完整上界，拒绝猜测所属方法", kZNM45WallBudgetSeconds * 1000.0];
        return nil;
    }
    if (!exact && !boundedInterior) {
        ZNM45CloseRuntime(&runtime);
        if (error) {
            if (!best.count) *error = [NSString stringWithFormat:@"M4.5：找不到 RVA 0x%llX 之前的 IL2CPP 方法入口", (unsigned long long)rva];
            else if (!nextStart) *error = [NSString stringWithFormat:@"M4.5：找到前一方法 0x%llX，但没有下一个方法入口作为安全上界", (unsigned long long)bestStart];
            else *error = [NSString stringWithFormat:@"M4.5：RVA 0x%llX 不属于已知方法区间", (unsigned long long)rva];
        }
        return nil;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *finished = [NSMutableArray arrayWithCapacity:best.count];
    for (NSDictionary *raw in best) {
        [finished addObject:ZNM45FinishedCandidate(&runtime, raw, rva, bestStart, nextStart, stats)];
    }
    ZNM45CloseRuntime(&runtime);

    if (!finished.count) {
        if (error) *error = @"M4.5：所属方法候选为空";
        return nil;
    }

    NSDictionary *first = finished.firstObject;
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m4.5-owning-method] query=0x%llX start=0x%llX next=0x%llX +0x%llX candidates=%lu kind=%@",
                                         (unsigned long long)rva,
                                         (unsigned long long)bestStart,
                                         (unsigned long long)nextStart,
                                         (unsigned long long)(rva - bestStart),
                                         (unsigned long)finished.count,
                                         first[@"ownershipKind"] ?: @"?"]];
    if (error) *error = nil;
    return [finished copy];
}

@end
