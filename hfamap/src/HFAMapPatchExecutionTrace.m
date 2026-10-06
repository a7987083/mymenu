#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

typedef int (*HFASecretDecryptFn)(void *, void *);
extern void HFAProbeKey2Path(uintptr_t getterAddress);
typedef struct { Class cls; SEL sel; IMP imp; } HFAHook;
typedef uintptr_t (*HFABlockInvokeFn)(void *, uintptr_t, uintptr_t, uintptr_t,
                                      uintptr_t, uintptr_t, uintptr_t);
typedef struct {
    void *block;
    HFABlockInvokeFn original;
    char identifier[96];
    char image[256];
    uintptr_t rva;
} HFABlockHook;
typedef struct {
    void *isa;
    int flags;
    int reserved;
    HFABlockInvokeFn invoke;
    void *descriptor;
} HFABlockLiteral;
typedef struct {
    Class owner;
    SEL sel;
    IMP original;
} HFAQueryHook;
typedef struct {
    uintptr_t caller;
    SEL query;
    char identifier[16];
    uintptr_t lastResult;
    unsigned calls;
    unsigned hookLogged;
} HFAStateSite;
typedef struct {
    id owner;
    id offsetWrapper;
    id patchWrapper;
    char module[160];
    char key[128];
    char sourceImage[256];
    unsigned seenEvent;
} HFADescriptor;
typedef struct {
    char label[256];
    char identifier[96];
    char key[128];
} HFAFeatureDefinition;

static HFAHook gHooks[64];
static unsigned gHookCount;
static HFABlockHook gBlockHooks[64];
static unsigned gBlockHookCount;
static HFAQueryHook gQueryHooks[768];
static unsigned gQueryHookCount;
static HFAStateSite gStateSites[256];
static unsigned gStateSiteCount;
static HFADescriptor gDescriptors[128];
static unsigned gDescriptorCount;
static HFAFeatureDefinition gFeatureDefinitions[128];
static unsigned gFeatureDefinitionCount;
static unsigned gEvent;
static char gFeature[256];
static char gFeatureDesc[384];
static char gTarget[256];
static char gIdentifier[96];
static char gWantedKey[128];
static char gDetectedTarget[256];
static char gQueryImage[256];
static unsigned gExecutedEvent;

static HFABlockHook *HFABlockHookFor(void *block) {
    for (unsigned i = 0; i < gBlockHookCount; i++)
        if (gBlockHooks[i].block == block) return &gBlockHooks[i];
    return NULL;
}

static HFAQueryHook *HFAQueryHookFor(Class owner, SEL sel) {
    for (unsigned i = 0; i < gQueryHookCount; i++)
        if (gQueryHooks[i].owner == owner && gQueryHooks[i].sel == sel)
            return &gQueryHooks[i];
    return NULL;
}

static void HFALog(const char *fmt, ...) {
    @autoreleasepool {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/HFAMap_Learn.log"];
        FILE *f = fopen(p.fileSystemRepresentation, "a");
        if (!f) return;
        va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
        fflush(f); fclose(f);
    }
}

static const char *HFABase(const char *p) {
    const char *q = p ? strrchr(p, '/') : NULL;
    return q ? q + 1 : (p ? p : "?");
}

static int HFAImageIndexForName(const char *value) {
    if (!value || !*value) return -1;
    if (strcmp(value, "main") == 0) return 0;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *base = HFABase(_dyld_get_image_name(i));
        if (strcmp(value, base) == 0) return (int)i;
        char stem[256]; snprintf(stem, sizeof(stem), "%s", base);
        char *dot = strrchr(stem, '.'); if (dot) *dot = 0;
        if (strcmp(value, stem) == 0) return (int)i;
    }
    return -1;
}

static HFADescriptor *HFADescriptorFor(id owner, int create) {
    if (!owner) return NULL;
    for (unsigned i = 0; i < gDescriptorCount; i++)
        if (gDescriptors[i].owner == owner) return &gDescriptors[i];
    if (!create || gDescriptorCount >= 128) return NULL;
    HFADescriptor *d = &gDescriptors[gDescriptorCount++];
    memset(d, 0, sizeof(*d));
    d->owner = owner;
    return d;
}

void HFAPatchTraceBeginEvent(unsigned event) {
    gEvent = event;
    gFeature[0] = 0;
    gFeatureDesc[0] = 0;
    gIdentifier[0] = 0;
    gWantedKey[0] = 0;
}

void HFAPatchTraceSetFeature(const char *text) {
    if (!text || !*text) return;
    if (!gFeature[0]) snprintf(gFeature, sizeof(gFeature), "%s", text);
    else if (!gFeatureDesc[0] && strcmp(gFeature, text) != 0)
        snprintf(gFeatureDesc, sizeof(gFeatureDesc), "%s", text);
}

void HFAPatchTraceSetTarget(const char *value) {
    if (value && *value) snprintf(gTarget, sizeof(gTarget), "%s", value);
}

void HFAPatchTraceSetIdentifier(const char *value) {
    if (!value || !*value) return;
    snprintf(gIdentifier, sizeof(gIdentifier), "%s", value);
    snprintf(gWantedKey, sizeof(gWantedKey), "%s-switch", value);
}

const char *HFAPatchTraceDetectedTarget(void) { return gDetectedTarget; }

void HFAPatchTraceConsiderString(const char *value) { (void)value; }

void HFAPatchTraceArm(unsigned event) {
    if (event == gEvent)
        HFALog("[MAP-ARM] event=%u title=%s desc=%s identifier=%s key=%s target=%s\n", event,
               gFeature[0] ? gFeature : "?",
               gFeatureDesc[0] ? gFeatureDesc : "?",
               gIdentifier[0] ? gIdentifier : "?",
               gWantedKey[0] ? gWantedKey : "?",
               gTarget[0] ? gTarget : "?");
}

void HFARegisterPatchSecret(id owner, id wrapper, const char *kind) {
    HFADescriptor *d = HFADescriptorFor(owner, 1);
    if (!d || !wrapper || !kind) return;
    d->seenEvent = gEvent;
    Method m = class_getInstanceMethod(object_getClass(wrapper), sel_registerName("secret"));
    Dl_info info = {0};
    if (m && dladdr((void *)method_getImplementation(m), &info) && info.dli_fname)
        snprintf(d->sourceImage, sizeof(d->sourceImage), "%s", HFABase(info.dli_fname));
    if (strstr(kind, "Int")) d->offsetWrapper = wrapper;
    else if (strstr(kind, "Data")) d->patchWrapper = wrapper;
}

void HFARegisterPatchString(id owner, const char *value) {
    HFADescriptor *d = HFADescriptorFor(owner, 1);
    if (!d || !value || !*value) return;
    d->seenEvent = gEvent;
    const char *normalized = HFABase(value);
    if (HFAImageIndexForName(value) >= 0)
        snprintf(d->module, sizeof(d->module), "%s", value);
    else if (normalized && normalized != value &&
             HFAImageIndexForName(normalized) >= 0) {
        snprintf(d->module, sizeof(d->module), "%s", normalized);
        HFALog("[MODULE-NORMALIZE] input=%s output=%s\n", value, normalized);
    }
    else if (!d->key[0] && strchr(value, '-') && !strchr(value, ' '))
        snprintf(d->key, sizeof(d->key), "%s", value);
}

void HFARegisterFeatureDefinition(const char *label, const char *identifier) {
    if (!label || !*label || !identifier || !*identifier) return;
    char key[128] = {0};
    size_t identifierLength = strlen(identifier);
    if (identifierLength > 7 &&
        strcmp(identifier + identifierLength - 7, "-switch") == 0)
        snprintf(key, sizeof(key), "%s", identifier);
    else
        snprintf(key, sizeof(key), "%s-switch", identifier);
    for (unsigned i = 0; i < gFeatureDefinitionCount; i++) {
        HFAFeatureDefinition *definition = &gFeatureDefinitions[i];
        if (strcmp(definition->key, key) != 0) continue;
        snprintf(definition->label, sizeof(definition->label), "%s", label);
        snprintf(definition->identifier, sizeof(definition->identifier), "%s",
                 identifier);
        return;
    }
    if (gFeatureDefinitionCount >= 128) return;
    HFAFeatureDefinition *definition =
        &gFeatureDefinitions[gFeatureDefinitionCount++];
    memset(definition, 0, sizeof(*definition));
    snprintf(definition->label, sizeof(definition->label), "%s", label);
    snprintf(definition->identifier, sizeof(definition->identifier), "%s",
             identifier);
    snprintf(definition->key, sizeof(definition->key), "%s", key);
}

static HFAFeatureDefinition *HFAFeatureDefinitionForKey(const char *key) {
    if (!key || !*key) return NULL;
    for (unsigned i = 0; i < gFeatureDefinitionCount; i++)
        if (strcmp(gFeatureDefinitions[i].key, key) == 0)
            return &gFeatureDefinitions[i];
    return NULL;
}

static IMP HFAOriginal(Class cls, SEL sel) {
    for (unsigned i = 0; i < gHookCount; i++)
        if (gHooks[i].cls == cls && gHooks[i].sel == sel) return gHooks[i].imp;
    return NULL;
}

static int HFADecryptWrapper(id wrapper, char *out, size_t outCap, const char *label) {
    if (!wrapper || !out || outCap < 2) return 0;
    SEL secretSel = sel_registerName("secret");
    Method getterMethod = class_getInstanceMethod(object_getClass(wrapper), secretSel);
    if (!getterMethod) return 0;
    void *secret = ((void *(*)(id,SEL))objc_msgSend)(wrapper, secretSel);
    if (!secret) return 0;

    uint32_t len = 0, flags = 0;
    memcpy(&len, secret, 4);
    memcpy(&flags, (uint8_t *)secret + 4, 4);
    size_t blobSize = (size_t)(len & ~0xFu) + 0x28u;
    if (blobSize <= 0x28u) blobSize = 0x28u;
    if (!len || len > 0x10000u || blobSize > 0x11000u) return 0;

    IMP getter = method_getImplementation(getterMethod);
    uintptr_t decryptAddress = (uintptr_t)getter + 0xD00u;
    Dl_info getterInfo = {0}, decryptInfo = {0};
    if (!dladdr((void *)getter, &getterInfo) ||
        !dladdr((void *)decryptAddress, &decryptInfo) ||
        getterInfo.dli_fbase != decryptInfo.dli_fbase) return 0;
    uintptr_t getterRVA = (uintptr_t)getter - (uintptr_t)getterInfo.dli_fbase;
    uintptr_t decryptRVA = decryptAddress - (uintptr_t)decryptInfo.dli_fbase;

    uint32_t insn0 = 0, insn30 = 0, insn40 = 0;
    memcpy(&insn0, (void *)decryptAddress, 4);
    memcpy(&insn30, (void *)(decryptAddress + 0x30), 4);
    memcpy(&insn40, (void *)(decryptAddress + 0x40), 4);
    if (insn0 != 0xD105C3FFu || insn30 != 0xB9400408u || insn40 != 0x53187D00u) {
        HFALog("[MAP-DECRYPT-SKIP] field=%s image=%s getterRVA=%llX candidateRVA=%llX fingerprint=%08X/%08X/%08X\n",
               label, HFABase(getterInfo.dli_fname),
               (unsigned long long)getterRVA, (unsigned long long)decryptRVA,
               insn0, insn30, insn40);
        return 0;
    }

    const char *verifiedImage = HFABase(getterInfo.dli_fname);
    if (strcmp(gDetectedTarget, verifiedImage) != 0) {
        snprintf(gDetectedTarget, sizeof(gDetectedTarget), "%s", verifiedImage);
        snprintf(gTarget, sizeof(gTarget), "%s", verifiedImage);
        HFALog("[AUTO-TARGET] image=%s getterRVA=%llX decryptRVA=%llX verified=1\n",
               verifiedImage, (unsigned long long)getterRVA,
               (unsigned long long)decryptRVA);
    }

    void *copy = malloc(blobSize);
    void *plain = calloc(1, (size_t)len + 0x20u);
    if (!copy || !plain) {
        free(copy); free(plain); return 0;
    }
    memcpy(copy, secret, blobSize);
    if ((flags >> 24) == 2u)
        HFAProbeKey2Path((uintptr_t)getter);
    int rc = ((HFASecretDecryptFn)decryptAddress)(copy, plain);
    if (rc == 0) {
        size_t n = len < outCap - 1 ? len : outCap - 1;
        memcpy(out, plain, n);
        out[n] = 0;
    }
    HFALog("[MAP-DECRYPT] field=%s image=%s getterRVA=%llX decryptRVA=%llX len=%u flags=%08X rc=%d plain=%s\n",
           label, HFABase(getterInfo.dli_fname),
           (unsigned long long)getterRVA, (unsigned long long)decryptRVA,
           len, flags, rc, rc == 0 ? out : "?");
    if ((flags >> 24) == 2u) {
        char cipher[129] = {0};
        size_t cipherBytes = len < 32u ? len : 32u;
        const uint8_t *bytes = (const uint8_t *)secret + 8;
        for (size_t i = 0; i < cipherBytes; i++)
            snprintf(cipher + i * 2, sizeof(cipher) - i * 2, "%02X", bytes[i]);
        HFALog("[SECRET02] event=%u field=%s wrapper=%p class=%s image=%s len=%u flags=%08X getterRVA=%llX decryptRVA=%llX rc=%d cipher=%s\n",
               gEvent, label, wrapper, class_getName(object_getClass(wrapper)),
               HFABase(getterInfo.dli_fname), len, flags,
               (unsigned long long)getterRVA, (unsigned long long)decryptRVA,
               rc, cipher);
    }
    free(plain); free(copy);
    return rc == 0;
}

static uintptr_t HFACustomBlockInvoke(void *block, uintptr_t a1, uintptr_t a2,
                                      uintptr_t a3, uintptr_t a4,
                                      uintptr_t a5, uintptr_t a6) {
    HFABlockHook *hook = HFABlockHookFor(block);
    if (!hook || !hook->original) return 0;
    HFALog("[CUSTOM-INVOKE] phase=begin event=%u identifier=%s block=%p image=%s invokeRVA=%llX args=%llX/%llX/%llX/%llX/%llX/%llX\n",
           gEvent, hook->identifier, block, hook->image,
           (unsigned long long)hook->rva,
           (unsigned long long)a1, (unsigned long long)a2,
           (unsigned long long)a3, (unsigned long long)a4,
           (unsigned long long)a5, (unsigned long long)a6);
    uintptr_t result = hook->original(block, a1, a2, a3, a4, a5, a6);
    HFALog("[CUSTOM-INVOKE] phase=end event=%u identifier=%s block=%p image=%s invokeRVA=%llX result=%llX\n",
           gEvent, hook->identifier, block, hook->image,
           (unsigned long long)hook->rva, (unsigned long long)result);
    return result;
}

void HFARegisterCustomBlock(id value, const char *identifier) {
    if (!value || !identifier ||
        (strcmp(identifier, "Fuel") != 0 && strcmp(identifier, "Boost") != 0))
        return;
    void *block = (void *)value;
    HFABlockHook *existing = HFABlockHookFor(block);
    if (existing) {
        snprintf(existing->identifier, sizeof(existing->identifier), "%s", identifier);
        return;
    }
    if (gBlockHookCount >= 64) return;
    HFABlockLiteral *literal = (HFABlockLiteral *)block;
    if (!literal->invoke) return;
    Dl_info info = {0};
    if (!dladdr((void *)literal->invoke, &info) || !info.dli_fbase) return;
    HFABlockHook *hook = &gBlockHooks[gBlockHookCount];
    memset(hook, 0, sizeof(*hook));
    hook->block = block;
    hook->original = literal->invoke;
    hook->rva = (uintptr_t)literal->invoke - (uintptr_t)info.dli_fbase;
    snprintf(hook->identifier, sizeof(hook->identifier), "%s", identifier);
    snprintf(hook->image, sizeof(hook->image), "%s", HFABase(info.dli_fname));

    vm_address_t address = (vm_address_t)(uintptr_t)&literal->invoke;
    vm_address_t region = address;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t regionInfo = {0};
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &region, &regionSize,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&regionInfo,
                                    &infoCount, &objectName);
    int installed = 0;
    if (kr == KERN_SUCCESS) {
        vm_prot_t oldProtection = regionInfo.protection;
        vm_size_t pageSize = (vm_size_t)vm_page_size;
        vm_address_t page = address & ~(pageSize - 1);
        kr = vm_protect(mach_task_self(), page, pageSize, FALSE,
                        oldProtection | VM_PROT_WRITE);
        if (kr == KERN_SUCCESS) {
            literal->invoke = HFACustomBlockInvoke;
            __sync_synchronize();
            vm_protect(mach_task_self(), page, pageSize, FALSE, oldProtection);
            installed = 1;
        }
    }
    HFALog("[CUSTOM-BLOCK] identifier=%s block=%p class=%s image=%s invokeRVA=%llX installed=%d kr=%d\n",
           identifier, block, class_getName(object_getClass(value)), hook->image,
           (unsigned long long)hook->rva, installed, kr);
    if (installed) gBlockHookCount++;
    else memset(hook, 0, sizeof(*hook));
}

static HFAStateSite *HFAStateSiteFor(uintptr_t caller, SEL query,
                                     const char *identifier) {
    for (unsigned i = 0; i < gStateSiteCount; i++) {
        HFAStateSite *site = &gStateSites[i];
        if (site->caller == caller && site->query == query &&
            strcmp(site->identifier, identifier) == 0) return site;
    }
    if (gStateSiteCount >= 256) return NULL;
    HFAStateSite *site = &gStateSites[gStateSiteCount++];
    memset(site, 0, sizeof(*site));
    site->caller = caller;
    site->query = query;
    snprintf(site->identifier, sizeof(site->identifier), "%s", identifier);
    return site;
}

static int64_t HFASignExtend(uint64_t value, unsigned bits) {
    return (int64_t)(value << (64u - bits)) >> (64u - bits);
}

static uintptr_t HFAStripCodePointer(uintptr_t value) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_function_pointer);
#else
    return value;
#endif
}

static int HFAReadable(uintptr_t address, size_t length) {
    vm_address_t region = (vm_address_t)address;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info = {0};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    kern_return_t kr = vm_region_64(mach_task_self(), &region, &regionSize,
                                    VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info, &count, &objectName);
    if (kr != KERN_SUCCESS || !(info.protection & VM_PROT_READ)) return 0;
    return region <= address && address + length >= address &&
           address + length <= region + regionSize;
}

static uintptr_t HFAFindFunctionStart(uintptr_t caller) {
    for (uintptr_t delta = 4; delta <= 0x100; delta += 4) {
        uintptr_t address = caller - delta;
        if (!HFAReadable(address, 4)) break;
        uint32_t word = *(const uint32_t *)address;
        if ((word & 0xFFC003E0u) == 0xA98003E0u) return address;
    }
    return 0;
}

static uintptr_t HFAResolveOriginalSlot(uintptr_t caller) {
    for (uintptr_t forward = 0; forward <= 0x100; forward += 4) {
        uintptr_t branchAddress = caller + forward;
        if (!HFAReadable(branchAddress, 4)) break;
        uint32_t branch = *(const uint32_t *)branchAddress;
        if ((branch & 0xFFFFFC1Fu) != 0xD61F0000u) continue;
        unsigned branchRegister = (branch >> 5) & 31u;
        for (uintptr_t back = 4; back <= 0x40 && back < branchAddress; back += 4) {
            uintptr_t loadAddress = branchAddress - back;
            uint32_t load = *(const uint32_t *)loadAddress;
            if ((load & 0xFFC00000u) != 0xF9400000u ||
                (load & 31u) != branchRegister) continue;
            unsigned baseRegister = (load >> 5) & 31u;
            uintptr_t loadOffset = ((load >> 10) & 0xFFFu) * 8u;
            for (uintptr_t adrpBack = 4; adrpBack <= 0x40 &&
                 adrpBack < loadAddress; adrpBack += 4) {
                uintptr_t adrpAddress = loadAddress - adrpBack;
                uint32_t adrp = *(const uint32_t *)adrpAddress;
                if ((adrp & 0x9F000000u) != 0x90000000u ||
                    (adrp & 31u) != baseRegister) continue;
                uint64_t immediate = (((uint64_t)(adrp >> 5) & 0x7FFFFu) << 2) |
                                     ((adrp >> 29) & 3u);
                int64_t pageDelta = HFASignExtend(immediate, 21) << 12;
                return (adrpAddress & ~(uintptr_t)0xFFFu) +
                       (uintptr_t)pageDelta + loadOffset;
            }
        }
    }
    return 0;
}

static uintptr_t HFAResolveTrampoline(uintptr_t original) {
    if (!original || !HFAReadable(original, 64)) return original;
    Dl_info direct = {0};
    if (dladdr((void *)original, &direct) && direct.dli_fbase) return original;
    for (unsigned i = 0; i < 16; i++) {
        uintptr_t pc = original + i * 4u;
        uint32_t word = *(const uint32_t *)pc;
        if ((word & 0xFC000000u) == 0x14000000u) {
            int64_t displacement = HFASignExtend(word & 0x03FFFFFFu, 26) << 2;
            uintptr_t target = pc + (uintptr_t)displacement;
            Dl_info info = {0};
            if (dladdr((void *)target, &info) && info.dli_fbase) return target;
        }
        if ((word & 0xFF000000u) == 0x58000000u) {
            unsigned targetRegister = word & 31u;
            int64_t displacement = HFASignExtend((word >> 5) & 0x7FFFFu, 19) << 2;
            uintptr_t literal = pc + (uintptr_t)displacement;
            if (!HFAReadable(literal, sizeof(uintptr_t))) continue;
            for (unsigned j = 1; j <= 4 && i + j < 16; j++) {
                uint32_t branch = *(const uint32_t *)(pc + j * 4u);
                if ((branch & 0xFFFFFC1Fu) == 0xD61F0000u &&
                    ((branch >> 5) & 31u) == targetRegister)
                    return HFAStripCodePointer(*(const uintptr_t *)literal);
            }
        }
    }
    return original;
}

static void HFAEmitHookTarget(HFAStateSite *site, uintptr_t caller) {
    Dl_info replacementInfo = {0}, originalInfo = {0}, targetInfo = {0};
    if (!site || !dladdr((void *)caller, &replacementInfo) ||
        !replacementInfo.dli_fbase) return;
    uintptr_t replacement = HFAFindFunctionStart(caller);
    uintptr_t slot = HFAResolveOriginalSlot(caller);
    uintptr_t original = 0;
    if (slot && HFAReadable(slot, sizeof(uintptr_t)))
        original = HFAStripCodePointer(*(const uintptr_t *)slot);
    uintptr_t target = HFAResolveTrampoline(original);
    dladdr((void *)original, &originalInfo);
    dladdr((void *)target, &targetInfo);
    uintptr_t base = (uintptr_t)replacementInfo.dli_fbase;
    uintptr_t originalRVA = originalInfo.dli_fbase
        ? original - (uintptr_t)originalInfo.dli_fbase : 0;
    uintptr_t targetRVA = targetInfo.dli_fbase
        ? target - (uintptr_t)targetInfo.dli_fbase : 0;
    HFALog("[CUSTOM-HOOK-TARGET] identifier=%s replacementImage=%s replacementRVA=%llX callsiteRVA=%llX originalSlotRVA=%llX original=%p originalImage=%s originalRVA=%llX target=%p targetImage=%s targetRVA=%llX\n",
           site->identifier, HFABase(replacementInfo.dli_fname),
           (unsigned long long)(replacement ? replacement - base : 0),
           (unsigned long long)(caller - base),
           (unsigned long long)(slot ? slot - base : 0),
           (void *)original,
           originalInfo.dli_fname ? HFABase(originalInfo.dli_fname) : "?",
           (unsigned long long)originalRVA, (void *)target,
           targetInfo.dli_fname ? HFABase(targetInfo.dli_fname) : "?",
           (unsigned long long)targetRVA);
    uint32_t words[8] = {0};
    if (original && HFAReadable(original, sizeof(words)))
        memcpy(words, (const void *)original, sizeof(words));
    HFALog("[CUSTOM-TRAMPOLINE] identifier=%s original=%p words=%08X/%08X/%08X/%08X/%08X/%08X/%08X/%08X\n",
           site->identifier, (void *)original, words[0], words[1], words[2],
           words[3], words[4], words[5], words[6], words[7]);
}

static uintptr_t HFACustomStateQuery(id self, SEL _cmd, id argument) {
    Class owner = object_getClass(self);
    HFAQueryHook *hook = HFAQueryHookFor(owner, _cmd);
    if (!hook || !hook->original) return 0;
    char identifier[16] = {0};
    if (argument && [argument isKindOfClass:[NSString class]]) {
        const char *s = [(NSString *)argument UTF8String];
        if (s && (strcmp(s, "Fuel") == 0 || strcmp(s, "Boost") == 0))
            snprintf(identifier, sizeof(identifier), "%s", s);
    }
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    uintptr_t result = ((uintptr_t(*)(id,SEL,id))hook->original)(self, _cmd, argument);
    if (!identifier[0]) return result;

    HFAStateSite *site = HFAStateSiteFor(caller, _cmd, identifier);
    if (!site) return result;
    uintptr_t previous = site->lastResult;
    site->calls++;
    site->lastResult = result;
    if (!site->hookLogged) {
        site->hookLogged = 1;
        HFAEmitHookTarget(site, caller);
    }
    if (site->calls != 1 && previous == result) return result;

    Dl_info callerInfo = {0}, queryInfo = {0};
    dladdr((void *)caller, &callerInfo);
    dladdr((void *)hook->original, &queryInfo);
    uintptr_t callerRVA = callerInfo.dli_fbase
        ? caller - (uintptr_t)callerInfo.dli_fbase : 0;
    uintptr_t queryRVA = queryInfo.dli_fbase
        ? (uintptr_t)hook->original - (uintptr_t)queryInfo.dli_fbase : 0;
    HFALog("[CUSTOM-STATE] identifier=%s result=%llu calls=%u queryClass=%s selector=%s queryImage=%s queryRVA=%llX callerImage=%s callerRVA=%llX caller=%p\n",
           identifier, (unsigned long long)result, site->calls,
           class_getName(owner), sel_getName(_cmd),
           queryInfo.dli_fname ? HFABase(queryInfo.dli_fname) : "?",
           (unsigned long long)queryRVA,
           callerInfo.dli_fname ? HFABase(callerInfo.dli_fname) : "?",
           (unsigned long long)callerRVA, (void *)caller);
    return result;
}

static int HFAIntegerReturnWithObjectArgument(Method method) {
    if (!method || method_getNumberOfArguments(method) != 3) return 0;
    char returnType[32] = {0}, argumentType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, argumentType, sizeof(argumentType));
    const char *r = returnType;
    const char *a = argumentType;
    while (*r && strchr("rnNoORV", *r)) r++;
    while (*a && strchr("rnNoORV", *a)) a++;
    if (*a != '@') return 0;
    return strchr("BcCsSiIlLqQ", *r) != NULL;
}

static unsigned HFAInstallQueryMethods(Class owner) {
    if (!owner) return 0;
    unsigned installed = 0;
    unsigned count = 0;
    Method *methods = class_copyMethodList(owner, &count);
    for (unsigned i = 0; methods && i < count; i++) {
        Method method = methods[i];
        if (!HFAIntegerReturnWithObjectArgument(method) ||
            gQueryHookCount >= 768) continue;
        SEL sel = method_getName(method);
        if (HFAQueryHookFor(owner, sel)) continue;
        IMP original = method_getImplementation(method);
        if (!original || original == (IMP)HFACustomStateQuery) continue;
        HFAQueryHook *hook = &gQueryHooks[gQueryHookCount++];
        hook->owner = owner;
        hook->sel = sel;
        hook->original = original;
        method_setImplementation(method, (IMP)HFACustomStateQuery);
        installed++;
    }
    free(methods);
    return installed;
}

static void HFAInstallStateQueriesForImage(const char *image) {
    if (!image || !*image || strcmp(gQueryImage, image) == 0) return;
    int classCount = objc_getClassList(NULL, 0);
    if (classCount <= 0) return;
    Class *classes = malloc((size_t)classCount * sizeof(Class));
    if (!classes) return;
    classCount = objc_getClassList(classes, classCount);
    unsigned matched = 0, installed = 0;
    for (int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        const char *path = class_getImageName(cls);
        if (!path || strcmp(HFABase(path), image) != 0) continue;
        matched++;
        installed += HFAInstallQueryMethods(cls);
        installed += HFAInstallQueryMethods(object_getClass(cls));
    }
    free(classes);
    snprintf(gQueryImage, sizeof(gQueryImage), "%s", image);
    HFALog("[CUSTOM-QUERY-INSTALL] image=%s classes=%u methods=%u total=%u\n",
           image, matched, installed, gQueryHookCount);
}

void HFAPatchTraceObserveAction(id target, SEL action) {
    if (!target || !action) return;
    Class cls = object_getClass(target);
    Method method = class_getInstanceMethod(cls, action);
    if (!method) return;
    IMP implementation = method_getImplementation(method);
    Dl_info info = {0};
    if (!implementation || !dladdr((void *)implementation, &info) ||
        !info.dli_fbase || !info.dli_fname) return;
    const char *image = HFABase(info.dli_fname);
    uintptr_t rva = (uintptr_t)implementation - (uintptr_t)info.dli_fbase;
    HFALog("[ACTION-IMP] event=%u targetClass=%s selector=%s image=%s rva=%llX\n",
           gEvent, class_getName(cls), sel_getName(action), image,
           (unsigned long long)rva);
    HFAInstallStateQueriesForImage(image);
}

static int HFAValidOffset(const char *s) {
    if (!s || !*s) return 0;
    const char *p = s;
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
    if (!*p) return 0;
    for (; *p; p++)
        if (!strchr("0123456789abcdefABCDEF", *p)) return 0;
    return 1;
}

static int HFAValidPatch(const char *s) {
    if (!s || !*s) return 0;
    size_t n = strlen(s);
    if (n & 1) return 0;
    for (const char *p = s; *p; p++)
        if (!strchr("0123456789abcdefABCDEF", *p)) return 0;
    return 1;
}

static NSData *HFADataFromHex(const char *value) {
    if (!HFAValidPatch(value)) return nil;
    size_t length = strlen(value) / 2;
    NSMutableData *data = [NSMutableData dataWithLength:length];
    uint8_t *bytes = data.mutableBytes;
    for (size_t i = 0; i < length; i++) {
        unsigned byte = 0;
        if (sscanf(value + i * 2, "%2x", &byte) != 1) return nil;
        bytes[i] = (uint8_t)byte;
    }
    return data;
}

static NSString *HFAHexData(NSData *data) {
    NSMutableString *result = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [result appendFormat:@"%02X", bytes[i]];
    return result;
}

static NSData *HFAReadOriginalBytes(uint32_t imageIndex, uint64_t rva, NSUInteger length) {
    if (!length || UINT64_MAX - (uint64_t)_dyld_get_image_vmaddr_slide(imageIndex) < rva) return nil;
    vm_address_t address = (vm_address_t)(_dyld_get_image_vmaddr_slide(imageIndex) + rva);
    NSMutableData *data = [NSMutableData dataWithLength:length];
    vm_size_t read = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), address, length,
                                         (vm_address_t)data.mutableBytes, &read);
    return kr == KERN_SUCCESS && read == length ? data : nil;
}

static void HFAWritePatchPackage(NSArray *features, NSDictionary *targets) {
    if (!features.count || !targets.count) return;
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *bundleID = bundle.bundleIdentifier ?: @"unknown.game";
    NSString *shortVersion = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
    NSString *buildVersion = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"0";
#ifdef CPU_SUBTYPE_ARM64E
    const struct mach_header *header = _dyld_get_image_header(0);
    cpu_subtype_t subtype = header ? (header->cpusubtype & ~CPU_SUBTYPE_MASK) : 0;
    NSString *architecture = subtype == CPU_SUBTYPE_ARM64E ? @"arm64e" : @"arm64";
#else
    NSString *architecture = @"arm64";
#endif
    NSDictionary *root = @{
        @"schema": @"com.hfa.patch/v1",
        @"name": [NSString stringWithFormat:@"%@ %@", bundleID, shortVersion],
        @"package": @{ @"bundleIdentifier": bundleID,
                        @"shortVersion": shortVersion,
                        @"buildVersion": buildVersion,
                        @"architectures": @[architecture] },
        @"targets": targets,
        @"features": features
    };
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:&error];
    if (!json) {
        HFALog("[PACKAGE-EXPORT-FAIL] reason=%s\n", error.localizedDescription.UTF8String ?: "json");
        return;
    }
    NSString *safeID = [bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *name = [NSString stringWithFormat:@"%@_%@_%@.hfapatch.json", safeID, shortVersion, buildVersion];
    NSString *path = [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name];
    if ([json writeToFile:path options:NSDataWritingAtomic error:&error])
        HFALog("[PACKAGE-EXPORT] path=%s features=%u targets=%u\n", path.UTF8String,
               (unsigned)features.count, (unsigned)targets.count);
    else
        HFALog("[PACKAGE-EXPORT-FAIL] reason=%s\n", error.localizedDescription.UTF8String ?: "write");
}

static void HFAWriteCompactMapping(const char *feature, const char *module,
                                   const char *offset, const char *patch) {
    if (!feature || !module || !offset || !patch) return;
    @autoreleasepool {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/HFAMap_Mapping.log"];
        FILE *f = fopen(p.fileSystemRepresentation, "a+");
        if (!f) return;
        char wanted[1200];
        snprintf(wanted, sizeof(wanted), "%s\t%s\t%s\t%s\n", feature, module, offset, patch);
        rewind(f);
        char line[1200];
        while (fgets(line, sizeof(line), f)) {
            if (strcmp(line, wanted) == 0) { fclose(f); return; }
        }
        fseek(f, 0, SEEK_END);
        if (ftell(f) == 0) fprintf(f, "feature\tmodule\toffset\tpatch\n");
        fputs(wanted, f);
        fflush(f); fclose(f);
    }
}

unsigned HFAPatchTraceFinalizeScan(void) {
    unsigned groups = 0, emitted = 0, validParts = 0;
    NSMutableArray *exportFeatures = [NSMutableArray array];
    NSMutableDictionary *exportTargets = [NSMutableDictionary dictionary];
    HFALog("[FULL-SCAN-BEGIN] features=%u descriptors=%u\n",
           gFeatureDefinitionCount, gDescriptorCount);
    for (unsigned i = 0; i < gDescriptorCount; i++) {
        HFADescriptor *first = &gDescriptors[i];
        if (!first->key[0]) continue;
        int alreadySeen = 0;
        for (unsigned previous = 0; previous < i; previous++) {
            if (strcmp(gDescriptors[previous].key, first->key) == 0) {
                alreadySeen = 1;
                break;
            }
        }
        if (alreadySeen) continue;
        unsigned count = 0;
        for (unsigned j = i; j < gDescriptorCount; j++)
            if (strcmp(gDescriptors[j].key, first->key) == 0) count++;
        HFAFeatureDefinition *definition =
            HFAFeatureDefinitionForKey(first->key);
        const char *title = definition ? definition->label : "(unresolved)";
        const char *identifier = definition ? definition->identifier : "?";
        groups++;
        unsigned part = 0;
        NSMutableArray *exportPatches = [NSMutableArray array];
        for (unsigned j = i; j < gDescriptorCount; j++) {
            HFADescriptor *descriptor = &gDescriptors[j];
            if (strcmp(descriptor->key, first->key) != 0) continue;
            part++;
            char offset[160] = {0}, normalizedOffset[164] = {0};
            char patch[512] = {0};
            int haveOffset = HFADecryptWrapper(descriptor->offsetWrapper,
                                               offset, sizeof(offset),
                                               "full-offset");
            int havePatch = HFADecryptWrapper(descriptor->patchWrapper,
                                              patch, sizeof(patch),
                                              "full-patchData");
            int valid = haveOffset && havePatch && HFAValidOffset(offset) &&
                        HFAValidPatch(patch) && descriptor->module[0];
            if (haveOffset && offset[0] == '0' &&
                (offset[1] == 'x' || offset[1] == 'X'))
                snprintf(normalizedOffset, sizeof(normalizedOffset), "%s", offset);
            else if (haveOffset && HFAValidOffset(offset))
                snprintf(normalizedOffset, sizeof(normalizedOffset), "0x%s", offset);
            HFALog("[FULL-MAPPING] part=%u/%u title=\"%s\" identifier=%s key=%s source=%s module=%s offset=%s patch=%s valid=%d\n",
                   part, count, title, identifier, descriptor->key,
                   descriptor->sourceImage[0] ? descriptor->sourceImage : "?",
                   descriptor->module[0] ? descriptor->module : "?",
                   normalizedOffset[0] ? normalizedOffset : "?",
                   havePatch ? patch : "?", valid);
            emitted++;
            if (valid) {
                validParts++;
                if (definition)
                    HFAWriteCompactMapping(title, descriptor->module,
                                           normalizedOffset, patch);
                int imageIndex = HFAImageIndexForName(descriptor->module);
                NSData *enabled = HFADataFromHex(patch);
                uint64_t rva = strtoull(normalizedOffset, NULL, 16);
                NSData *original = imageIndex >= 0 ? HFAReadOriginalBytes((uint32_t)imageIndex, rva, enabled.length) : nil;
                if (definition && enabled.length && original.length == enabled.length) {
                    if ([original isEqualToData:enabled]) {
                        HFALog("[PACKAGE-SKIP] title=\"%s\" reason=patch-already-enabled\n", title);
                    } else {
                        NSString *targetID = imageIndex == 0 ? @"main" : [NSString stringWithUTF8String:descriptor->module];
                        NSString *image = imageIndex == 0 ? @"@main" :
                            [NSString stringWithUTF8String:HFABase(_dyld_get_image_name((uint32_t)imageIndex))];
                        exportTargets[targetID] = @{ @"image": image };
                        [exportPatches addObject:@{ @"target": targetID,
                                                   @"offset": [NSString stringWithUTF8String:normalizedOffset],
                                                   @"original": HFAHexData(original),
                                                   @"enabled": [NSString stringWithUTF8String:patch] }];
                    }
                } else if (definition) {
                    HFALog("[PACKAGE-SKIP] title=\"%s\" reason=identity-or-original-unavailable\n", title);
                }
            }
        }
        if (definition && exportPatches.count) {
            NSString *featureID = [NSString stringWithUTF8String:identifier];
            NSString *featureTitle = [NSString stringWithUTF8String:title];
            [exportFeatures addObject:@{ @"id": featureID,
                                         @"title": featureTitle,
                                         @"group": @"Imported",
                                         @"defaultEnabled": @NO,
                                         @"patches": exportPatches }];
        }
    }
    HFALog("[FULL-SCAN-END] groups=%u mappings=%u valid=%u unresolved=%u\n",
           groups, emitted, validParts, emitted - validParts);
    HFAWritePatchPackage(exportFeatures, exportTargets);
    return validParts;
}

static void HFAEmitMapping(id owner, uintptr_t active) {
    HFADescriptor *d = HFADescriptorFor(owner, 0);
    if (!d) {
        HFALog("[MAP-MISS] event=%u owner=%p reason=no-descriptor\n", gEvent, owner);
        return;
    }
    char offset[160] = {0}, patch[512] = {0};
    int haveOffset = HFADecryptWrapper(d->offsetWrapper, offset, sizeof(offset), "offset");
    int havePatch = HFADecryptWrapper(d->patchWrapper, patch, sizeof(patch), "patchData");
    int valid = haveOffset && havePatch && HFAValidOffset(offset) && HFAValidPatch(patch);
    char normalizedOffset[164] = {0};
    if (haveOffset && offset[0] == '0' && (offset[1] == 'x' || offset[1] == 'X'))
        snprintf(normalizedOffset, sizeof(normalizedOffset), "%s", offset);
    else if (haveOffset && HFAValidOffset(offset))
        snprintf(normalizedOffset, sizeof(normalizedOffset), "0x%s", offset);
    HFALog("[MAPPING] title=\"%s\" desc=\"%s\" key=%s module=%s offset=%s patch=%s active=%u valid=%d\n",
           gFeature[0] ? gFeature : "(not found)",
           gFeatureDesc[0] ? gFeatureDesc : "(not found)",
           d->key[0] ? d->key : "?",
           d->module[0] ? d->module : "?",
           normalizedOffset[0] ? normalizedOffset : "?",
           havePatch ? patch : "?",
           (unsigned)(active != 0), valid);
    if (valid && gFeature[0] && d->module[0] && normalizedOffset[0])
        HFAWriteCompactMapping(gFeature, d->module, normalizedOffset, patch);
}

void HFAPatchTraceFinalizeEvent(unsigned event) {
    if (event != gEvent || !gWantedKey[0]) return;
    unsigned count = 0;
    for (unsigned i = 0; i < gDescriptorCount; i++) {
        HFADescriptor *d = &gDescriptors[i];
        if (d->seenEvent == event && strcmp(d->key, gWantedKey) == 0) count++;
    }
    const char *status = gExecutedEvent == event ? "EXECUTED" : "NOT_EXECUTED";
    HFALog("[GROUP] event=%u title=\"%s\" identifier=%s key=%s members=%u status=%s\n",
           event, gFeature[0] ? gFeature : "(not found)", gIdentifier,
           gWantedKey, count, status);
    unsigned part = 0;
    for (unsigned i = 0; i < gDescriptorCount; i++) {
        HFADescriptor *d = &gDescriptors[i];
        if (d->seenEvent != event || strcmp(d->key, gWantedKey) != 0) continue;
        part++;
        char offset[160] = {0}, normalizedOffset[164] = {0}, patch[512] = {0};
        int haveOffset = HFADecryptWrapper(d->offsetWrapper, offset, sizeof(offset), "group-offset");
        int havePatch = HFADecryptWrapper(d->patchWrapper, patch, sizeof(patch), "group-patchData");
        int valid = haveOffset && havePatch && HFAValidOffset(offset) && HFAValidPatch(patch);
        if (haveOffset && offset[0] == '0' && (offset[1] == 'x' || offset[1] == 'X'))
            snprintf(normalizedOffset, sizeof(normalizedOffset), "%s", offset);
        else if (haveOffset && HFAValidOffset(offset))
            snprintf(normalizedOffset, sizeof(normalizedOffset), "0x%s", offset);
        HFALog("[GROUP-MAPPING] event=%u part=%u/%u title=\"%s\" identifier=%s key=%s source=%s module=%s offset=%s patch=%s status=%s valid=%d\n",
               event, part, count, gFeature[0] ? gFeature : "(not found)",
               gIdentifier, gWantedKey, d->sourceImage[0] ? d->sourceImage : "?",
               d->module[0] ? d->module : "?",
               normalizedOffset[0] ? normalizedOffset : "?",
               havePatch ? patch : "?", status, valid);
        if (valid && gFeature[0] && d->module[0] && normalizedOffset[0])
            HFAWriteCompactMapping(gFeature, d->module, normalizedOffset, patch);
    }
}

static void HFASetActiveHook(id self, SEL _cmd, uintptr_t active) {
    Class cls = object_getClass(self);
    IMP orig = HFAOriginal(cls, _cmd);
    gExecutedEvent = gEvent;
    HFAEmitMapping(self, active);
    if (orig) ((void(*)(id,SEL,uintptr_t))orig)(self, _cmd, active);
}

void HFARegisterPatchObject(id obj, const char *actualClass) {
    if (!obj) return;
    HFADescriptor *d = HFADescriptorFor(obj, 1);
    if (d) d->seenEvent = gEvent;
    Class cls = object_getClass(obj);
    if (!cls) return;
    SEL sel = sel_registerName("setActive:");
    for (unsigned i = 0; i < gHookCount; i++)
        if (gHooks[i].cls == cls && gHooks[i].sel == sel) return;
    if (gHookCount >= 64) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != 3) {
        HFALog("[MAP-OBJECT] class=%s object=%p setActive=missing\n",
               actualClass ? actualClass : class_getName(cls), obj);
        return;
    }
    IMP old = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, sel, (IMP)HFASetActiveHook, types))
        method_setImplementation(method, (IMP)HFASetActiveHook);
    gHooks[gHookCount++] = (HFAHook){cls, sel, old};
    HFALog("[MAP-OBJECT] class=%s object=%p selector=setActive: orig=%p\n",
           actualClass ? actualClass : class_getName(cls), obj, old);
}

__attribute__((constructor)) static void HFAInit(void) {
    HFALog("[HFALearn v1.8.7 KeyRegisterProbe] loaded\n");
}
