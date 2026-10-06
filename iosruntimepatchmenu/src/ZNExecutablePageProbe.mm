#import "ZNExecutablePageProbe.h"
#import <sys/mman.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <libkern/OSCacheControl.h>

// Dedicated __TEXT section, page-aligned so the probe never changes protection on
// the page currently executing runProbe. The target is never executed while writable.
__attribute__((used, noinline, aligned(16384), section("__TEXT,__znprobe")))
static int ZNExecutableProbeTarget(void) {
    return 0x42;
}

@interface ZNExecutablePageProbe ()
@property(nonatomic,assign,readwrite) BOOL hasRun;
@property(nonatomic,assign,readwrite) BOOL supported;
@property(nonatomic,assign,readwrite) double durationMs;
@property(nonatomic,copy,readwrite) NSString *lastResult;
@end

@implementation ZNExecutablePageProbe

+ (instancetype)sharedProbe {
    static ZNExecutablePageProbe *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [ZNExecutablePageProbe new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _lastResult = @"尚未运行";
    return self;
}

- (BOOL)runProbe {
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    self.hasRun = YES;
    self.supported = NO;

    const int beforeValue = ZNExecutableProbeTarget();
    if (beforeValue != 0x42) {
        self.lastResult = [NSString stringWithFormat:@"FAIL：探针函数初始返回异常 value=%d", beforeValue];
        self.durationMs = (CFAbsoluteTimeGetCurrent() - begin) * 1000.0;
        return NO;
    }

    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) ps = 16384;
    const size_t pageSize = (size_t)ps;
    uintptr_t target = (uintptr_t)(void *)&ZNExecutableProbeTarget;
    uintptr_t page = target & ~((uintptr_t)pageSize - 1);

    uint8_t original[4] = {0};
    memcpy(original, (const void *)target, sizeof(original));
    uint8_t mutated[4] = {0};
    memcpy(mutated, original, sizeof(mutated));
    mutated[0] ^= 0x01;

    errno = 0;
    if (mprotect((void *)page, pageSize, PROT_READ | PROT_WRITE) != 0) {
        int e = errno;
        self.lastResult = [NSString stringWithFormat:@"UNSUPPORTED：__TEXT RX→RW 被拒绝 errno=%d (%s) page=0x%llx", e, strerror(e), (unsigned long long)page];
        self.durationMs = (CFAbsoluteTimeGetCurrent() - begin) * 1000.0;
        return NO;
    }

    memcpy((void *)target, mutated, sizeof(mutated));
    BOOL changed = (memcmp((const void *)target, mutated, sizeof(mutated)) == 0);

    // Restore the exact original bytes before executable permission is restored.
    memcpy((void *)target, original, sizeof(original));
    BOOL restoredBytes = (memcmp((const void *)target, original, sizeof(original)) == 0);

    errno = 0;
    if (mprotect((void *)page, pageSize, PROT_READ | PROT_EXEC) != 0) {
        int e = errno;
        self.lastResult = [NSString stringWithFormat:@"FAIL：写入=%@ 原字节恢复=%@，但 RW→RX 失败 errno=%d (%s)", changed?@"OK":@"FAIL", restoredBytes?@"OK":@"FAIL", e, strerror(e)];
        self.durationMs = (CFAbsoluteTimeGetCurrent() - begin) * 1000.0;
        return NO;
    }

    sys_icache_invalidate((void *)target, sizeof(original));
    const int afterValue = ZNExecutableProbeTarget();
    BOOL executableAgain = (afterValue == 0x42);

    self.supported = changed && restoredBytes && executableAgain;
    self.durationMs = (CFAbsoluteTimeGetCurrent() - begin) * 1000.0;
    self.lastResult = self.supported
        ? [NSString stringWithFormat:@"PASS：真实 __TEXT RX→RW→写入→恢复→RX→执行，%.2f ms", self.durationMs]
        : [NSString stringWithFormat:@"FAIL：changed=%d restored=%d executable=%d，%.2f ms", changed, restoredBytes, executableAgain, self.durationMs];
    return self.supported;
}

- (NSString *)diagnosticReport {
    return [NSString stringWithFormat:@"Executable Page Probe 0.4.2\n已运行: %@  支持: %@  耗时: %.2f ms\n结果: %@\n",
            self.hasRun?@"是":@"否", self.supported?@"是":@"否", self.durationMs, self.lastResult ?: @""];
}

@end
