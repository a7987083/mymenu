#import "ZNPatchRuntimeValidator.h"
#import "ZNPatchCore.h"
#import "ZNExecutablePageProbe.h"
#import <mach-o/loader.h>
#import <libkern/OSCacheControl.h>
#import <sys/mman.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>

static NSString *ZN43Hex(NSData *data) {
    if (!data.length) return @"";
    const uint8_t *p = (const uint8_t *)data.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) [s appendFormat:@"%02X", p[i]];
    return s;
}

static NSData *ZN43DataFromHex(NSString *input, NSString **error) {
    if (!input.length) { if (error) *error = @"Patch 不能为空"; return nil; }
    NSMutableString *clean = [NSMutableString string];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        if ([ws characterIsMember:c] || c == ':' || c == '-') continue;
        [clean appendFormat:@"%C", c];
    }
    if ([clean hasPrefix:@"0x"] || [clean hasPrefix:@"0X"]) [clean deleteCharactersInRange:NSMakeRange(0, 2)];
    if (!clean.length || (clean.length & 1)) { if (error) *error = @"Patch HEX 长度必须为偶数"; return nil; }
    if (clean.length / 2 > 256) { if (error) *error = @"首版运行时验证限制 Patch <= 256 bytes"; return nil; }

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

static BOOL ZN43ParseRVA(NSString *input, uint64_t *outRVA, NSString **error) {
    NSString *s = [[input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (!s.length) { if (error) *error = @"Offset 不能为空"; return NO; }

    const char *c = s.UTF8String;
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(c, &end, 0);
    if (errno != 0 || end == c || (end && *end != '\0')) {
        errno = 0;
        end = NULL;
        value = strtoull(c, &end, 16);
    }
    if (errno != 0 || end == c || (end && *end != '\0')) {
        if (error) *error = [NSString stringWithFormat:@"Offset 格式无效：%@", input];
        return NO;
    }
    if (outRVA) *outRVA = (uint64_t)value;
    return YES;
}

static NSString *ZN43ProtectionString(vm_prot_t p) {
    return [NSString stringWithFormat:@"%@%@%@",
            (p & VM_PROT_READ) ? @"R" : @"-",
            (p & VM_PROT_WRITE) ? @"W" : @"-",
            (p & VM_PROT_EXECUTE) ? @"X" : @"-"];
}

static int ZN43POSIXProtection(vm_prot_t p) {
    int result = PROT_NONE;
    if (p & VM_PROT_READ) result |= PROT_READ;
    if (p & VM_PROT_WRITE) result |= PROT_WRITE;
    if (p & VM_PROT_EXECUTE) result |= PROT_EXEC;
    return result;
}

typedef struct {
    uintptr_t start;
    uintptr_t end;
    vm_prot_t protection;
    vm_prot_t maxProtection;
    char segmentName[17];
} ZN43SegmentInfo;

// iOS public SDK does not export vm_region/mach_vm_region for app linking.
// For a patch that is explicitly target-image + RVA, the loaded Mach-O segment
// table is a stronger source of truth anyway: it proves the address belongs to
// that image and provides the segment's intended init/max protections.
static BOOL ZN43QueryImageSegment(uintptr_t imageBase,
                                  uintptr_t address,
                                  NSUInteger length,
                                  ZN43SegmentInfo *outInfo,
                                  NSString **error) {
    if (!imageBase || !address || !length) {
        if (error) *error = @"Image/地址/长度无效";
        return NO;
    }

    const struct mach_header_64 *mh = (const struct mach_header_64 *)imageBase;
    if (mh->magic != MH_MAGIC_64) {
        if (error) *error = @"目标不是当前支持的 64-bit Mach-O image";
        return NO;
    }

    const uint8_t *commands = (const uint8_t *)(mh + 1);
    const uint8_t *commandEnd = commands + mh->sizeofcmds;
    const struct load_command *lc = (const struct load_command *)commands;
    uint64_t imageVMBase = UINT64_MAX;

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if ((const uint8_t *)lc + sizeof(struct load_command) > commandEnd || lc->cmdsize < sizeof(struct load_command) || (const uint8_t *)lc + lc->cmdsize > commandEnd) {
            if (error) *error = @"Mach-O load commands 损坏";
            return NO;
        }
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, SEG_TEXT, 16) == 0) imageVMBase = seg->vmaddr;
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }
    if (imageVMBase == UINT64_MAX) {
        if (error) *error = @"未找到 __TEXT segment";
        return NO;
    }

    lc = (const struct load_command *)commands;
    uint64_t wantedEnd = (uint64_t)address + (uint64_t)length;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (seg->vmaddr >= imageVMBase) {
                uintptr_t runtimeStart = imageBase + (uintptr_t)(seg->vmaddr - imageVMBase);
                uintptr_t runtimeEnd = runtimeStart + (uintptr_t)seg->vmsize;
                if (address >= runtimeStart && wantedEnd <= (uint64_t)runtimeEnd) {
                    if (outInfo) {
                        memset(outInfo, 0, sizeof(*outInfo));
                        outInfo->start = runtimeStart;
                        outInfo->end = runtimeEnd;
                        outInfo->protection = seg->initprot;
                        outInfo->maxProtection = seg->maxprot;
                        memcpy(outInfo->segmentName, seg->segname, 16);
                        outInfo->segmentName[16] = '\0';
                    }
                    return YES;
                }
            }
        }
        lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
    }

    if (error) *error = @"Offset 不落在目标 Mach-O 的任何 segment 内";
    return NO;
}

static BOOL ZN43Read(uintptr_t address, NSUInteger length, NSData **outData, NSString **error) {
    if (!address || !length) { if (error) *error = @"读取地址或长度无效"; return NO; }
    NSData *data = [NSData dataWithBytes:(const void *)address length:length];
    if (data.length != length) {
        if (error) *error = @"读取长度异常";
        return NO;
    }
    if (outData) *outData = data;
    return YES;
}

static void ZN43RefreshCurrent(uintptr_t address, NSUInteger length, void (^setter)(NSData *)) {
    NSData *fresh = nil;
    if (ZN43Read(address, length, &fresh, NULL) && setter) setter(fresh);
}

static BOOL ZN43WriteTransition(uintptr_t address,
                                NSData *target,
                                NSData *rollback,
                                vm_prot_t originalProtection,
                                NSString **error) {
    vm_size_t pageSize = vm_page_size;
    uintptr_t pageStart = address & ~((uintptr_t)pageSize - 1);
    uintptr_t rawEnd = address + target.length;
    uintptr_t pageEnd = (rawEnd + pageSize - 1) & ~((uintptr_t)pageSize - 1);
    size_t protectSize = (size_t)(pageEnd - pageStart);

    if (mprotect((void *)pageStart, protectSize, PROT_READ | PROT_WRITE) != 0) {
        int e = errno;
        if (error) *error = [NSString stringWithFormat:@"RX→RW 失败：errno=%d (%s)", e, strerror(e)];
        return NO;
    }

    memcpy((void *)address, target.bytes, target.length);
    sys_icache_invalidate((void *)address, target.length);

    NSData *written = nil;
    NSString *readError = nil;
    BOOL writeVerified = ZN43Read(address, target.length, &written, &readError) && [written isEqualToData:target];
    if (!writeVerified) {
        if (rollback.length == target.length) {
            memcpy((void *)address, rollback.bytes, rollback.length);
            sys_icache_invalidate((void *)address, rollback.length);
        }
        mprotect((void *)pageStart, protectSize, ZN43POSIXProtection(originalProtection));
        if (error) *error = readError.length ? [NSString stringWithFormat:@"写入 read-back 失败：%@；已回滚", readError] : @"写入 read-back 不一致；已回滚";
        return NO;
    }

    int restoreRC = mprotect((void *)pageStart, protectSize, ZN43POSIXProtection(originalProtection));
    if (restoreRC != 0) {
        int firstError = errno;
        if (rollback.length == target.length) {
            memcpy((void *)address, rollback.bytes, rollback.length);
            sys_icache_invalidate((void *)address, rollback.length);
        }
        int secondRC = mprotect((void *)pageStart, protectSize, ZN43POSIXProtection(originalProtection));
        int secondError = errno;
        if (error) {
            *error = [NSString stringWithFormat:@"写入后恢复 %@ 失败 errno=%d (%s)；原字节已回滚；二次恢复=%@%@",
                      ZN43ProtectionString(originalProtection), firstError, strerror(firstError),
                      secondRC == 0 ? @"成功" : @"失败",
                      secondRC == 0 ? @"" : [NSString stringWithFormat:@" errno=%d (%s)", secondError, strerror(secondError)]];
        }
        return NO;
    }

    NSData *final = nil;
    if (!ZN43Read(address, target.length, &final, &readError) || ![final isEqualToData:target]) {
        if (error) *error = readError.length ? [NSString stringWithFormat:@"恢复权限后 read-back 失败：%@", readError] : @"恢复权限后 read-back 不一致";
        return NO;
    }
    return YES;
}

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

@implementation ZNPatchRuntimeValidator

+ (instancetype)sharedValidator {
    static ZNPatchRuntimeValidator *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [ZNPatchRuntimeValidator new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _target = @"UnityFramework";
    _lastResult = @"尚未配置";
    _protectionDescription = @"未知";
    _segmentDescription = @"未知";
    return self;
}

- (BOOL)configureTarget:(NSString *)target offsetString:(NSString *)offsetString patchHex:(NSString *)patchHex error:(NSString **)error {
    @synchronized (self) {
        if (self.applied) {
            if (error) *error = @"当前临时 Patch 尚未恢复，请先恢复原始字节";
            return NO;
        }
        NSString *name = [target stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) { if (error) *error = @"Target 不能为空"; return NO; }

        uint64_t parsedRVA = 0;
        NSString *e = nil;
        if (!ZN43ParseRVA(offsetString, &parsedRVA, &e)) { if (error) *error = e; return NO; }
        NSData *patch = ZN43DataFromHex(patchHex, &e);
        if (!patch) { if (error) *error = e; return NO; }
        if ((parsedRVA & 3ULL) != 0) { if (error) *error = @"Offset 不是 4-byte ARM64 对齐"; return NO; }
        if ((patch.length & 3U) != 0) { if (error) *error = @"代码 Patch 长度必须是 4 bytes 的倍数"; return NO; }

        self.target = name;
        self.rva = parsedRVA;
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
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[runtime-validate] configured target=%@ rva=0x%llX patch=%@",
                                             self.target, self.rva, ZN43Hex(self.patchBytes)]];
        return YES;
    }
}

- (BOOL)validate:(NSString **)error {
    @synchronized (self) {
        if (!self.configured || !self.patchBytes.length) {
            if (error) *error = @"请先配置 target / offset / patch";
            return NO;
        }

        NSDictionary *module = [[ZNModuleManager sharedManager] moduleNamed:self.target];
        if (!module) {
            self.validated = NO;
            self.lastResult = [NSString stringWithFormat:@"目标模块未加载：%@", self.target];
            if (error) *error = self.lastResult;
            return NO;
        }
        uintptr_t imageBase = (uintptr_t)[module[@"base"] unsignedLongLongValue];
        uintptr_t address = [[ZNModuleManager sharedManager] runtimeAddressForModule:self.target rva:self.rva];
        if (!imageBase || !address) {
            self.validated = NO;
            self.lastResult = @"Runtime Address 解析失败";
            if (error) *error = self.lastResult;
            return NO;
        }

        ZN43SegmentInfo segment = {};
        NSString *e = nil;
        if (!ZN43QueryImageSegment(imageBase, address, self.patchBytes.length, &segment, &e)) {
            self.validated = NO;
            self.lastResult = e ?: @"Mach-O segment 查询失败";
            if (error) *error = self.lastResult;
            return NO;
        }
        self.runtimeAddress = address;
        self.segmentDescription = [NSString stringWithUTF8String:segment.segmentName] ?: @"?";
        self.protectionDescription = [NSString stringWithFormat:@"%@  max=%@",
                                      ZN43ProtectionString(segment.protection),
                                      ZN43ProtectionString(segment.maxProtection)];
        if ((segment.protection & VM_PROT_EXECUTE) == 0 || (segment.protection & VM_PROT_READ) == 0) {
            self.validated = NO;
            self.lastResult = [NSString stringWithFormat:@"目标不是 R-X executable segment：%@ %@",
                               self.segmentDescription, self.protectionDescription];
            if (error) *error = self.lastResult;
            return NO;
        }

        NSData *now = nil;
        if (!ZN43Read(address, self.patchBytes.length, &now, &e)) {
            self.validated = NO;
            self.lastResult = e ?: @"读取失败";
            if (error) *error = self.lastResult;
            return NO;
        }
        self.currentBytes = now;

        if ([now isEqualToData:self.patchBytes]) {
            if (!self.capturedOriginalBytes.length) {
                self.validated = NO;
                self.lastResult = @"当前位置已经等于 Patch，无法现场推断 Original；请用原版进程重新验证";
                if (error) *error = self.lastResult;
                return NO;
            }
            self.applied = YES;
        } else if (!self.capturedOriginalBytes.length) {
            // This is the only trusted OFF baseline: bytes read live from the user's
            // original binary. JSON "original" is intentionally ignored.
            self.capturedOriginalBytes = now;
            self.applied = NO;
        } else if ([now isEqualToData:self.capturedOriginalBytes]) {
            self.applied = NO;
        } else {
            self.validated = NO;
            self.lastResult = [NSString stringWithFormat:@"现场字节与本会话 Original/Patch 均不一致，拒绝更新基线。Original=%@ Current=%@ Patch=%@",
                               ZN43Hex(self.capturedOriginalBytes), ZN43Hex(now), ZN43Hex(self.patchBytes)];
            if (error) *error = self.lastResult;
            return NO;
        }

        self.validated = YES;
        self.lastResult = [NSString stringWithFormat:@"Binary/Runtime 预检 PASS：%@ + 0x%llX，%@，现场 Original=%@",
                           self.target, self.rva, self.segmentDescription, ZN43Hex(self.capturedOriginalBytes)];
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[runtime-validate] %@", self.lastResult]];
        return YES;
    }
}

- (BOOL)applyTemporary:(NSString **)error {
    @synchronized (self) {
        NSString *e = nil;
        if (!self.validated && ![self validate:&e]) {
            if (error) *error = e;
            return NO;
        }
        if (!self.capturedOriginalBytes.length || self.capturedOriginalBytes.length != self.patchBytes.length) {
            self.lastResult = @"没有可用的现场 Original，拒绝临时应用";
            if (error) *error = self.lastResult;
            return NO;
        }

        NSData *now = nil;
        if (!ZN43Read(self.runtimeAddress, self.patchBytes.length, &now, &e)) {
            self.lastResult = e ?: @"读取失败";
            if (error) *error = self.lastResult;
            return NO;
        }
        self.currentBytes = now;
        if ([now isEqualToData:self.patchBytes]) {
            self.applied = YES;
            self.lastResult = @"Patch 已经处于临时应用状态";
            return YES;
        }
        if (![now isEqualToData:self.capturedOriginalBytes]) {
            self.lastResult = [NSString stringWithFormat:@"当前字节已变化，拒绝覆盖。Original=%@ Current=%@",
                               ZN43Hex(self.capturedOriginalBytes), ZN43Hex(now)];
            if (error) *error = self.lastResult;
            return NO;
        }

        ZNExecutablePageProbe *probe = [ZNExecutablePageProbe sharedProbe];
        BOOL capable = probe.hasRun ? probe.supported : [probe runProbe];
        if (!capable) {
            self.lastResult = [NSString stringWithFormat:@"Executable Page Probe 未通过，拒绝触碰真实目标：%@",
                               probe.lastResult ?: @"unsupported"];
            if (error) *error = self.lastResult;
            [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[runtime-validate] %@", self.lastResult]];
            return NO;
        }

        NSDictionary *module = [[ZNModuleManager sharedManager] moduleNamed:self.target];
        uintptr_t imageBase = (uintptr_t)[module[@"base"] unsignedLongLongValue];
        ZN43SegmentInfo segment = {};
        if (!ZN43QueryImageSegment(imageBase, self.runtimeAddress, self.patchBytes.length, &segment, &e)) {
            self.lastResult = e ?: @"Mach-O segment 查询失败";
            if (error) *error = self.lastResult;
            return NO;
        }

        if (!ZN43WriteTransition(self.runtimeAddress,
                                 self.patchBytes,
                                 self.capturedOriginalBytes,
                                 segment.protection,
                                 &e)) {
            self.applied = NO;
            __weak typeof(self) weakSelf = self;
            ZN43RefreshCurrent(self.runtimeAddress, self.patchBytes.length, ^(NSData *fresh) { weakSelf.currentBytes = fresh; });
            self.lastResult = [NSString stringWithFormat:@"Runtime Patch FAIL：%@", e ?: @"写入失败"];
            if (error) *error = self.lastResult;
            [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[runtime-validate] %@", self.lastResult]];
            return NO;
        }

        self.applied = YES;
        __weak typeof(self) weakSelf = self;
        ZN43RefreshCurrent(self.runtimeAddress, self.patchBytes.length, ^(NSData *fresh) { weakSelf.currentBytes = fresh; });
        self.lastResult = [NSString stringWithFormat:@"Runtime Patch PASS：write / read-back / %@ restore / icache",
                           ZN43ProtectionString(segment.protection)];
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[runtime-validate] %@", self.lastResult]];
        return YES;
    }
}

- (BOOL)restoreOriginal:(NSString **)error {
    @synchronized (self) {
        if (!self.configured || !self.capturedOriginalBytes.length || !self.runtimeAddress) {
            if (error) *error = @"当前会话没有可恢复的现场 Original";
            return NO;
        }

        NSString *e = nil;
        NSData *now = nil;
        if (!ZN43Read(self.runtimeAddress, self.patchBytes.length, &now, &e)) {
            self.lastResult = e ?: @"读取失败";
            if (error) *error = self.lastResult;
            return NO;
        }
        self.currentBytes = now;
        if ([now isEqualToData:self.capturedOriginalBytes]) {
            self.applied = NO;
            self.validated = YES;
            self.lastResult = @"当前已经是现场 Original，无需恢复";
            return YES;
        }
        if (![now isEqualToData:self.patchBytes]) {
            self.lastResult = @"当前位置不是本会话 Patch，检测到第三方变化，拒绝恢复";
            if (error) *error = self.lastResult;
            return NO;
        }

        NSDictionary *module = [[ZNModuleManager sharedManager] moduleNamed:self.target];
        uintptr_t imageBase = (uintptr_t)[module[@"base"] unsignedLongLongValue];
        ZN43SegmentInfo segment = {};
        if (!ZN43QueryImageSegment(imageBase, self.runtimeAddress, self.patchBytes.length, &segment, &e)) {
            self.lastResult = e ?: @"Mach-O segment 查询失败";
            if (error) *error = self.lastResult;
            return NO;
        }
        if (!ZN43WriteTransition(self.runtimeAddress,
                                 self.capturedOriginalBytes,
                                 self.patchBytes,
                                 segment.protection,
                                 &e)) {
            self.lastResult = [NSString stringWithFormat:@"恢复 FAIL：%@", e ?: @"写入失败"];
            if (error) *error = self.lastResult;
            [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[runtime-validate] %@", self.lastResult]];
            return NO;
        }

        self.applied = NO;
        self.validated = YES;
        __weak typeof(self) weakSelf = self;
        ZN43RefreshCurrent(self.runtimeAddress, self.patchBytes.length, ^(NSData *fresh) { weakSelf.currentBytes = fresh; });
        self.lastResult = @"恢复 PASS：现场 Original 已写回并验证";
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[runtime-validate] %@", self.lastResult]];
        return YES;
    }
}

- (void)clearSession {
    @synchronized (self) {
        if (self.applied) {
            self.lastResult = @"临时 Patch 尚未恢复，拒绝清除会话";
            return;
        }
        self.target = @"UnityFramework";
        self.rva = 0;
        self.patchBytes = nil;
        self.capturedOriginalBytes = nil;
        self.currentBytes = nil;
        self.runtimeAddress = 0;
        self.configured = NO;
        self.validated = NO;
        self.applied = NO;
        self.protectionDescription = @"未知";
        self.segmentDescription = @"未知";
        self.lastResult = @"尚未配置";
    }
}

- (NSArray<NSString *> *)diagnosticLines {
    @synchronized (self) {
        if (!self.configured) {
            return @[
                @"状态：尚未配置",
                @"输入：target + offset + patch；JSON original 不参与验证",
                @"临时应用前会先要求 Executable Page Probe PASS"
            ];
        }
        return @[
            [NSString stringWithFormat:@"Target：%@", self.target ?: @""],
            [NSString stringWithFormat:@"Offset：0x%llX    Runtime：%@",
             self.rva,
             self.runtimeAddress ? [NSString stringWithFormat:@"0x%llX", (unsigned long long)self.runtimeAddress] : @"未解析"],
            [NSString stringWithFormat:@"Patch：%@", ZN43Hex(self.patchBytes)],
            [NSString stringWithFormat:@"Live Original：%@", self.capturedOriginalBytes.length ? ZN43Hex(self.capturedOriginalBytes) : @"未捕获"],
            [NSString stringWithFormat:@"Current：%@", self.currentBytes.length ? ZN43Hex(self.currentBytes) : @"未读取"],
            [NSString stringWithFormat:@"Segment：%@    VM：%@", self.segmentDescription ?: @"未知", self.protectionDescription ?: @"未知"],
            [NSString stringWithFormat:@"Applied：%@    结果：%@", self.applied ? @"YES" : @"NO", self.lastResult ?: @""]
        ];
    }
}

- (NSString *)diagnosticReport {
    return [[self diagnosticLines] componentsJoinedByString:@"\n"];
}

@end
