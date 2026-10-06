#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

#if 0
static int gKey2PathDone;
static uintptr_t gKeyRegistryMaskAddress;
static uintptr_t gKeyTableAddress;
static uintptr_t gKeyImageBase;
static uintptr_t gKeyBundleLoaderAddress;
static uint64_t gLastLifecycleMask = UINT64_MAX;
static uintptr_t gLastLifecycleSlot2 = UINTPTR_MAX;
static uint64_t gLastLifecycleFingerprint = UINT64_MAX;
static unsigned gLifecycleTick;
static uintptr_t (*gOriginalKeyBundleLoader)(const void *, size_t,
                                              const uint8_t *, void *);

typedef void (*HFAMSHookFunction)(void *, void *, void **);

static void HFAInstallKeyBundleHook(uintptr_t base);

static const char *HFABaseName(const char *path) {
    const char *p = path ? strrchr(path, '/') : NULL;
    return p ? p + 1 : (path ? path : "?");
}

static void HFAKey2Log(const char *fmt, ...) {
    @autoreleasepool {
        NSString *path = [NSHomeDirectory()
            stringByAppendingPathComponent:@"Documents/HFAMap_Learn.log"];
        FILE *f = fopen(path.fileSystemRepresentation, "a");
        if (!f) return;
        va_list ap;
        va_start(ap, fmt);
        vfprintf(f, fmt, ap);
        va_end(ap);
        fflush(f);
        fclose(f);
    }
}

static uintptr_t HFAStripPointer(uintptr_t value) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)value,
                                    ptrauth_key_function_pointer);
#else
    return value;
#endif
}

static uint64_t HFANonzeroKeyMask(const uint8_t *keys) {
    if (!keys) return 0;
    uint64_t mask = 0;
    for (unsigned keyId = 0; keyId < 64; keyId++) {
        uint8_t combined = 0;
        for (unsigned byte = 0; byte < 16; byte++)
            combined |= keys[keyId * 16 + byte];
        if (combined) mask |= 1ULL << keyId;
    }
    return mask;
}

static int HFASafeRead(uintptr_t address, void *output, size_t length) {
    if (!address || !output || !length) return 0;
    vm_size_t copied = 0;
    kern_return_t result = vm_read_overwrite(
        mach_task_self(), (vm_address_t)address,
        (vm_size_t)length, (vm_address_t)output, &copied);
    return result == KERN_SUCCESS && copied == length;
}

static uint64_t HFAFingerprint(const uint8_t *bytes, size_t length) {
    // Stable, one-way diagnostic fingerprint. Raw key bytes are never logged.
    uint64_t hash = 1469598103934665603ULL;
    for (size_t i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    return hash;
}

static void HFAKey2LifecycleTick(void);

static void HFAScheduleKey2LifecycleTick(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        HFAKey2LifecycleTick();
    });
}

static void HFAKey2LifecycleTick(void) {
    if (!gKeyImageBase || !gKeyRegistryMaskAddress || !gKeyTableAddress) return;
    gLifecycleTick++;
    uint64_t mask = 0;
    uintptr_t slots[4] = {0};
    int maskReadable = HFASafeRead(gKeyRegistryMaskAddress, &mask, sizeof(mask));
    int tableReadable = HFASafeRead(gKeyTableAddress, slots, sizeof(slots));
    uintptr_t slot2 = tableReadable ? slots[2] : 0;
    uint8_t window[64] = {0};
    int slotReadable = slot2 && HFASafeRead(slot2, window, sizeof(window));
    uint64_t fingerprint = slotReadable ? HFAFingerprint(window, sizeof(window)) : 0;
    int changed = mask != gLastLifecycleMask || slot2 != gLastLifecycleSlot2 ||
                  fingerprint != gLastLifecycleFingerprint;
    if (changed || gLifecycleTick == 1 || (gLifecycleTick % 30) == 0) {
        HFAKey2Log("[KEY2-LIFECYCLE] tick=%u maskReadable=%u tableReadable=%u mask=%016llX key2Mask=%u slot2=%p slotReadable=%u fingerprint64=%016llX changed=%u\n",
                   gLifecycleTick, maskReadable ? 1u : 0u,
                   tableReadable ? 1u : 0u, (unsigned long long)mask,
                   (unsigned)((mask >> 2) & 1), (void *)slot2,
                   slotReadable ? 1u : 0u,
                   (unsigned long long)fingerprint, changed ? 1u : 0u);
        gLastLifecycleMask = mask;
        gLastLifecycleSlot2 = slot2;
        gLastLifecycleFingerprint = fingerprint;
    }
    if (!gOriginalKeyBundleLoader && (gLifecycleTick % 5) == 0)
        HFAInstallKeyBundleHook(gKeyImageBase);
    HFAScheduleKey2LifecycleTick();
}

static uintptr_t HFAKeyBundleLoaderHook(const void *payload,
                                         size_t payloadLength,
                                         const uint8_t *keys,
                                         void *authorizationContext) {
    uint64_t suppliedMask = HFANonzeroKeyMask(keys);
    HFAKey2Log("[KEY2-AUTH-LOAD-BEGIN] payload=%p len=%llu keys=%p nonzeroMask=%016llX key2=%u context=%p\n",
               payload, (unsigned long long)payloadLength, keys,
               (unsigned long long)suppliedMask,
               (unsigned)((suppliedMask >> 2) & 1),
               authorizationContext);

    uintptr_t result = gOriginalKeyBundleLoader
        ? gOriginalKeyBundleLoader(payload, payloadLength, keys,
                                   authorizationContext)
        : 0;

    uint64_t registryMask = 0;
    if (gKeyRegistryMaskAddress)
        memcpy(&registryMask, (const void *)gKeyRegistryMaskAddress,
               sizeof(registryMask));
    HFAKey2Log("[KEY2-AUTH-LOAD-END] result=%p registryMask=%016llX key2=%u\n",
               (void *)result, (unsigned long long)registryMask,
               (unsigned)((registryMask >> 2) & 1));
    return result;
}

static void HFAInstallKeyBundleHook(uintptr_t base) {
    if (gOriginalKeyBundleLoader) return;
    uintptr_t loader = gKeyBundleLoaderAddress ? gKeyBundleLoaderAddress
                                                : base + 0x995914u;
    uint32_t fingerprint[2] = {0};
    memcpy(fingerprint, (const void *)loader, sizeof(fingerprint));
    if (fingerprint[0] != 0xD10643FFu ||
        fingerprint[1] != 0xA9136FFCu) {
        HFAKey2Log("[KEY2-AUTH-HOOK-SKIP] loaderRVA=%llX fingerprint=%08X/%08X\n",
                   (unsigned long long)(loader - base), fingerprint[0], fingerprint[1]);
        return;
    }

    HFAMSHookFunction hook = (HFAMSHookFunction)dlsym(
        RTLD_DEFAULT, "MSHookFunction");
    if (!hook) {
        HFAKey2Log("[KEY2-AUTH-HOOK-SKIP] loaderRVA=%llX reason=no-MSHookFunction\n",
                   (unsigned long long)(loader - base));
        return;
    }
    hook((void *)loader, (void *)&HFAKeyBundleLoaderHook,
         (void **)&gOriginalKeyBundleLoader);
    HFAKey2Log("[KEY2-AUTH-HOOK] loaderRVA=%llX installed=%u original=%p\n",
               (unsigned long long)(loader - base), gOriginalKeyBundleLoader ? 1u : 0u,
               (void *)gOriginalKeyBundleLoader);
}

static void HFAKey2ImageAdded(const struct mach_header *header,
                              intptr_t slide) {
    (void)slide;
    if (!header || gOriginalKeyBundleLoader) return;
    Dl_info info = {0};
    if (!dladdr((const void *)header, &info) || !info.dli_fbase ||
        strcmp(HFABaseName(info.dli_fname), "RiseofBerk.dylib") != 0)
        return;
    uintptr_t base = (uintptr_t)info.dli_fbase;
    gKeyImageBase = base;
    gKeyTableAddress = base + 0xD31D40u;
    gKeyRegistryMaskAddress = base + 0xCFC9C0u;
    gKeyBundleLoaderAddress = base + 0x995914u;
    HFAKey2Log("[KEY2-AUTH-EARLY] image=RiseofBerk.dylib base=%p\n",
               (void *)base);
    HFAInstallKeyBundleHook(base);
    HFAKey2LifecycleTick();
}

__attribute__((constructor))
static void HFAKey2AuthTraceInit(void) {
    _dyld_register_func_for_add_image(HFAKey2ImageAdded);
}
#endif

static int gKey2PathDone;
static uintptr_t gRegisterImageBase;
static uintptr_t (*gOriginalKeyRegister)(uintptr_t, uintptr_t, uintptr_t,
                                          uintptr_t, uintptr_t, uintptr_t);

typedef int (*HFADobbyHookFn)(void *, void *, void **);
typedef void (*HFAMSHookFunction)(void *, void *, void **);

static const char *HFABaseName(const char *path) {
    const char *p = path ? strrchr(path, '/') : NULL;
    return p ? p + 1 : (path ? path : "?");
}

static void HFAKey2Log(const char *fmt, ...) {
    @autoreleasepool {
        NSString *path = [NSHomeDirectory()
            stringByAppendingPathComponent:@"Documents/HFAMap_Learn.log"];
        FILE *f = fopen(path.fileSystemRepresentation, "a");
        if (!f) return;
        va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
        fflush(f); fclose(f);
    }
}

static uintptr_t HFAStripPointer(uintptr_t value) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)value,
                                    ptrauth_key_function_pointer);
#else
    return value;
#endif
}

static int HFASafeFingerprint(uintptr_t address, size_t length,
                              uint64_t *fingerprint) {
    if (!address || !length || length > 64 || !fingerprint) return 0;
    uint8_t bytes[64] = {0};
    vm_size_t copied = 0;
    kern_return_t result = vm_read_overwrite(
        mach_task_self(), (vm_address_t)address, (vm_size_t)length,
        (vm_address_t)bytes, &copied);
    if (result != KERN_SUCCESS || copied != length) return 0;
    uint64_t hash = 1469598103934665603ULL;
    for (size_t i = 0; i < length; i++) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    *fingerprint = hash;
    return 1;
}

static uintptr_t HFAKeyRegisterHook(uintptr_t a0, uintptr_t a1,
                                    uintptr_t a2, uintptr_t a3,
                                    uintptr_t a4, uintptr_t a5) {
    uint64_t fp16 = 0, fp32 = 0, fp64 = 0;
    unsigned read16 = HFASafeFingerprint(a0, 16, &fp16) ? 1u : 0u;
    unsigned read32 = HFASafeFingerprint(a0, 32, &fp32) ? 1u : 0u;
    unsigned read64 = HFASafeFingerprint(a0, 64, &fp64) ? 1u : 0u;
    unsigned keyId = (unsigned)(a1 & 0xFFFFFFFFu);
    unsigned long long lengthCandidate = a2 > 0 && a2 <= 4096
        ? (unsigned long long)a2 : 0;
    HFAKey2Log("[KEY-REGISTER-BEGIN] keyId=%u keyPtr=%p lengthCandidate=%llu readable16=%u fingerprint16=%016llX readable32=%u fingerprint32=%016llX readable64=%u fingerprint64=%016llX\n",
               keyId, (void *)a0, lengthCandidate, read16,
               (unsigned long long)fp16, read32, (unsigned long long)fp32,
               read64, (unsigned long long)fp64);
    uintptr_t result = gOriginalKeyRegister
        ? gOriginalKeyRegister(a0, a1, a2, a3, a4, a5) : 0;
    HFAKey2Log("[KEY-REGISTER-END] keyId=%u result=%p\n",
               keyId, (void *)result);
    return result;
}

static void HFAInstallKeyRegisterHook(uintptr_t base,
                                      uintptr_t registerAddress) {
    if (gOriginalKeyRegister) return;
    gRegisterImageBase = base;
    const char *backend = "none";
    HFAMSHookFunction substrate = (HFAMSHookFunction)dlsym(
        RTLD_DEFAULT, "MSHookFunction");
    if (substrate) {
        substrate((void *)registerAddress, (void *)&HFAKeyRegisterHook,
                  (void **)&gOriginalKeyRegister);
        backend = "MSHookFunction";
    } else {
        HFADobbyHookFn dobby = (HFADobbyHookFn)dlsym(RTLD_DEFAULT,
                                                     "DobbyHook");
        if (dobby) {
            int status = dobby((void *)registerAddress,
                               (void *)&HFAKeyRegisterHook,
                               (void **)&gOriginalKeyRegister);
            backend = status == 0 ? "DobbyHook" : "DobbyHook-failed";
        }
    }
    HFAKey2Log("[KEY-REGISTER-HOOK] registerRVA=%llX backend=%s installed=%u original=%p\n",
               (unsigned long long)(registerAddress - gRegisterImageBase),
               backend, gOriginalKeyRegister ? 1u : 0u,
               (void *)gOriginalKeyRegister);
}

static uintptr_t HFABLTarget(uintptr_t pc, uint32_t instruction) {
    int64_t immediate = instruction & 0x03FFFFFFu;
    if (immediate & 0x02000000LL) immediate |= ~0x03FFFFFFLL;
    return (uintptr_t)((int64_t)pc + (immediate << 2));
}

static int HFAFindText(uintptr_t base, uintptr_t *startOut,
                       uintptr_t *endOut) {
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)base;
    if (!header || header->magic != MH_MAGIC_64) return 0;
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command =
            (const struct load_command *)cursor;
        if (!command->cmdsize) return 0;
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment =
                (const struct segment_command_64 *)cursor;
            const struct section_64 *section =
                (const struct section_64 *)(segment + 1);
            for (uint32_t j = 0; j < segment->nsects; j++) {
                if (strncmp(section[j].sectname, "__text", 16) == 0) {
                    uintptr_t start = base + (uintptr_t)section[j].addr;
                    uintptr_t size = (uintptr_t)section[j].size;
                    if (!size || size > 0x2000000u ||
                        start + size < start) return 0;
                    *startOut = start;
                    *endOut = start + size;
                    return 1;
                }
            }
        }
        cursor += command->cmdsize;
    }
    return 0;
}

static uintptr_t HFAFindFunctionStart(uintptr_t textStart,
                                      uintptr_t caller) {
    uintptr_t best = 0;
    for (uintptr_t delta = 4; delta <= 0x1000 && caller >= delta;
         delta += 4) {
        uintptr_t address = caller - delta;
        if (address < textStart) break;
        uint32_t word = 0;
        memcpy(&word, (const void *)address, 4);
        if ((word & 0xFFC003FFu) == 0xD10003FFu) {
            best = address;
            break;
        }
        if (word == 0xD65F03C0u) {
            best = address + 4;
            break;
        }
    }
    return best;
}

static unsigned HFAAddUnique(uintptr_t *values, unsigned count,
                             unsigned capacity, uintptr_t value) {
    if (!value) return count;
    for (unsigned i = 0; i < count; i++)
        if (values[i] == value) return count;
    if (count < capacity) values[count++] = value;
    return count;
}

static unsigned HFAScanXrefs(uintptr_t base, uintptr_t textStart,
                             uintptr_t textEnd, const uintptr_t *targets,
                             unsigned targetCount, unsigned depth,
                             uintptr_t *functions, unsigned functionCount,
                             unsigned functionCapacity) {
    for (uintptr_t pc = textStart; pc + 4 <= textEnd; pc += 4) {
        uint32_t instruction = 0;
        memcpy(&instruction, (const void *)pc, 4);
        if ((instruction & 0xFC000000u) != 0x94000000u) continue;
        uintptr_t target = HFABLTarget(pc, instruction);
        int match = 0;
        for (unsigned i = 0; i < targetCount; i++)
            if (target == targets[i]) { match = 1; break; }
        if (!match) continue;
        uintptr_t function = HFAFindFunctionStart(textStart, pc);
        uint32_t context[8] = {0};
        uintptr_t contextStart = pc >= textStart + 16 ? pc - 16 : pc;
        for (unsigned i = 0; i < 8 &&
             contextStart + i * 4 + 4 <= textEnd; i++)
            memcpy(&context[i], (const void *)(contextStart + i * 4), 4);
        HFAKey2Log("[KEY2-XREF] depth=%u targetRVA=%llX callsiteRVA=%llX functionRVA=%llX ctx=%08X/%08X/%08X/%08X/%08X/%08X/%08X/%08X\n",
                   depth,
                   (unsigned long long)(target - base),
                   (unsigned long long)(pc - base),
                   function ? (unsigned long long)(function - base) : 0,
                   context[0], context[1], context[2], context[3],
                   context[4], context[5], context[6], context[7]);
        functionCount = HFAAddUnique(functions, functionCount,
                                     functionCapacity, function);
    }
    return functionCount;
}

static void HFALogMethodsForNodes(uintptr_t base, const char *image,
                                  const uintptr_t *nodes,
                                  unsigned nodeCount) {
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return;
    Class *classes = malloc((size_t)classCount * sizeof(Class));
    if (!classes) return;
    classCount = objc_getClassList(classes, classCount);
    unsigned matches = 0;
    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *classImage = class_getImageName(cls);
        if (!classImage ||
            strcmp(HFABaseName(classImage), image) != 0) continue;
        Class owners[2] = {cls, object_getClass(cls)};
        for (unsigned kind = 0; kind < 2; kind++) {
            unsigned methodCount = 0;
            Method *methods = class_copyMethodList(owners[kind],
                                                   &methodCount);
            for (unsigned m = 0; methods && m < methodCount; m++) {
                uintptr_t implementation = HFAStripPointer(
                    (uintptr_t)method_getImplementation(methods[m]));
                for (unsigned n = 0; n < nodeCount; n++) {
                    if (implementation != nodes[n]) continue;
                    HFAKey2Log("[KEY2-METHOD] kind=%c class=%s selector=%s rva=%llX\n",
                               kind ? '+' : '-',
                               class_getName(cls),
                               sel_getName(method_getName(methods[m])),
                               (unsigned long long)(implementation - base));
                    matches++;
                }
            }
            free(methods);
        }
    }
    free(classes);
    HFAKey2Log("[KEY2-METHOD-END] matches=%u nodes=%u\n",
               matches, nodeCount);
}

void HFAProbeKey2Path(uintptr_t getterAddress) {
    if (gKey2PathDone || !getterAddress) return;
    Dl_info info = {0};
    if (!dladdr((void *)getterAddress, &info) || !info.dli_fbase) return;
    uintptr_t base = (uintptr_t)info.dli_fbase;
    uintptr_t getterRVA = getterAddress - base;
    const char *image = HFABaseName(info.dli_fname);
    uintptr_t registerAddress = getterAddress + 0x1F38u;
    uintptr_t loaderAddress = getterAddress + 0xA70u;
    uint32_t registerInsn = 0, loaderInsn = 0;
    memcpy(&registerInsn, (const void *)registerAddress, 4);
    memcpy(&loaderInsn, (const void *)loaderAddress, 4);
    if (registerInsn != 0xA9BD57F6u ||
        loaderInsn != 0xD10643FFu) {
        HFAKey2Log("[KEY2-PATH-SKIP] image=%s fingerprint=%08X/%08X\n",
                   image, registerInsn, loaderInsn);
        return;
    }
    gKey2PathDone = 1;

    uintptr_t textStart = 0, textEnd = 0;
    if (!HFAFindText(base, &textStart, &textEnd)) {
        HFAKey2Log("[KEY2-PATH-SKIP] image=%s reason=no-text\n", image);
        return;
    }

    HFAKey2Log("[KEY2-PATH-BEGIN] image=%s base=%p getterRVA=%llX textRVA=%llX-%llX registerRVA=%llX loaderRVA=%llX\n",
               image, (void *)base,
               (unsigned long long)getterRVA,
               (unsigned long long)(textStart - base),
               (unsigned long long)(textEnd - base),
               (unsigned long long)(registerAddress - base),
               (unsigned long long)(loaderAddress - base));
    HFAInstallKeyRegisterHook(base, registerAddress);

    uintptr_t targets[64] = {registerAddress, loaderAddress};
    unsigned targetCount = 2;
    uintptr_t nodes[128] = {registerAddress, loaderAddress};
    unsigned nodeCount = 2;
    for (unsigned depth = 0; depth < 3 && targetCount; depth++) {
        uintptr_t functions[64] = {0};
        unsigned functionCount = HFAScanXrefs(
            base, textStart, textEnd, targets, targetCount, depth,
            functions, 0, 64);
        targetCount = 0;
        for (unsigned i = 0; i < functionCount; i++) {
            unsigned oldCount = nodeCount;
            nodeCount = HFAAddUnique(nodes, nodeCount, 128, functions[i]);
            if (nodeCount != oldCount && targetCount < 64)
                targets[targetCount++] = functions[i];
        }
        HFAKey2Log("[KEY2-XREF-DEPTH-END] depth=%u functions=%u next=%u\n",
                   depth, functionCount, targetCount);
    }
    HFALogMethodsForNodes(base, image, nodes, nodeCount);
    HFAKey2Log("[KEY2-PATH-END] nodes=%u\n", nodeCount);
}
