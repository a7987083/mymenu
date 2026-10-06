#import "ZNPatchCore.h"
#import "ZNExecutablePageProbe.h"
#import "ZNDeveloperGate.h"
#import <objc/runtime.h>
#import <atomic>

static dispatch_queue_t gZN42ResolverQueue;
static dispatch_source_t gZN42WatchdogTimer;
static std::atomic<uint64_t> gZN42RequestedGeneration{0};
static std::atomic<uint64_t> gZN42DyldBurstCount{0};
static std::atomic<uint64_t> gZN42RefreshCount{0};
static std::atomic<uint64_t> gZN42StallCount{0};
static std::atomic<double> gZN42MaxRefreshMs{0.0};
static std::atomic<double> gZN42MaxMainDelayMs{0.0};
static std::atomic<bool> gZN42PingPending{false};

static NSString *ZN42ThreadName(void) {
    return NSThread.isMainThread ? @"main" : @"bg";
}

static void ZN42AtomicMax(std::atomic<double> &slot, double value) {
    double old = slot.load();
    while (value > old && !slot.compare_exchange_weak(old, value)) {}
}

static void ZN42RecordRefresh(NSString *source, uint64_t generation, NSUInteger imageCount, double ms) {
    gZN42RefreshCount.fetch_add(1);
    ZN42AtomicMax(gZN42MaxRefreshMs, ms);
    NSString *slow = ms >= 50.0 ? @" [SLOW]" : @"";
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[resolver][%@][%@] refresh done generation=%llu images=%lu duration=%.2fms%@",
                                         source ?: @"unknown", ZN42ThreadName(), generation,
                                         (unsigned long)imageCount, ms, slow]];
}

@interface ZNPatchManager (ZNRuntimeDiagnosticsV042)
- (void)zn42_moduleAdded:(NSNotification *)note;
- (void)zn42_refreshResolution;
- (NSString *)zn42_diagnosticReport;
@end

@implementation ZNPatchManager (ZNRuntimeDiagnosticsV042)

- (void)zn42_moduleAdded:(NSNotification *)note {
    (void)note;
    uint64_t generation = [ZNModuleManager sharedManager].moduleGeneration;
    gZN42RequestedGeneration.store(generation);
    gZN42DyldBurstCount.fetch_add(1);

    // Keep the useful resolver debounce for every build. Only the expensive
    // main-thread watchdog is developer-gated below.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)), gZN42ResolverQueue, ^{
        if (gZN42RequestedGeneration.load() != generation) return;
        uint64_t burst = gZN42DyldBurstCount.exchange(0);
        ZNModuleManager *mm = [ZNModuleManager sharedManager];
        NSDictionary *unity = mm.unityFramework;
        NSUInteger images = mm.loadedImages.count;
        if (!unity) return;

        CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
        @synchronized (self) {
            [self zn42_refreshResolution];
        }
        double ms = (CFAbsoluteTimeGetCurrent() - begin) * 1000.0;
        ZN42RecordRefresh(@"dyld-debounce", generation, images, ms);
        (void)burst;
    });
}

- (void)zn42_refreshResolution {
    ZNModuleManager *mm = [ZNModuleManager sharedManager];
    uint64_t generation = mm.moduleGeneration;
    NSUInteger images = mm.loadedImages.count;
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    @synchronized (self) {
        [self zn42_refreshResolution];
    }
    double ms = (CFAbsoluteTimeGetCurrent() - begin) * 1000.0;
    ZN42RecordRefresh(@"manual", generation, images, ms);
}

- (NSString *)zn42_diagnosticReport {
    NSString *base = [self zn42_diagnosticReport];
    NSString *watchdog = [ZNDeveloperGate sharedGate].authorized ? @"developer-only/on" : @"public/off";
    NSString *perf = [NSString stringWithFormat:@"Runtime Diagnostics 0.5.2\nrefreshCount=%llu maxRefresh=%.2fms\nmainWatchdog=%@ mainStallCount=%llu maxMainDelay=%.2fms\n",
                      gZN42RefreshCount.load(), gZN42MaxRefreshMs.load(), watchdog,
                      gZN42StallCount.load(), gZN42MaxMainDelayMs.load()];
    return [NSString stringWithFormat:@"%@\n%@\n%@", base ?: @"", perf, [[ZNExecutablePageProbe sharedProbe] diagnosticReport]];
}

@end

static void ZN42StartMainThreadWatchdog(void) {
    if (gZN42WatchdogTimer) return;
    gZN42WatchdogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gZN42ResolverQueue);
    dispatch_source_set_timer(gZN42WatchdogTimer,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              500 * NSEC_PER_MSEC,
                              50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gZN42WatchdogTimer, ^{
        bool expected = false;
        if (!gZN42PingPending.compare_exchange_strong(expected, true)) return;
        CFAbsoluteTime sent = CFAbsoluteTimeGetCurrent();
        dispatch_async(dispatch_get_main_queue(), ^{
            double delayMs = (CFAbsoluteTimeGetCurrent() - sent) * 1000.0;
            gZN42PingPending.store(false);
            if (delayMs >= 250.0) {
                gZN42StallCount.fetch_add(1);
                ZN42AtomicMax(gZN42MaxMainDelayMs, delayMs);
                NSString *severity = delayMs >= 1000.0 ? @"SEVERE" : @"SLOW";
                [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[watchdog][main][%@] main-thread delay=%.2fms", severity, delayMs]];
            }
        });
    });
    dispatch_resume(gZN42WatchdogTimer);
}

static void ZNSwapPatchManagerV042(SEL original, SEL replacement) {
    Class cls = [ZNPatchManager class];
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

extern "C" void ZNInstallRuntimeDiagnosticsV042Deferred(void) {
    @autoreleasepool {
        gZN42ResolverQueue = dispatch_queue_create("com.zonoe.patch.resolver.v052", DISPATCH_QUEUE_SERIAL);
        ZNSwapPatchManagerV042(@selector(moduleAdded:), @selector(zn42_moduleAdded:));
        ZNSwapPatchManagerV042(@selector(refreshResolution), @selector(zn42_refreshResolution));
        ZNSwapPatchManagerV042(@selector(diagnosticReport), @selector(zn42_diagnosticReport));

        // File 1 is evaluated once when deferred activation first reaches ZNDeveloperGate. The watchdog is never
        // created in public mode and cannot be enabled later without restart.
        if ([ZNDeveloperGate sharedGate].authorized) {
            ZN42StartMainThreadWatchdog();
            [[ZNRuntimeLogger sharedLogger] log:@"[bootstrap][dev] runtime watchdog enabled from first-activation g permission"];
        }
    }
}
