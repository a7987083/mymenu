#import "ZNAnyImageAddressResolver.h"
#import "ZNPatchRuntimeValidator.h"
#import "ZNPatchCore.h"

#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#import <objc/runtime.h>

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

// Address semantics are intentionally resolved from the exact loaded Mach-O.
// Never infer a base from the textual shape of an address (for example 0x100...).

typedef NS_ENUM(NSInteger, ZNARKind) {
    ZNARKindUnknown = 0,
    ZNARKindRVA,
    ZNARKindPreferredVA,
    ZNARKindRuntimeVA,
    ZNARKindFileOffset,
};

static NSString *ZNARKindName(ZNARKind kind) {
    switch (kind) {
        case ZNARKindRVA: return @"RVA";
        case ZNARKindPreferredVA: return @"Preferred VA";
        case ZNARKindRuntimeVA: return @"Runtime VA";
        case ZNARKindFileOffset: return @"File Offset";
        default: return @"Unknown";
    }
}

struct ZNARSegment {
    uint64_t vmaddr;
    uint64_t vmsize;
    uint64_t fileoff;
    uint64_t filesize;
    vm_prot_t initprot;
    vm_prot_t maxprot;
    char name[17];
};

struct ZNARLayout {
    uint64_t imageVMBase;
    std::vector<ZNARSegment> segments;
};

@interface ZNARResolution : NSObject
@property(nonatomic,copy) NSString *originalInput;
@property(nonatomic,copy) NSString *targetInput;
@property(nonatomic,copy) NSString *canonicalTarget;
@property(nonatomic,copy) NSString *imagePath;
@property(nonatomic,copy) NSString *segmentName;
@property(nonatomic,copy) NSString *protectionText;
@property(nonatomic,assign) ZNARKind kind;
@property(nonatomic,assign) uint64_t inputValue;
@property(nonatomic,assign) uint64_t rva;
@property(nonatomic,assign) uint64_t preferredVA;
@property(nonatomic,assign) uint64_t runtimeVA;
@property(nonatomic,assign) uint64_t fileOffset;
@property(nonatomic,assign) uint64_t imageVMBase;
@property(nonatomic,assign) int64_t slide;
@end
@implementation ZNARResolution @end

static NSString *ZNARProtection(vm_prot_t p) {
    return [NSString stringWithFormat:@"%@%@%@",
            (p & VM_PROT_READ) ? @"R" : @"-",
            (p & VM_PROT_WRITE) ? @"W" : @"-",
            (p & VM_PROT_EXECUTE) ? @"X" : @"-"];
}

static BOOL ZNARParseInteger(NSString *text, uint64_t *outValue) {
    NSString *s = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!s.length) return NO;
    const char *c = s.UTF8String;
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(c, &end, 0);
    if (errno || end == c || (end && *end)) {
        errno = 0; end = NULL;
        value = strtoull(c, &end, 16);
    }
    if (errno || end == c || (end && *end)) return NO;
    if (outValue) *outValue = (uint64_t)value;
    return YES;
}

static NSString *ZNARStripQualifier(NSString *raw, ZNARKind *explicitKind) {
    NSString *trim = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *lower = trim.lowercaseString;
    NSArray<NSArray *> *prefixes = @[
        @[@"rva:", @(ZNARKindRVA)],
        @[@"va:", @(ZNARKindPreferredVA)],
        @[@"preferred:", @(ZNARKindPreferredVA)],
        @[@"preferredva:", @(ZNARKindPreferredVA)],
        @[@"runtime:", @(ZNARKindRuntimeVA)],
        @[@"runtimeva:", @(ZNARKindRuntimeVA)],
        @[@"file:", @(ZNARKindFileOffset)],
        @[@"fileoff:", @(ZNARKindFileOffset)],
        @[@"fileoffset:", @(ZNARKindFileOffset)],
    ];
    for (NSArray *entry in prefixes) {
        NSString *prefix = entry[0];
        if ([lower hasPrefix:prefix]) {
            if (explicitKind) *explicitKind = (ZNARKind)[entry[1] integerValue];
            return [trim substringFromIndex:prefix.length];
        }
    }
    if (explicitKind) *explicitKind = ZNARKindUnknown;
    return trim;
}

static NSDictionary *ZNARFindLoadedImage(NSString *target, NSString **error) {
    ZNModuleManager *manager = [ZNModuleManager sharedManager];
    NSString *wanted = [target stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!wanted.length) { if (error) *error = @"Target 不能为空"; return nil; }

    if ([wanted caseInsensitiveCompare:@"main"] == NSOrderedSame ||
        [wanted caseInsensitiveCompare:@"main executable"] == NSOrderedSame) {
        NSDictionary *main = manager.mainExecutable;
        if (!main && error) *error = @"主程序 Mach-O 未加载";
        return main;
    }

    NSArray<NSDictionary *> *images = manager.loadedImages;
    NSMutableArray<NSDictionary *> *basenameMatches = [NSMutableArray array];
    NSString *wantedBase = wanted.lastPathComponent;
    for (NSDictionary *item in images) {
        NSString *path = item[@"path"] ?: @"";
        NSString *name = item[@"name"] ?: path.lastPathComponent ?: @"";
        if (path.length && [path caseInsensitiveCompare:wanted] == NSOrderedSame) return item;
        if (name.length && [name caseInsensitiveCompare:wantedBase] == NSOrderedSame) [basenameMatches addObject:item];
        if (path.length && [path hasSuffix:wanted]) return item;
    }
    if (basenameMatches.count == 1) return basenameMatches.firstObject;
    if (basenameMatches.count > 1) {
        if (error) *error = [NSString stringWithFormat:@"Target 名称有歧义：%@ 匹配 %lu 个已加载 Mach-O；请填写完整路径", wantedBase, (unsigned long)basenameMatches.count];
        return nil;
    }

    // Preserve historical aliases such as UnityFramework.framework/UnityFramework.
    NSDictionary *legacy = [manager moduleNamed:wanted];
    if (legacy) return legacy;
    if (error) *error = [NSString stringWithFormat:@"目标模块未加载：%@", wanted];
    return nil;
}

static BOOL ZNARParseLayout(uintptr_t imageBase, ZNARLayout &layout, NSString **error) {
    if (!imageBase) { if (error) *error = @"目标 image base 无效"; return NO; }
    const struct mach_header_64 *mh = (const struct mach_header_64 *)imageBase;
    if (mh->magic != MH_MAGIC_64) { if (error) *error = @"目标不是当前支持的 thin 64-bit Mach-O image"; return NO; }
    if (mh->ncmds > 4096 || mh->sizeofcmds > 16 * 1024 * 1024) { if (error) *error = @"Mach-O load commands 异常"; return NO; }

    layout.imageVMBase = UINT64_MAX;
    layout.segments.clear();
    const uint8_t *cursor = (const uint8_t *)(mh + 1);
    const uint8_t *limit = cursor + mh->sizeofcmds;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > limit) { if (error) *error = @"Mach-O load commands 越界"; return NO; }
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command) || cursor + lc->cmdsize > limit) { if (error) *error = @"Mach-O load command size 损坏"; return NO; }
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
            ZNARSegment parsed = {};
            parsed.vmaddr = seg->vmaddr; parsed.vmsize = seg->vmsize;
            parsed.fileoff = seg->fileoff; parsed.filesize = seg->filesize;
            parsed.initprot = seg->initprot; parsed.maxprot = seg->maxprot;
            memcpy(parsed.name, seg->segname, 16); parsed.name[16] = 0;
            layout.segments.push_back(parsed);
            if (strncmp(seg->segname, SEG_TEXT, 16) == 0) layout.imageVMBase = seg->vmaddr;
        }
        cursor += lc->cmdsize;
    }
    if (layout.imageVMBase == UINT64_MAX) { if (error) *error = @"目标 Mach-O 未找到 __TEXT segment"; return NO; }
    return YES;
}

static const ZNARSegment *ZNARSegmentForPreferred(const ZNARLayout &layout, uint64_t va) {
    for (const ZNARSegment &seg : layout.segments) {
        if (!seg.vmsize) continue;
        if (va >= seg.vmaddr && va < seg.vmaddr + seg.vmsize) return &seg;
    }
    return NULL;
}

static const ZNARSegment *ZNARSegmentForRuntime(const ZNARLayout &layout, uintptr_t imageBase, uint64_t runtimeVA) {
    for (const ZNARSegment &seg : layout.segments) {
        if (!seg.vmsize || seg.vmaddr < layout.imageVMBase) continue;
        uint64_t start = (uint64_t)imageBase + (seg.vmaddr - layout.imageVMBase);
        if (runtimeVA >= start && runtimeVA < start + seg.vmsize) return &seg;
    }
    return NULL;
}

static BOOL ZNARFileOffsetToPreferred(const ZNARLayout &layout, uint64_t fileOffset, uint64_t *preferred, const ZNARSegment **segment) {
    for (const ZNARSegment &seg : layout.segments) {
        if (!seg.filesize) continue;
        if (fileOffset >= seg.fileoff && fileOffset < seg.fileoff + seg.filesize) {
            if (preferred) *preferred = seg.vmaddr + (fileOffset - seg.fileoff);
            if (segment) *segment = &seg;
            return YES;
        }
    }
    return NO;
}

static uint64_t ZNARPreferredToFileOffset(const ZNARSegment *seg, uint64_t preferred) {
    if (!seg || !seg->filesize || preferred < seg->vmaddr) return UINT64_MAX;
    uint64_t delta = preferred - seg->vmaddr;
    return delta < seg->filesize ? seg->fileoff + delta : UINT64_MAX;
}

static ZNARResolution *ZNARMakeResolution(NSString *raw,
                                         NSString *target,
                                         NSDictionary *image,
                                         const ZNARLayout &layout,
                                         ZNARKind kind,
                                         uint64_t input,
                                         uint64_t preferred,
                                         const ZNARSegment *seg) {
    if (!seg || preferred < layout.imageVMBase) return nil;
    uintptr_t imageBase = (uintptr_t)[image[@"base"] unsignedLongLongValue];
    uint64_t rva = preferred - layout.imageVMBase;
    uint64_t runtime = (uint64_t)imageBase + rva;
    ZNARResolution *r = [ZNARResolution new];
    r.originalInput = raw ?: @""; r.targetInput = target ?: @"";
    r.canonicalTarget = image[@"name"] ?: target.lastPathComponent ?: target ?: @"";
    r.imagePath = image[@"path"] ?: @"";
    r.segmentName = [NSString stringWithUTF8String:seg->name] ?: @"?";
    r.protectionText = [NSString stringWithFormat:@"%@ max=%@", ZNARProtection(seg->initprot), ZNARProtection(seg->maxprot)];
    r.kind = kind; r.inputValue = input; r.rva = rva; r.preferredVA = preferred; r.runtimeVA = runtime;
    r.fileOffset = ZNARPreferredToFileOffset(seg, preferred);
    r.imageVMBase = layout.imageVMBase; r.slide = [image[@"slide"] longLongValue];
    return r;
}

static ZNARResolution *ZNARResolve(NSString *target, NSString *rawInput, NSString **error) {
    ZNARKind explicitKind = ZNARKindUnknown;
    NSString *numeric = ZNARStripQualifier(rawInput ?: @"", &explicitKind);
    uint64_t input = 0;
    if (!ZNARParseInteger(numeric, &input)) { if (error) *error = [NSString stringWithFormat:@"Offset 格式无效：%@", rawInput ?: @""]; return nil; }

    NSString *findError = nil;
    NSDictionary *image = ZNARFindLoadedImage(target, &findError);
    if (!image) { if (error) *error = findError ?: @"目标 Mach-O 未加载"; return nil; }
    uintptr_t imageBase = (uintptr_t)[image[@"base"] unsignedLongLongValue];
    ZNARLayout layout = {};
    NSString *layoutError = nil;
    if (!ZNARParseLayout(imageBase, layout, &layoutError)) { if (error) *error = layoutError; return nil; }

    NSMutableArray<ZNARResolution *> *candidates = [NSMutableArray array];
    auto addCandidate = ^(ZNARKind kind, uint64_t preferred, const ZNARSegment *seg) {
        ZNARResolution *r = ZNARMakeResolution(rawInput, target, image, layout, kind, input, preferred, seg);
        if (r) [candidates addObject:r];
    };

    if (explicitKind == ZNARKindUnknown || explicitKind == ZNARKindRVA) {
        if (input <= UINT64_MAX - layout.imageVMBase) {
            uint64_t preferred = layout.imageVMBase + input;
            const ZNARSegment *seg = ZNARSegmentForPreferred(layout, preferred);
            if (seg) addCandidate(ZNARKindRVA, preferred, seg);
        }
    }
    if (explicitKind == ZNARKindUnknown || explicitKind == ZNARKindPreferredVA) {
        const ZNARSegment *seg = ZNARSegmentForPreferred(layout, input);
        if (seg) addCandidate(ZNARKindPreferredVA, input, seg);
    }
    if (explicitKind == ZNARKindUnknown || explicitKind == ZNARKindRuntimeVA) {
        const ZNARSegment *seg = ZNARSegmentForRuntime(layout, imageBase, input);
        if (seg && seg->vmaddr >= layout.imageVMBase) {
            uint64_t runtimeStart = (uint64_t)imageBase + (seg->vmaddr - layout.imageVMBase);
            uint64_t preferred = seg->vmaddr + (input - runtimeStart);
            addCandidate(ZNARKindRuntimeVA, preferred, seg);
        }
    }
    if (explicitKind == ZNARKindUnknown || explicitKind == ZNARKindFileOffset) {
        uint64_t preferred = 0; const ZNARSegment *seg = NULL;
        if (ZNARFileOffsetToPreferred(layout, input, &preferred, &seg)) addCandidate(ZNARKindFileOffset, preferred, seg);
    }

    if (!candidates.count) {
        if (error) *error = [NSString stringWithFormat:@"地址 0x%llX 无法映射到目标 Mach-O：%@。支持 RVA / Preferred VA / Runtime VA / File Offset",
                             (unsigned long long)input, image[@"name"] ?: target];
        return nil;
    }

    if (explicitKind != ZNARKindUnknown) return candidates.firstObject;

    // Collapse candidates that normalize to the exact same runtime address.
    NSMutableDictionary<NSNumber *, NSMutableArray<ZNARResolution *> *> *byRuntime = [NSMutableDictionary dictionary];
    for (ZNARResolution *r in candidates) {
        NSNumber *key = @(r.runtimeVA);
        if (!byRuntime[key]) byRuntime[key] = [NSMutableArray array];
        [byRuntime[key] addObject:r];
    }
    if (byRuntime.count > 1) {
        NSMutableArray<NSString *> *kinds = [NSMutableArray array];
        for (ZNARResolution *r in candidates) [kinds addObject:ZNARKindName(r.kind)];
        if (error) *error = [NSString stringWithFormat:@"地址语义有歧义（%@）。请显式使用 rva:/va:/runtime:/file: 前缀", [kinds componentsJoinedByString:@" / "]];
        return nil;
    }

    NSArray<ZNARResolution *> *same = byRuntime.allValues.firstObject;
    // Prefer a semantic label that preserves common authoring conventions.
    if (input >= layout.imageVMBase) {
        for (ZNARResolution *r in same) if (r.kind == ZNARKindPreferredVA) return r;
        for (ZNARResolution *r in same) if (r.kind == ZNARKindRuntimeVA) return r;
    }
    for (ZNARResolution *r in same) if (r.kind == ZNARKindRVA) return r;
    for (ZNARResolution *r in same) if (r.kind == ZNARKindFileOffset) return r;
    return same.firstObject;
}

static const void *kZNARRawInputKey = &kZNARRawInputKey;
static const void *kZNARPatchHexKey = &kZNARPatchHexKey;
static const void *kZNARResolutionKey = &kZNARResolutionKey;

static NSString *ZNARDiagnostic(ZNARResolution *r) {
    if (!r) return @"";
    NSString *file = (r.fileOffset == UINT64_MAX) ? @"—" : [NSString stringWithFormat:@"0x%llX", (unsigned long long)r.fileOffset];
    return [NSString stringWithFormat:@"Address Resolver: %@ · input=0x%llX · RVA=0x%llX · Preferred=0x%llX · Runtime=0x%llX · file=%@ · %@ %@",
            ZNARKindName(r.kind), (unsigned long long)r.inputValue, (unsigned long long)r.rva,
            (unsigned long long)r.preferredVA, (unsigned long long)r.runtimeVA, file,
            r.segmentName ?: @"?", r.protectionText ?: @""];
}

@interface ZNPatchRuntimeValidator (ZNAnyImageAddressResolver)
- (BOOL)znar_configureTarget:(NSString *)target offsetString:(NSString *)offsetString patchHex:(NSString *)patchHex error:(NSString **)error;
- (BOOL)znar_validate:(NSString **)error;
- (NSArray<NSString *> *)znar_diagnosticLines;
- (NSString *)znar_diagnosticReport;
- (void)znar_clearSession;
@end

@implementation ZNPatchRuntimeValidator (ZNAnyImageAddressResolver)

- (BOOL)znar_configureTarget:(NSString *)target offsetString:(NSString *)offsetString patchHex:(NSString *)patchHex error:(NSString **)error {
    ZNARKind ignored = ZNARKindUnknown;
    NSString *numeric = ZNARStripQualifier(offsetString ?: @"", &ignored);
    BOOL ok = [self znar_configureTarget:target offsetString:numeric patchHex:patchHex error:error];
    if (ok) {
        objc_setAssociatedObject(self, kZNARRawInputKey, [offsetString copy] ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(self, kZNARPatchHexKey, [patchHex copy] ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(self, kZNARResolutionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return ok;
}

- (BOOL)znar_validate:(NSString **)error {
    if (self.isApplied) return [self znar_validate:error];
    NSString *raw = objc_getAssociatedObject(self, kZNARRawInputKey);
    NSString *patchHex = objc_getAssociatedObject(self, kZNARPatchHexKey);
    if (!raw.length || !patchHex.length) return [self znar_validate:error];

    NSString *resolveError = nil;
    ZNARResolution *resolution = ZNARResolve(self.target, raw, &resolveError);
    if (!resolution) {
        if (error) *error = resolveError ?: @"地址解析失败";
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[address-resolver] target=%@ input=%@ FAIL: %@", self.target, raw, resolveError ?: @"unknown"]];
        return NO;
    }

    NSString *canonicalRVA = [NSString stringWithFormat:@"0x%llX", (unsigned long long)resolution.rva];
    NSString *reconfigureError = nil;
    if (![self znar_configureTarget:resolution.canonicalTarget offsetString:canonicalRVA patchHex:patchHex error:&reconfigureError]) {
        if (error) *error = reconfigureError ?: @"规范化 RVA 配置失败";
        return NO;
    }
    objc_setAssociatedObject(self, kZNARRawInputKey, raw, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, kZNARPatchHexKey, patchHex, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, kZNARResolutionKey, resolution, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSString *validateError = nil;
    BOOL ok = [self znar_validate:&validateError];
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[address-resolver] %@ · %@", ZNARDiagnostic(resolution), ok ? @"validate=PASS" : [NSString stringWithFormat:@"validate=FAIL %@", validateError ?: @"unknown"]]];
    if (!ok && error) *error = validateError;
    return ok;
}

- (NSArray<NSString *> *)znar_diagnosticLines {
    NSMutableArray<NSString *> *lines = [[self znar_diagnosticLines] mutableCopy] ?: [NSMutableArray array];
    NSString *raw = objc_getAssociatedObject(self, kZNARRawInputKey);
    ZNARResolution *resolution = objc_getAssociatedObject(self, kZNARResolutionKey);
    if (raw.length) [lines addObject:[NSString stringWithFormat:@"输入地址：%@", raw]];
    if (resolution) [lines addObject:ZNARDiagnostic(resolution)];
    return lines;
}

- (NSString *)znar_diagnosticReport {
    NSString *base = [self znar_diagnosticReport] ?: @"";
    ZNARResolution *resolution = objc_getAssociatedObject(self, kZNARResolutionKey);
    if (!resolution) return base;
    return [base stringByAppendingFormat:@"\n%@", ZNARDiagnostic(resolution)];
}

- (void)znar_clearSession {
    [self znar_clearSession];
    objc_setAssociatedObject(self, kZNARRawInputKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, kZNARPatchHexKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, kZNARResolutionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

static void ZNARSwap(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

extern "C" void ZNInstallAnyImageAddressResolverDeferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = ZNPatchRuntimeValidator.class;
        ZNARSwap(cls, @selector(configureTarget:offsetString:patchHex:error:), @selector(znar_configureTarget:offsetString:patchHex:error:));
        ZNARSwap(cls, @selector(validate:), @selector(znar_validate:));
        ZNARSwap(cls, @selector(diagnosticLines), @selector(znar_diagnosticLines));
        ZNARSwap(cls, @selector(diagnosticReport), @selector(znar_diagnosticReport));
        ZNARSwap(cls, @selector(clearSession), @selector(znar_clearSession));
        [[ZNRuntimeLogger sharedLogger] log:@"[address-resolver] installed: any loaded Mach-O · RVA / Preferred VA / Runtime VA / File Offset -> canonical RVA"];
    });
}
