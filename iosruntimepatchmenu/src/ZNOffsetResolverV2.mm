#import "ZNPatchRuntimeValidator.h"
#import "ZNPatchCore.h"
#import "ZNExecutablePageProbe.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <libkern/OSCacheControl.h>
#import <objc/runtime.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <vector>

typedef NS_ENUM(NSInteger, ZNOV2AddressKind) {
    ZNOV2AddressKindUnknown = 0,
    ZNOV2AddressKindUnslidVA,
    ZNOV2AddressKindRVA,
};

static NSString *ZNOV2KindName(ZNOV2AddressKind kind) {
    switch (kind) {
        case ZNOV2AddressKindUnslidVA: return @"Unslid VA";
        case ZNOV2AddressKindRVA: return @"RVA";
        default: return @"Unknown";
    }
}

struct ZNOV2Segment {
    uint64_t vmaddr;
    uint64_t vmsize;
    vm_prot_t initprot;
    vm_prot_t maxprot;
    char name[17];
};

struct ZNOV2Layout {
    uint64_t imageVMBase;
    std::vector<ZNOV2Segment> segments;
};

@interface ZNOV2Resolution : NSObject
@property(nonatomic,copy) NSString *inputText;
@property(nonatomic,copy) NSString *requestedTarget;
@property(nonatomic,copy) NSString *imageName;
@property(nonatomic,copy) NSString *imagePath;
@property(nonatomic,assign) uint32_t imageIndex;
@property(nonatomic,assign) uintptr_t imageHeader;
@property(nonatomic,assign) int64_t slide;
@property(nonatomic,assign) uint64_t imageVMBase;
@property(nonatomic,assign) uint64_t inputValue;
@property(nonatomic,assign) ZNOV2AddressKind kind;
@property(nonatomic,assign) uint64_t preferredVA;
@property(nonatomic,assign) uint64_t rva;
@property(nonatomic,assign) uint64_t runtimeVA;
@property(nonatomic,copy) NSString *segmentName;
@end
@implementation ZNOV2Resolution @end

@interface ZNPatchRuntimeValidator ()
@property(nonatomic,copy,readwrite) NSString *target;
@property(nonatomic,assign,readwrite) uint64_t rva;
@property(nonatomic,copy,readwrite) NSData *patchBytes;
@property(nonatomic,copy,readwrite) NSData *capturedOriginalBytes;
@property(nonatomic,copy,readwrite) NSData *currentBytes;
@property(nonatomic,assign,readwrite) uintptr_t runtimeAddress;
@property(nonatomic,assign,readwrite,getter=isConfigured) BOOL configured;
@property(nonatomic,assign,readwrite,getter=isValidated) BOOL validated;
@property(nonatomic,assign,readwrite,getter=isApplied) BOOL applied;
@property(nonatomic,copy,readwrite) NSString *lastResult;
@property(nonatomic,copy) NSString *protectionDescription;
@property(nonatomic,copy) NSString *segmentDescription;
@end

static const void *kZNOV2ResolutionKey = &kZNOV2ResolutionKey;
static const void *kZNOV2InputKey = &kZNOV2InputKey;
static const void *kZNOV2RequestedTargetKey = &kZNOV2RequestedTargetKey;

static NSString *ZNOV2Protection(vm_prot_t p) {
    return [NSString stringWithFormat:@"%@%@%@",
            (p & VM_PROT_READ) ? @"R" : @"-",
            (p & VM_PROT_WRITE) ? @"W" : @"-",
            (p & VM_PROT_EXECUTE) ? @"X" : @"-"];
}

static NSString *ZNOV2Hex(NSData *data) {
    if (!data.length) return @"";
    const uint8_t *p = (const uint8_t *)data.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [s appendFormat:@"%02X", p[i]];
    return s;
}

static BOOL ZNOV2ParseInteger(NSString *input, uint64_t *outValue, NSString **error) {
    NSString *s = [[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!s.length) { if (error) *error = @"Offset 不能为空"; return NO; }
    const char *c = s.UTF8String;
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(c, &end, 0);
    if (errno || end == c || (end && *end)) {
        errno = 0; end = NULL;
        value = strtoull(c, &end, 16);
    }
    if (errno || end == c || (end && *end)) {
        if (error) *error = [NSString stringWithFormat:@"Offset 格式无效：%@", input ?: @""];
        return NO;
    }
    if (outValue) *outValue = (uint64_t)value;
    return YES;
}

static NSData *ZNOV2DataFromHex(NSString *input, NSString **error) {
    if (!input.length) { if (error) *error = @"Patch 不能为空"; return nil; }
    NSMutableString *clean = [NSMutableString string];
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        if ([ws characterIsMember:c] || c == ':' || c == '-') continue;
        [clean appendFormat:@"%C", c];
    }
    if ([clean hasPrefix:@"0x"] || [clean hasPrefix:@"0X"]) [clean deleteCharactersInRange:NSMakeRange(0, 2)];
    if (!clean.length || (clean.length & 1U)) { if (error) *error = @"Patch HEX 长度必须为偶数"; return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:clean.length / 2];
    uint8_t *out = (uint8_t *)data.mutableBytes;
    for (NSUInteger i = 0; i < clean.length; i += 2) {
        NSString *pair = [clean substringWithRange:NSMakeRange(i, 2)];
        unsigned value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        if (![scanner scanHexInt:&value] || !scanner.isAtEnd) {
            if (error) *error = [NSString stringWithFormat:@"Patch HEX 非法：%@", pair];
            return nil;
        }
        out[i / 2] = (uint8_t)value;
    }
    return data;
}

static BOOL ZNOV2ParseLayout(uintptr_t header, ZNOV2Layout &layout, NSString **error) {
    if (!header) { if (error) *error = @"目标 image header 无效"; return NO; }
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
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
            ZNOV2Segment p = {};
            p.vmaddr = seg->vmaddr;
            p.vmsize = seg->vmsize;
            p.initprot = seg->initprot;
            p.maxprot = seg->maxprot;
            memcpy(p.name, seg->segname, 16); p.name[16] = 0;
            layout.segments.push_back(p);
            if (strncmp(seg->segname, SEG_TEXT, 16) == 0) layout.imageVMBase = seg->vmaddr;
        }
        cursor += lc->cmdsize;
    }
    if (layout.imageVMBase == UINT64_MAX) { if (error) *error = @"目标 Mach-O 未找到 __TEXT segment"; return NO; }
    return YES;
}

static const ZNOV2Segment *ZNOV2SegmentForRange(const ZNOV2Layout &layout, uint64_t preferred, uint64_t length) {
    if (!length || preferred > UINT64_MAX - length) return NULL;
    uint64_t end = preferred + length;
    for (const ZNOV2Segment &seg : layout.segments) {
        if (!seg.vmsize || seg.vmaddr < layout.imageVMBase || seg.vmaddr > UINT64_MAX - seg.vmsize) continue;
        if (preferred >= seg.vmaddr && end <= seg.vmaddr + seg.vmsize) return &seg;
    }
    return NULL;
}

static BOOL ZNOV2AddSlide(uint64_t preferred, int64_t slide, uint64_t *runtime) {
    __int128 value = (__int128)preferred + (__int128)slide;
    if (value < 0 || value > (__int128)UINT64_MAX) return NO;
    if (runtime) *runtime = (uint64_t)value;
    return YES;
}

static NSDictionary *ZNOV2FindImage(NSString *target, NSString **error) {
    ZNModuleManager *manager = [ZNModuleManager sharedManager];
    NSString *wanted = [target stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!wanted.length) { if (error) *error = @"Target 不能为空"; return nil; }
    if ([wanted caseInsensitiveCompare:@"main"] == NSOrderedSame || [wanted caseInsensitiveCompare:@"main executable"] == NSOrderedSame) {
        NSDictionary *main = manager.mainExecutable;
        if (!main && error) *error = @"主程序 Mach-O 未加载";
        return main;
    }
    NSArray<NSDictionary *> *images = manager.loadedImages;
    for (NSDictionary *item in images) {
        NSString *path = item[@"path"] ?: @"";
        if (path.length && [path caseInsensitiveCompare:wanted] == NSOrderedSame) return item;
    }
    NSMutableDictionary<NSNumber *, NSDictionary *> *matches = [NSMutableDictionary dictionary];
    NSString *wantedBase = wanted.lastPathComponent;
    BOOL pathLike = [wanted containsString:@"/"];
    for (NSDictionary *item in images) {
        NSString *path = item[@"path"] ?: @"";
        NSString *name = item[@"name"] ?: path.lastPathComponent ?: @"";
        BOOL match = pathLike ? (path.length && [path hasSuffix:wanted]) : (name.length && [name caseInsensitiveCompare:wantedBase] == NSOrderedSame);
        if (match) matches[item[@"index"] ?: @(-1)] = item;
    }
    if (matches.count == 1) return matches.allValues.firstObject;
    if (matches.count > 1) {
        if (error) *error = [NSString stringWithFormat:@"Target 名称有歧义：%@ 匹配 %lu 个已加载 Mach-O；请使用完整路径", wantedBase, (unsigned long)matches.count];
        return nil;
    }
    if (error) *error = [NSString stringWithFormat:@"目标模块未加载：%@", wanted];
    return nil;
}

static ZNOV2Resolution *ZNOV2Resolve(NSString *target, NSString *inputText, NSUInteger patchLength, NSString **error) {
    uint64_t input = 0;
    if (!ZNOV2ParseInteger(inputText, &input, error)) return nil;
    NSDictionary *image = ZNOV2FindImage(target, error);
    if (!image) return nil;
    uint32_t index = [image[@"index"] unsignedIntValue];
    uintptr_t header = (uintptr_t)[image[@"base"] unsignedLongLongValue];
    int64_t slide = [image[@"slide"] longLongValue];
    NSString *path = image[@"path"] ?: @"";
    NSString *name = image[@"name"] ?: path.lastPathComponent ?: target.lastPathComponent ?: target;
    ZNOV2Layout layout = {};
    if (!ZNOV2ParseLayout(header, layout, error)) return nil;
    uint64_t expectedHeader = 0;
    if (!ZNOV2AddSlide(layout.imageVMBase, slide, &expectedHeader) || expectedHeader != (uint64_t)header) {
        if (error) *error = [NSString stringWithFormat:@"dyld image identity 不一致：header=0x%llX __TEXT+slide=0x%llX", (unsigned long long)header, (unsigned long long)expectedHeader];
        return nil;
    }

    const ZNOV2Segment *seg = ZNOV2SegmentForRange(layout, input, (uint64_t)patchLength);
    uint64_t preferred = 0;
    ZNOV2AddressKind kind = ZNOV2AddressKindUnknown;
    if (seg) {
        preferred = input;
        kind = ZNOV2AddressKindUnslidVA;
    } else if (input <= UINT64_MAX - layout.imageVMBase) {
        uint64_t candidate = layout.imageVMBase + input;
        seg = ZNOV2SegmentForRange(layout, candidate, (uint64_t)patchLength);
        if (seg) { preferred = candidate; kind = ZNOV2AddressKindRVA; }
    }
    if (!seg || kind == ZNOV2AddressKindUnknown) {
        if (error) *error = [NSString stringWithFormat:@"地址 0x%llX 不属于目标 Mach-O 的 Unslid VA 或 RVA 范围：%@", (unsigned long long)input, name ?: target];
        return nil;
    }
    if (preferred < layout.imageVMBase) { if (error) *error = @"解析后的地址位于 __TEXT.vmaddr 之前"; return nil; }
    uint64_t runtime = 0;
    if (!ZNOV2AddSlide(preferred, slide, &runtime)) { if (error) *error = @"Preferred VA + dyld slide 溢出"; return nil; }

    ZNOV2Resolution *r = [ZNOV2Resolution new];
    r.inputText = inputText ?: @"";
    r.requestedTarget = target ?: @"";
    r.imageName = name ?: @"";
    r.imagePath = path ?: @"";
    r.imageIndex = index;
    r.imageHeader = header;
    r.slide = slide;
    r.imageVMBase = layout.imageVMBase;
    r.inputValue = input;
    r.kind = kind;
    r.preferredVA = preferred;
    r.rva = preferred - layout.imageVMBase;
    r.runtimeVA = runtime;
    r.segmentName = [NSString stringWithUTF8String:seg->name] ?: @"?";
    return r;
}

static BOOL ZNOV2VerifyIdentity(ZNOV2Resolution *r, NSUInteger length, NSString **error) {
    if (!r || !r.imagePath.length) { if (error) *error = @"没有已解析的目标 image identity"; return NO; }
    NSDictionary *current = nil;
    for (NSDictionary *item in [ZNModuleManager sharedManager].loadedImages) {
        if ([item[@"index"] unsignedIntValue] != r.imageIndex) continue;
        if ([(item[@"path"] ?: @"") isEqualToString:r.imagePath]) current = item;
        break;
    }
    if (!current) { if (error) *error = @"目标 dyld image identity 已变化；请重新读取验证"; return NO; }
    uintptr_t header = (uintptr_t)[current[@"base"] unsignedLongLongValue];
    int64_t slide = [current[@"slide"] longLongValue];
    if (header != r.imageHeader || slide != r.slide) { if (error) *error = @"目标 Mach-O header/slide 已变化；请重新读取验证"; return NO; }
    ZNOV2Layout layout = {};
    if (!ZNOV2ParseLayout(header, layout, error)) return NO;
    if (!ZNOV2SegmentForRange(layout, r.preferredVA, (uint64_t)length)) { if (error) *error = @"规范化地址已不在目标 Mach-O segment 范围内"; return NO; }
    uint64_t runtime = 0;
    if (!ZNOV2AddSlide(r.preferredVA, slide, &runtime) || runtime != r.runtimeVA) { if (error) *error = @"Runtime Address 与已验证结果不一致"; return NO; }
    return YES;
}

typedef struct {
    mach_vm_address_t start;
    mach_vm_size_t size;
    vm_prot_t protection;
    vm_prot_t maxProtection;
} ZNOV2VMRegion;

static BOOL ZNOV2QueryRegion(uint64_t address, NSUInteger length, ZNOV2VMRegion *outRegion, NSString **error) {
    if (!address || !length || address > UINT64_MAX - (uint64_t)length) { if (error) *error = @"Runtime 地址或 Patch 长度无效"; return NO; }
    mach_vm_address_t regionAddress = (mach_vm_address_t)address;
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info = {};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;
    kern_return_t kr = mach_vm_region(mach_task_self(), &regionAddress, &regionSize, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &objectName);
    if (objectName != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), objectName);
    if (kr != KERN_SUCCESS) { if (error) *error = [NSString stringWithFormat:@"mach_vm_region 失败：%d", kr]; return NO; }
    uint64_t wantedEnd = address + (uint64_t)length;
    uint64_t regionEnd = (uint64_t)regionAddress + (uint64_t)regionSize;
    if (regionAddress > address || regionEnd < regionAddress || wantedEnd > regionEnd) { if (error) *error = @"Patch 跨越多个 VM region；请拆分 Patch"; return NO; }
    if (outRegion) {
        outRegion->start = regionAddress;
        outRegion->size = regionSize;
        outRegion->protection = info.protection;
        outRegion->maxProtection = info.max_protection;
    }
    return YES;
}

static BOOL ZNOV2Read(uint64_t address, NSUInteger length, NSData **outData, NSString **error) {
    if (!address || !length) { if (error) *error = @"读取地址或长度无效"; return NO; }
    NSMutableData *data = [NSMutableData dataWithLength:length];
    mach_vm_size_t readSize = 0;
    kern_return_t kr = mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)address, (mach_vm_size_t)length, (mach_vm_address_t)(uintptr_t)data.mutableBytes, &readSize);
    if (kr != KERN_SUCCESS || readSize != (mach_vm_size_t)length) {
        if (error) *error = [NSString stringWithFormat:@"mach_vm_read_overwrite 失败：kr=%d read=%llu/%llu", kr, (unsigned long long)readSize, (unsigned long long)length];
        return NO;
    }
    if (outData) *outData = data;
    return YES;
}

static BOOL ZNOV2Protect(uint64_t address, NSUInteger length, vm_prot_t protection, NSString **error) {
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)address, (vm_size_t)length, FALSE, protection);
    if (kr != KERN_SUCCESS) { if (error) *error = [NSString stringWithFormat:@"vm_protect(%@) 失败：%d", ZNOV2Protection(protection), kr]; return NO; }
    return YES;
}

static BOOL ZNOV2Write(uint64_t address, NSData *target, NSData *rollback, NSString **error) {
    if (!target.length || target.length > UINT32_MAX) { if (error) *error = @"Patch 长度超出 Mach vm_write 支持范围"; return NO; }
    ZNOV2VMRegion region = {};
    NSString *e = nil;
    if (!ZNOV2QueryRegion(address, target.length, &region, &e)) { if (error) *error = e; return NO; }
    BOOL writable = (region.protection & VM_PROT_WRITE) != 0;
    BOOL executable = (region.protection & VM_PROT_EXECUTE) != 0;
    BOOL changed = NO;
    if (!writable) {
        vm_prot_t temp = VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY;
        if (!ZNOV2Protect(address, target.length, temp, &e)) { if (error) *error = e; return NO; }
        changed = YES;
    }
    kern_return_t writeKR = vm_write(mach_task_self(), (vm_address_t)address, (vm_offset_t)(uintptr_t)target.bytes, (mach_msg_type_number_t)target.length);
    if (writeKR == KERN_SUCCESS && executable) sys_icache_invalidate((void *)(uintptr_t)address, target.length);
    NSData *written = nil;
    BOOL readOK = (writeKR == KERN_SUCCESS) && ZNOV2Read(address, target.length, &written, &e) && [written isEqualToData:target];
    BOOL rollbackAttempted = NO;
    BOOL rollbackConfirmed = NO;
    if (!readOK && rollback.length == target.length) {
        rollbackAttempted = YES;
        kern_return_t rollbackKR = vm_write(mach_task_self(), (vm_address_t)address, (vm_offset_t)(uintptr_t)rollback.bytes, (mach_msg_type_number_t)rollback.length);
        if (rollbackKR == KERN_SUCCESS && executable) sys_icache_invalidate((void *)(uintptr_t)address, rollback.length);
        NSData *rolledBack = nil;
        rollbackConfirmed = rollbackKR == KERN_SUCCESS &&
            ZNOV2Read(address, rollback.length, &rolledBack, NULL) &&
            [rolledBack isEqualToData:rollback];
    }
    NSString *restoreError = nil;
    BOOL restoreOK = !changed || ZNOV2Protect(address, target.length, region.protection, &restoreError);
    if (!readOK) {
        NSString *rollbackState = rollbackAttempted ? (rollbackConfirmed ? @"；回滚 read-back 已确认" : @"；回滚未确认") : @"；无可用回滚数据";
        NSString *base = writeKR != KERN_SUCCESS ? [NSString stringWithFormat:@"vm_write 失败：%d", writeKR] : (e ?: @"写入 read-back 不一致");
        if (error) *error = [base stringByAppendingString:rollbackState];
        return NO;
    }
    if (!restoreOK) {
        BOOL protectRollbackConfirmed = NO;
        if (rollback.length == target.length) {
            kern_return_t rollbackKR = vm_write(mach_task_self(), (vm_address_t)address, (vm_offset_t)(uintptr_t)rollback.bytes, (mach_msg_type_number_t)rollback.length);
            if (rollbackKR == KERN_SUCCESS && executable) sys_icache_invalidate((void *)(uintptr_t)address, rollback.length);
            NSData *rolledBack = nil;
            protectRollbackConfirmed = rollbackKR == KERN_SUCCESS &&
                ZNOV2Read(address, rollback.length, &rolledBack, NULL) &&
                [rolledBack isEqualToData:rollback];
        }
        ZNOV2Protect(address, target.length, region.protection, NULL);
        if (error) *error = [NSString stringWithFormat:@"%@；回滚%@确认", restoreError ?: @"写入后恢复原保护失败", protectRollbackConfirmed ? @"已" : @"未"];
        return NO;
    }
    NSData *final = nil;
    if (!ZNOV2Read(address, target.length, &final, &e) || ![final isEqualToData:target]) { if (error) *error = e ?: @"最终 read-back 不一致"; return NO; }
    return YES;
}

static NSString *ZNOV2ResolutionLine(ZNOV2Resolution *r) {
    if (!r) return @"";
    return [NSString stringWithFormat:@"Offset Resolver V2: %@ · input=%@ · RVA=0x%llX · Preferred=0x%llX · Runtime=0x%llX · image[%u]=%@ · segment=%@",
            ZNOV2KindName(r.kind), r.inputText ?: @"", (unsigned long long)r.rva, (unsigned long long)r.preferredVA,
            (unsigned long long)r.runtimeVA, r.imageIndex, r.imageName ?: @"?", r.segmentName ?: @"?"];
}

@interface ZNPatchRuntimeValidator (ZNOffsetResolverV2)
- (BOOL)znov2_configureTarget:(NSString *)target offsetString:(NSString *)offsetString patchHex:(NSString *)patchHex error:(NSString **)error;
- (BOOL)znov2_validate:(NSString **)error;
- (BOOL)znov2_applyTemporary:(NSString **)error;
- (BOOL)znov2_restoreOriginal:(NSString **)error;
- (void)znov2_clearSession;
- (NSArray<NSString *> *)znov2_diagnosticLines;
- (NSString *)znov2_diagnosticReport;
@end

@implementation ZNPatchRuntimeValidator (ZNOffsetResolverV2)

- (BOOL)znov2_configureTarget:(NSString *)target offsetString:(NSString *)offsetString patchHex:(NSString *)patchHex error:(NSString **)error {
    @synchronized (self) {
        if (self.applied) { if (error) *error = @"当前临时 Patch 尚未恢复，请先恢复原始字节"; return NO; }
        NSString *requested = [target stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!requested.length) { if (error) *error = @"Target 不能为空"; return NO; }
        uint64_t parsed = 0;
        NSString *e = nil;
        if (!ZNOV2ParseInteger(offsetString, &parsed, &e)) { if (error) *error = e; return NO; }
        NSData *patch = ZNOV2DataFromHex(patchHex, &e);
        if (!patch.length) { if (error) *error = e ?: @"Patch HEX 无效"; return NO; }
        self.target = requested;
        self.rva = parsed;
        self.patchBytes = patch;
        self.capturedOriginalBytes = nil;
        self.currentBytes = nil;
        self.runtimeAddress = 0;
        self.configured = YES;
        self.validated = NO;
        self.applied = NO;
        self.protectionDescription = @"未知";
        self.segmentDescription = @"未知";
        self.lastResult = @"已配置，等待读取验证";
        objc_setAssociatedObject(self, kZNOV2ResolutionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kZNOV2InputKey, [offsetString copy] ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(self, kZNOV2RequestedTargetKey, [requested copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[offset-v2] configured target=%@ input=%@ patchBytes=%lu", requested, offsetString ?: @"", (unsigned long)patch.length]];
        return YES;
    }
}

- (BOOL)znov2_validate:(NSString **)error {
    @synchronized (self) {
        if (!self.configured || !self.patchBytes.length) { if (error) *error = @"请先配置 target / offset / patch"; return NO; }
        NSString *requested = objc_getAssociatedObject(self, kZNOV2RequestedTargetKey) ?: self.target;
        NSString *input = objc_getAssociatedObject(self, kZNOV2InputKey) ?: @"";
        NSString *e = nil;
        ZNOV2Resolution *r = ZNOV2Resolve(requested, input, self.patchBytes.length, &e);
        if (!r || !ZNOV2VerifyIdentity(r, self.patchBytes.length, &e)) {
            self.validated = NO;
            self.lastResult = e ?: @"地址解析失败";
            if (error) *error = self.lastResult;
            return NO;
        }
        ZNOV2VMRegion region = {};
        if (!ZNOV2QueryRegion(r.runtimeVA, self.patchBytes.length, &region, &e)) {
            self.validated = NO; self.lastResult = e ?: @"VM region 查询失败"; if (error) *error = self.lastResult; return NO;
        }
        if ((region.protection & VM_PROT_EXECUTE) && ((r.runtimeVA & 3u) != 0 || (self.patchBytes.length & 3u) != 0)) {
            self.validated = NO;
            self.lastResult = @"ARM64 可执行页 Patch 要求地址与长度均为 4-byte 对齐";
            if (error) *error = self.lastResult;
            return NO;
        }
        NSData *now = nil;
        if (!ZNOV2Read(r.runtimeVA, self.patchBytes.length, &now, &e)) {
            self.validated = NO; self.lastResult = e ?: @"读取失败"; if (error) *error = self.lastResult; return NO;
        }
        self.target = r.imagePath.length ? r.imagePath : r.imageName;
        self.rva = r.rva;
        self.runtimeAddress = (uintptr_t)r.runtimeVA;
        self.segmentDescription = r.segmentName ?: @"?";
        self.protectionDescription = [NSString stringWithFormat:@"%@ max=%@", ZNOV2Protection(region.protection), ZNOV2Protection(region.maxProtection)];
        self.currentBytes = now;
        if ([now isEqualToData:self.patchBytes]) {
            if (!self.capturedOriginalBytes.length) {
                self.validated = NO; self.lastResult = @"当前位置已经等于 Patch，无法现场推断 Original；请用原版进程重新验证"; if (error) *error = self.lastResult; return NO;
            }
            self.applied = YES;
        } else if (!self.capturedOriginalBytes.length) {
            self.capturedOriginalBytes = now; self.applied = NO;
        } else if ([now isEqualToData:self.capturedOriginalBytes]) {
            self.applied = NO;
        } else {
            self.validated = NO;
            self.lastResult = [NSString stringWithFormat:@"现场字节与本会话 Original/Patch 均不一致。Original=%@ Current=%@ Patch=%@", ZNOV2Hex(self.capturedOriginalBytes), ZNOV2Hex(now), ZNOV2Hex(self.patchBytes)];
            if (error) *error = self.lastResult;
            return NO;
        }
        objc_setAssociatedObject(self, kZNOV2ResolutionKey, r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.validated = YES;
        self.lastResult = [NSString stringWithFormat:@"Binary/Runtime 预检 PASS：%@ · %@ · RVA=0x%llX · %@ · Original=%@", r.imageName ?: requested, ZNOV2KindName(r.kind), (unsigned long long)r.rva, self.segmentDescription, ZNOV2Hex(self.capturedOriginalBytes)];
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[offset-v2] %@ · vm=%@", ZNOV2ResolutionLine(r), self.protectionDescription]];
        return YES;
    }
}

- (BOOL)znov2_applyTemporary:(NSString **)error {
    @synchronized (self) {
        NSString *e = nil;
        if (!self.validated && ![self validate:&e]) { if (error) *error = e; return NO; }
        ZNOV2Resolution *r = objc_getAssociatedObject(self, kZNOV2ResolutionKey);
        if (!r || !self.capturedOriginalBytes.length || self.capturedOriginalBytes.length != self.patchBytes.length) { self.lastResult = @"没有可用的已验证 Resolution/Original"; if (error) *error = self.lastResult; return NO; }
        if (!ZNOV2VerifyIdentity(r, self.patchBytes.length, &e)) { self.validated = NO; self.lastResult = e ?: @"目标 image identity 已变化"; if (error) *error = self.lastResult; return NO; }
        NSData *now = nil;
        if (!ZNOV2Read(r.runtimeVA, self.patchBytes.length, &now, &e)) { self.lastResult = e ?: @"读取失败"; if (error) *error = self.lastResult; return NO; }
        self.currentBytes = now;
        if ([now isEqualToData:self.patchBytes]) { self.applied = YES; self.lastResult = @"Patch 已经处于临时应用状态"; return YES; }
        if (![now isEqualToData:self.capturedOriginalBytes]) { self.lastResult = [NSString stringWithFormat:@"当前字节已变化，拒绝覆盖。Original=%@ Current=%@", ZNOV2Hex(self.capturedOriginalBytes), ZNOV2Hex(now)]; if (error) *error = self.lastResult; return NO; }
        ZNOV2VMRegion region = {};
        if (!ZNOV2QueryRegion(r.runtimeVA, self.patchBytes.length, &region, &e)) { self.lastResult = e ?: @"VM region 查询失败"; if (error) *error = self.lastResult; return NO; }
        if (region.protection & VM_PROT_EXECUTE) {
            ZNExecutablePageProbe *probe = [ZNExecutablePageProbe sharedProbe];
            BOOL capable = probe.hasRun ? probe.supported : [probe runProbe];
            if (!capable) { self.lastResult = [NSString stringWithFormat:@"Executable Page Probe 未通过：%@", probe.lastResult ?: @"unsupported"]; if (error) *error = self.lastResult; return NO; }
        }
        if (!ZNOV2Write(r.runtimeVA, self.patchBytes, self.capturedOriginalBytes, &e)) { self.applied = NO; self.lastResult = [NSString stringWithFormat:@"Runtime Patch FAIL：%@", e ?: @"写入失败"]; if (error) *error = self.lastResult; return NO; }
        NSData *fresh = nil; ZNOV2Read(r.runtimeVA, self.patchBytes.length, &fresh, NULL); self.currentBytes = fresh;
        self.applied = YES;
        self.lastResult = [NSString stringWithFormat:@"Runtime Patch PASS：%@ · write/read-back/protection restore%@", ZNOV2KindName(r.kind), (region.protection & VM_PROT_EXECUTE) ? @"/icache" : @""];
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[offset-v2] %@", self.lastResult]];
        return YES;
    }
}

- (BOOL)znov2_restoreOriginal:(NSString **)error {
    @synchronized (self) {
        ZNOV2Resolution *r = objc_getAssociatedObject(self, kZNOV2ResolutionKey);
        if (!self.configured || !r || !self.capturedOriginalBytes.length) { if (error) *error = @"当前会话没有可恢复的现场 Original"; return NO; }
        NSString *e = nil;
        if (!ZNOV2VerifyIdentity(r, self.patchBytes.length, &e)) { self.lastResult = e ?: @"目标 image identity 已变化"; if (error) *error = self.lastResult; return NO; }
        NSData *now = nil;
        if (!ZNOV2Read(r.runtimeVA, self.patchBytes.length, &now, &e)) { self.lastResult = e ?: @"读取失败"; if (error) *error = self.lastResult; return NO; }
        self.currentBytes = now;
        if ([now isEqualToData:self.capturedOriginalBytes]) { self.applied = NO; self.validated = YES; self.lastResult = @"当前已经是现场 Original，无需恢复"; return YES; }
        if (![now isEqualToData:self.patchBytes]) { self.lastResult = @"当前位置不是本会话 Patch，检测到第三方变化，拒绝恢复"; if (error) *error = self.lastResult; return NO; }
        if (!ZNOV2Write(r.runtimeVA, self.capturedOriginalBytes, self.patchBytes, &e)) { self.lastResult = [NSString stringWithFormat:@"恢复 FAIL：%@", e ?: @"写入失败"]; if (error) *error = self.lastResult; return NO; }
        NSData *fresh = nil; ZNOV2Read(r.runtimeVA, self.patchBytes.length, &fresh, NULL); self.currentBytes = fresh;
        self.applied = NO; self.validated = YES; self.lastResult = @"恢复 PASS：现场 Original 已写回并验证";
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[offset-v2] %@", self.lastResult]];
        return YES;
    }
}

- (void)znov2_clearSession {
    @synchronized (self) {
        if (self.applied) return;
        self.target = @""; self.rva = 0; self.patchBytes = nil; self.capturedOriginalBytes = nil; self.currentBytes = nil; self.runtimeAddress = 0;
        self.configured = NO; self.validated = NO; self.applied = NO; self.protectionDescription = @"未知"; self.segmentDescription = @"未知"; self.lastResult = @"已清空";
        objc_setAssociatedObject(self, kZNOV2ResolutionKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, kZNOV2InputKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(self, kZNOV2RequestedTargetKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

- (NSArray<NSString *> *)znov2_diagnosticLines {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"Target: %@", self.target.length ? self.target : @"—"]];
    NSString *input = objc_getAssociatedObject(self, kZNOV2InputKey);
    if (input.length) [lines addObject:[NSString stringWithFormat:@"输入 Offset: %@", input]];
    ZNOV2Resolution *r = objc_getAssociatedObject(self, kZNOV2ResolutionKey);
    if (r) { [lines addObject:ZNOV2ResolutionLine(r)]; [lines addObject:[NSString stringWithFormat:@"Image path: %@", r.imagePath ?: @""]]; }
    [lines addObject:[NSString stringWithFormat:@"Protection: %@", self.protectionDescription ?: @"未知"]];
    [lines addObject:[NSString stringWithFormat:@"Patch: %@", ZNOV2Hex(self.patchBytes)]];
    [lines addObject:[NSString stringWithFormat:@"Original: %@", ZNOV2Hex(self.capturedOriginalBytes)]];
    [lines addObject:[NSString stringWithFormat:@"Current: %@", ZNOV2Hex(self.currentBytes)]];
    [lines addObject:[NSString stringWithFormat:@"Result: %@", self.lastResult ?: @""]];
    return lines;
}

- (NSString *)znov2_diagnosticReport {
    return [[self diagnosticLines] componentsJoinedByString:@"\n"];
}

@end

static void ZNOV2Swap(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

extern "C" void ZNInstallOffsetResolverV2Deferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = ZNPatchRuntimeValidator.class;
        ZNOV2Swap(cls, @selector(configureTarget:offsetString:patchHex:error:), @selector(znov2_configureTarget:offsetString:patchHex:error:));
        ZNOV2Swap(cls, @selector(validate:), @selector(znov2_validate:));
        ZNOV2Swap(cls, @selector(applyTemporary:), @selector(znov2_applyTemporary:));
        ZNOV2Swap(cls, @selector(restoreOriginal:), @selector(znov2_restoreOriginal:));
        ZNOV2Swap(cls, @selector(clearSession), @selector(znov2_clearSession));
        ZNOV2Swap(cls, @selector(diagnosticLines), @selector(znov2_diagnosticLines));
        ZNOV2Swap(cls, @selector(diagnosticReport), @selector(znov2_diagnosticReport));
        [[ZNRuntimeLogger sharedLogger] log:@"[offset-v2] installed: exact dyld image identity · Unslid VA first · RVA fallback · no runtime/file ambiguity"];
    });
}
