#import "ZNRuntimePatchExecutor.h"
#import <mach/mach.h>
#import <libkern/OSCacheControl.h>
#import <objc/runtime.h>
#import <sys/mman.h>
#import <errno.h>

static const void *kZNExpectedBytesKey = &kZNExpectedBytesKey;
static const void *kZNPatchBytesKey = &kZNPatchBytesKey;
static const void *kZNOriginalBytesKey = &kZNOriginalBytesKey;
static const void *kZNWroteMemoryKey = &kZNWroteMemoryKey;
static const void *kZNTargetWritableKey = &kZNTargetWritableKey;

@implementation ZNPatchActionDescriptor (ZNRuntimePatchExecution)
- (NSData *)zn_expectedBytes { return objc_getAssociatedObject(self, kZNExpectedBytesKey); }
- (void)setZn_expectedBytes:(NSData *)v { objc_setAssociatedObject(self, kZNExpectedBytesKey, [v copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSData *)zn_patchBytes { return objc_getAssociatedObject(self, kZNPatchBytesKey); }
- (void)setZn_patchBytes:(NSData *)v { objc_setAssociatedObject(self, kZNPatchBytesKey, [v copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (NSData *)zn_originalBytes { return objc_getAssociatedObject(self, kZNOriginalBytesKey); }
- (void)setZn_originalBytes:(NSData *)v { objc_setAssociatedObject(self, kZNOriginalBytesKey, [v copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (BOOL)zn_wroteRuntimeMemory { return [objc_getAssociatedObject(self, kZNWroteMemoryKey) boolValue]; }
- (void)setZn_wroteRuntimeMemory:(BOOL)v { objc_setAssociatedObject(self, kZNWroteMemoryKey, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
- (BOOL)zn_targetWritable { return [objc_getAssociatedObject(self, kZNTargetWritableKey) boolValue]; }
- (void)setZn_targetWritable:(BOOL)v { objc_setAssociatedObject(self, kZNTargetWritableKey, @(v), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
@end

static NSString *ZNKernError(kern_return_t kr) {
    const char *s = mach_error_string(kr);
    return [NSString stringWithFormat:@"%s (%d)", s ?: "Mach error", kr];
}

static BOOL ZNReadMemory(uintptr_t address, NSUInteger length, NSData **outData, NSString **error) {
    if (!address || !length) { if (error) *error = @"地址或长度无效"; return NO; }
    NSMutableData *data = [NSMutableData dataWithLength:length];
    vm_size_t readSize = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address,
                                         (vm_size_t)length,
                                         (vm_address_t)data.mutableBytes, &readSize);
    if (kr != KERN_SUCCESS || readSize != length) {
        if (error) *error = [NSString stringWithFormat:@"读取失败：%@，read=%lu/%lu", ZNKernError(kr), (unsigned long)readSize, (unsigned long)length];
        return NO;
    }
    if (outData) *outData = data;
    return YES;
}

static BOOL ZNWriteMemory(uintptr_t address, NSData *data, BOOL targetWritable, NSString **error) {
    if (!address || !data.length) { if (error) *error = @"写入地址或数据无效"; return NO; }

    vm_size_t pageSize = vm_page_size;
    uintptr_t pageStart = address & ~((uintptr_t)pageSize - 1);
    uintptr_t end = address + data.length;
    uintptr_t pageEnd = (end + pageSize - 1) & ~((uintptr_t)pageSize - 1);
    size_t protectSize = (size_t)(pageEnd - pageStart);

    if (!targetWritable) {
        // Bytes Patch is a code-target backend. No JIT and never W+X: temporarily
        // switch existing code pages RX -> RW, write, then restore RW -> RX.
        if (mprotect((void *)pageStart, protectSize, PROT_READ | PROT_WRITE) != 0) {
            int e = errno;
            if (error) *error = [NSString stringWithFormat:@"当前内存权限不支持运行时代码写入：mprotect RW errno=%d (%s)", e, strerror(e)];
            return NO;
        }
    }

    memcpy((void *)address, data.bytes, data.length);

    if (!targetWritable) {
        if (mprotect((void *)pageStart, protectSize, PROT_READ | PROT_EXEC) != 0) {
            int e = errno;
            if (error) *error = [NSString stringWithFormat:@"写入完成但恢复 RX 权限失败：errno=%d (%s)", e, strerror(e)];
            return NO;
        }
        sys_icache_invalidate((void *)address, data.length);
    }

    NSData *verify = nil;
    NSString *readError = nil;
    if (!ZNReadMemory(address, data.length, &verify, &readError) || ![verify isEqualToData:data]) {
        if (error) *error = readError.length ? [NSString stringWithFormat:@"写入后验证失败：%@", readError] : @"写入后字节校验失败";
        return NO;
    }
    return YES;
}

@interface ZNRuntimePatchExecutor ()
@property(nonatomic,copy) NSString *lastResult;
@property(nonatomic,assign) NSUInteger successfulTransactions;
@property(nonatomic,assign) NSUInteger failedTransactions;
@end

@implementation ZNRuntimePatchExecutor
+ (instancetype)sharedExecutor {
    static ZNRuntimePatchExecutor *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [ZNRuntimePatchExecutor new]; });
    return s;
}
- (instancetype)init { self = [super init]; if (!self) return nil; _lastResult = @"尚未执行"; return self; }

- (BOOL)prepareAction:(ZNPatchActionDescriptor *)a enabling:(BOOL)enabling current:(NSData **)current restore:(NSData **)restore error:(NSString **)error {
    if (a.type != ZNPatchActionTypeBytes) {
        if (error) *error = [NSString stringWithFormat:@"%@：v0.4.1 仅执行 Bytes Patch", a.identifier];
        a.state = ZNPatchStateUnsupported; return NO;
    }
    if (!a.resolvedAddress) {
        if (error) *error = [NSString stringWithFormat:@"%@：目标地址尚未解析", a.identifier];
        a.state = ZNPatchStateTargetMissing; return NO;
    }
    NSData *patch = a.zn_patchBytes;
    NSData *expected = a.zn_expectedBytes;
    if (!patch.length) { if (error) *error = [NSString stringWithFormat:@"%@：patchBytes 为空", a.identifier]; a.state = ZNPatchStateFailed; return NO; }
    if (!expected.length) { if (error) *error = [NSString stringWithFormat:@"%@：expectedBytes 为空；为避免覆盖未知版本，执行器拒绝盲写", a.identifier]; a.state = ZNPatchStateFailed; return NO; }
    if (expected.length != patch.length) { if (error) *error = [NSString stringWithFormat:@"%@：expectedBytes 与 patchBytes 长度不同", a.identifier]; a.state = ZNPatchStateFailed; return NO; }

    NSData *now = nil;
    NSString *readError = nil;
    if (!ZNReadMemory(a.resolvedAddress, patch.length, &now, &readError)) {
        if (error) *error = [NSString stringWithFormat:@"%@：%@", a.identifier, readError ?: @"读取失败"];
        a.state = ZNPatchStateFailed; return NO;
    }
    NSData *knownRestore = a.zn_originalBytes ?: expected;
    if (enabling) {
        if ([now isEqualToData:patch]) { if (!a.zn_originalBytes) a.zn_originalBytes = expected; }
        else if (![now isEqualToData:expected]) {
            if (error) *error = [NSString stringWithFormat:@"%@：当前字节既不是 expected 也不是 patch，拒绝覆盖", a.identifier];
            a.state = ZNPatchStateByteMismatch; return NO;
        } else { a.zn_originalBytes = now; knownRestore = now; }
    } else {
        if (!knownRestore.length) { if (error) *error = [NSString stringWithFormat:@"%@：没有可恢复的原始字节", a.identifier]; a.state = ZNPatchStateConflict; return NO; }
        if (![now isEqualToData:patch] && ![now isEqualToData:knownRestore]) {
            if (error) *error = [NSString stringWithFormat:@"%@：当前字节发生第三方变化，拒绝恢复", a.identifier];
            a.state = ZNPatchStateConflict; return NO;
        }
    }
    if (current) *current = now;
    if (restore) *restore = knownRestore;
    return YES;
}

- (BOOL)setActions:(NSArray<ZNPatchActionDescriptor *> *)actions enabled:(BOOL)enabled error:(NSString **)error {
    if (!actions.count) { if (error) *error = @"Feature 没有 Runtime Action"; return NO; }
    NSMutableArray<NSDictionary *> *plan = [NSMutableArray arrayWithCapacity:actions.count];
    for (ZNPatchActionDescriptor *a in actions) {
        NSData *current = nil, *restore = nil;
        NSString *e = nil;
        if (![self prepareAction:a enabling:enabled current:&current restore:&restore error:&e]) {
            self.failedTransactions++; self.lastResult = e ?: @"预检失败"; a.lastError = self.lastResult;
            if (error) *error = self.lastResult; return NO;
        }
        NSData *target = enabled ? a.zn_patchBytes : restore;
        [plan addObject:@{@"action":a, @"before":current, @"target":target ?: [NSData data]}];
    }

    NSMutableArray<NSDictionary *> *changed = [NSMutableArray array];
    for (NSDictionary *step in plan) {
        ZNPatchActionDescriptor *a = step[@"action"];
        NSData *before = step[@"before"];
        NSData *target = step[@"target"];
        if ([before isEqualToData:target]) { a.state = enabled ? ZNPatchStateEnabled : ZNPatchStateDisabled; a.lastError = @""; continue; }
        NSString *writeError = nil;
        if (!ZNWriteMemory(a.resolvedAddress, target, a.zn_targetWritable, &writeError)) {
            for (NSDictionary *done in [changed reverseObjectEnumerator]) {
                ZNPatchActionDescriptor *ra = done[@"action"];
                NSData *rb = done[@"before"];
                NSString *ignored = nil;
                ZNWriteMemory(ra.resolvedAddress, rb, ra.zn_targetWritable, &ignored);
                ra.zn_wroteRuntimeMemory = NO;
            }
            self.failedTransactions++;
            self.lastResult = [NSString stringWithFormat:@"%@：%@；事务已回滚 %lu 个 Action", a.identifier, writeError ?: @"写入失败", (unsigned long)changed.count];
            a.state = [writeError containsString:@"内存权限"] ? ZNPatchStateUnsupported : ZNPatchStateFailed;
            a.lastError = self.lastResult;
            if (error) *error = self.lastResult;
            [[ZNRuntimeLogger sharedLogger] log:self.lastResult];
            return NO;
        }
        [changed addObject:step];
        a.zn_wroteRuntimeMemory = enabled;
        a.state = enabled ? ZNPatchStateEnabled : ZNPatchStateDisabled;
        a.lastError = @"";
    }

    self.successfulTransactions++;
    self.lastResult = [NSString stringWithFormat:@"%@成功：%lu 个 Action", enabled ? @"启用" : @"恢复", (unsigned long)actions.count];
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"Runtime Executor %@", self.lastResult]];
    return YES;
}

- (BOOL)runSelfTest {
    uint8_t *buf = (uint8_t *)malloc(16);
    if (!buf) return NO;
    const uint8_t originalBytes[] = {0x11,0x22,0x33,0x44};
    const uint8_t patchedBytes[]  = {0xAA,0xBB,0xCC,0xDD};
    memcpy(buf, originalBytes, sizeof(originalBytes));
    ZNPatchActionDescriptor *a = [[ZNPatchActionDescriptor alloc] initWithIdentifier:@"executor_selftest" type:ZNPatchActionTypeBytes];
    a.resolvedAddress = (uintptr_t)buf;
    a.zn_targetWritable = YES;
    a.zn_expectedBytes = [NSData dataWithBytes:originalBytes length:sizeof(originalBytes)];
    a.zn_patchBytes = [NSData dataWithBytes:patchedBytes length:sizeof(patchedBytes)];
    NSString *e1 = nil, *e2 = nil;
    BOOL on = [self setActions:@[a] enabled:YES error:&e1];
    BOOL bytesOn = memcmp(buf, patchedBytes, sizeof(patchedBytes)) == 0;
    BOOL off = on && [self setActions:@[a] enabled:NO error:&e2];
    BOOL bytesOff = memcmp(buf, originalBytes, sizeof(originalBytes)) == 0;
    free(buf);
    BOOL ok = on && bytesOn && off && bytesOff;
    self.lastResult = ok ? @"自检 PASS：read / validate / write / verify / restore" : [NSString stringWithFormat:@"自检 FAIL：%@ %@", e1 ?: @"", e2 ?: @""];
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"Runtime Executor %@", self.lastResult]];
    return ok;
}

- (NSString *)diagnosticReport {
    return [NSString stringWithFormat:@"Runtime Patch Executor 0.4.1\n模式: No JIT / 代码页 RX→RW→RX / expected 校验 / read-back / 事务回滚\n成功事务: %lu  失败事务: %lu\n最近结果: %@\n",
            (unsigned long)self.successfulTransactions, (unsigned long)self.failedTransactions, self.lastResult ?: @""];
}
@end
