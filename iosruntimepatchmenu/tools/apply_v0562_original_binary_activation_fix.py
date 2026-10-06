#!/usr/bin/env python3
from pathlib import Path

root = Path('iosruntimepatchmenu/src')

# --- ZNPatchCore.mm: suppress dyld registration replay and coalesce real image bursts.
p = root / 'ZNPatchCore.mm'
s = p.read_text()
if 'v0.5.6.2 dyld replay suppression + image-burst coalescing' not in s:
    s = s.replace('#import "ZNIL2CPPResolver.h"\n#import <mach-o/dyld.h>\n',
                  '#import "ZNIL2CPPResolver.h"\n#import "ZNActivationTrace.h"\n#import <mach-o/dyld.h>\n#include <atomic>\n', 1)

    old = '''static __unsafe_unretained id gZNModuleManager = nil;
static void ZNModuleAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh;
    (void)slide;
    id manager = gZNModuleManager;
    if (!manager) return;
    @synchronized (manager) {
        uint64_t gen = [[manager valueForKey:@"moduleGeneration"] unsignedLongLongValue];
        [manager setValue:@(gen + 1) forKey:@"moduleGeneration"];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZNModuleManagerImageAdded" object:manager];
    });
}

@interface ZNModuleManager ()
@property(nonatomic,assign,readwrite) uint64_t moduleGeneration;
@end
'''
    new = '''// v0.5.6.2 dyld replay suppression + image-burst coalescing.
// _dyld_register_func_for_add_image synchronously replays already-loaded images
// when the callback is registered. Those images are not new work and must not
// fan out into hundreds of main-queue refreshes on first menu activation.
@interface ZNModuleManager ()
@property(nonatomic,assign,readwrite) uint64_t moduleGeneration;
@property(nonatomic,assign) NSUInteger pendingImageCount;
@property(nonatomic,assign) BOOL imageNotificationScheduled;
@property(nonatomic,assign) NSUInteger replaySuppressedCount;
@property(nonatomic,assign) NSUInteger deliveredImageNotificationCount;
@end

static __unsafe_unretained ZNModuleManager *gZNModuleManager = nil;
static std::atomic<bool> gZNModuleRegistrationReplay{false};

static void ZNModuleAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh;
    (void)slide;
    ZNModuleManager *manager = gZNModuleManager;
    if (!manager) return;

    if (gZNModuleRegistrationReplay.load(std::memory_order_acquire)) {
        @synchronized (manager) {
            manager.replaySuppressedCount += 1;
        }
        return;
    }

    __block BOOL shouldSchedule = NO;
    @synchronized (manager) {
        manager.moduleGeneration += 1;
        manager.pendingImageCount += 1;
        if (!manager.imageNotificationScheduled) {
            manager.imageNotificationScheduled = YES;
            shouldSchedule = YES;
        }
    }
    if (!shouldSchedule) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger burst = 0;
        NSUInteger delivered = 0;
        @synchronized (manager) {
            burst = manager.pendingImageCount;
            manager.pendingImageCount = 0;
            manager.imageNotificationScheduled = NO;
            manager.deliveredImageNotificationCount += 1;
            delivered = manager.deliveredImageNotificationCount;
        }

        ZNActivationTraceLog([NSString stringWithFormat:@"[module-manager] image burst coalesced=%lu · notification=%lu",
                              (unsigned long)burst,
                              (unsigned long)delivered]);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZNModuleManagerImageAdded"
                                                            object:manager
                                                          userInfo:@{@"burstCount": @(burst)}];
    });
}
'''
    if old not in s:
        raise SystemExit('ZNPatchCore module callback anchor missing')
    s = s.replace(old, new, 1)

    old_init = '''- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _moduleGeneration = 1;
    gZNModuleManager = self;
    _dyld_register_func_for_add_image(ZNModuleAdded);
    return self;
}
'''
    new_init = '''- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _moduleGeneration = 1;
    _pendingImageCount = 0;
    _imageNotificationScheduled = NO;
    _replaySuppressedCount = 0;
    _deliveredImageNotificationCount = 0;
    gZNModuleManager = self;

    uint32_t imagesBeforeRegistration = _dyld_image_count();
    gZNModuleRegistrationReplay.store(true, std::memory_order_release);
    _dyld_register_func_for_add_image(ZNModuleAdded);
    gZNModuleRegistrationReplay.store(false, std::memory_order_release);

    ZNActivationTraceLog([NSString stringWithFormat:@"[module-manager] dyld callback registered · existing=%u · replay suppressed=%lu",
                          imagesBeforeRegistration,
                          (unsigned long)_replaySuppressedCount]);
    return self;
}
'''
    if old_init not in s:
        raise SystemExit('ZNPatchCore init anchor missing')
    s = s.replace(old_init, new_init, 1)

    diag = '[s appendFormat:@"模块代数: %llu\\n", self.moduleGeneration];'
    diag_new = diag + '\n    [s appendFormat:@"dyld replay suppressed: %lu\\n", (unsigned long)self.replaySuppressedCount];\n    [s appendFormat:@"image notifications delivered: %lu\\n", (unsigned long)self.deliveredImageNotificationCount];'
    if diag not in s:
        raise SystemExit('ZNPatchCore diagnostic anchor missing')
    s = s.replace(diag, diag_new, 1)

    p.write_text(s)

# --- ZNStaticDispatchRuntime.mm: coalesce refresh requests and label original-binary mode.
p = root / 'ZNStaticDispatchRuntime.mm'
s = p.read_text()
if 'v0.5.6.2 refresh-request coalescer' not in s:
    prop = '@property(nonatomic,copy) NSString *lastDiscoverySummary;\n'
    if prop not in s:
        raise SystemExit('StaticDispatch property anchor missing')
    s = s.replace(prop, prop + '@property(nonatomic,assign) BOOL refreshScheduled;\n@property(nonatomic,assign) NSUInteger refreshRequestCount;\n@property(nonatomic,assign) NSUInteger refreshExecutionCount;\n@property(nonatomic,assign) NSUInteger refreshCoalescedCount;\n', 1)

    old_image = '''- (void)zn44_imageAdded:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}
'''
    new_image = '''// v0.5.6.2 refresh-request coalescer: one burst of image additions must
// produce at most one Static Dispatch refresh. The first activation refresh and
// image-added refreshes share the same gate, so dyld bursts cannot build a long
// main-queue backlog.
- (void)zn44_scheduleRefreshAfter:(NSTimeInterval)delay reason:(NSString *)reason {
    void (^scheduleBlock)(void) = ^{
        self.refreshRequestCount += 1;
        if (self.refreshScheduled) {
            self.refreshCoalescedCount += 1;
            if (self.refreshCoalescedCount <= 3 || (self.refreshCoalescedCount % 100) == 0) {
                ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh request coalesced · reason=%@ · requests=%lu executions=%lu coalesced=%lu",
                                      reason ?: @"unknown",
                                      (unsigned long)self.refreshRequestCount,
                                      (unsigned long)self.refreshExecutionCount,
                                      (unsigned long)self.refreshCoalescedCount]);
            }
            return;
        }

        self.refreshScheduled = YES;
        NSUInteger requestID = self.refreshRequestCount;
        ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh scheduled · request=%lu · reason=%@ · delay=%.0fms",
                              (unsigned long)requestID,
                              reason ?: @"unknown",
                              delay * 1000.0]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.0, delay) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.refreshScheduled = NO;
            self.refreshExecutionCount += 1;
            ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh execution=%lu · request=%lu · reason=%@",
                                  (unsigned long)self.refreshExecutionCount,
                                  (unsigned long)requestID,
                                  reason ?: @"unknown"]);
            [self refresh];
        });
    };

    if (NSThread.isMainThread) scheduleBlock();
    else dispatch_async(dispatch_get_main_queue(), scheduleBlock);
}

- (void)zn44_imageAdded:(NSNotification *)note {
    NSUInteger burst = [note.userInfo[@"burstCount"] unsignedIntegerValue];
    ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] image notification received · burst=%lu",
                          (unsigned long)MAX((NSUInteger)1, burst)]);
    [self zn44_scheduleRefreshAfter:0.20 reason:@"image-added-burst"];
}
'''
    if old_image not in s:
        raise SystemExit('StaticDispatch imageAdded anchor missing')
    s = s.replace(old_image, new_image, 1)

    old_summary = '''    self.lastRefreshMilliseconds = (ZNActivationTraceNow() - refreshStart) * 1000.0;
    self.lastDiscoverySummary = [NSString stringWithFormat:@"direct=%lu fallback=%lu probes=%llu",
                                 (unsigned long)directImages,
                                 (unsigned long)fallbackImages,
                                 fallbackProbes];

    ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh end · %.1fms · bundleImages=%lu direct=%lu fallback=%lu fallbackBytes=%llu probes=%llu · logical=%lu physical=%lu shared=%lu payload-v2=%lu/%lu",
                          self.lastRefreshMilliseconds,
                          (unsigned long)bundleImages,
                          (unsigned long)directImages,
                          (unsigned long)fallbackImages,
                          fallbackBytes,
                          fallbackProbes,
                          (unsigned long)found.count,
                          (unsigned long)counts.count,
                          (unsigned long)shared,
                          (unsigned long)payloadV2,
                          (unsigned long)found.count]);
'''
    new_summary = '''    self.lastRefreshMilliseconds = (ZNActivationTraceNow() - refreshStart) * 1000.0;
    NSString *mode = found.count ? @"generated-static" : @"original-binary/no-static-metadata";
    self.lastDiscoverySummary = [NSString stringWithFormat:@"mode=%@ direct=%lu fallback=%lu probes=%llu requests=%lu executions=%lu coalesced=%lu",
                                 mode,
                                 (unsigned long)directImages,
                                 (unsigned long)fallbackImages,
                                 fallbackProbes,
                                 (unsigned long)self.refreshRequestCount,
                                 (unsigned long)self.refreshExecutionCount,
                                 (unsigned long)self.refreshCoalescedCount];

    if (found.count == 0) {
        ZNActivationTraceLog(@"[static-dispatch] original-binary mode · no generated Static metadata found");
    } else {
        ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] generated-static mode · logical=%lu physical=%lu",
                              (unsigned long)found.count,
                              (unsigned long)counts.count]);
    }

    ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh end · %.1fms · bundleImages=%lu direct=%lu fallback=%lu fallbackBytes=%llu probes=%llu · logical=%lu physical=%lu shared=%lu payload-v2=%lu/%lu · requests=%lu executions=%lu coalesced=%lu",
                          self.lastRefreshMilliseconds,
                          (unsigned long)bundleImages,
                          (unsigned long)directImages,
                          (unsigned long)fallbackImages,
                          fallbackBytes,
                          fallbackProbes,
                          (unsigned long)found.count,
                          (unsigned long)counts.count,
                          (unsigned long)shared,
                          (unsigned long)payloadV2,
                          (unsigned long)found.count,
                          (unsigned long)self.refreshRequestCount,
                          (unsigned long)self.refreshExecutionCount,
                          (unsigned long)self.refreshCoalescedCount]);
'''
    if old_summary not in s:
        raise SystemExit('StaticDispatch summary anchor missing')
    s = s.replace(old_summary, new_summary, 1)

    old_prepare = '''extern "C" void ZNPrepareStaticDispatchRuntimeDeferred(void) {
    @autoreleasepool {
        ZNStaticDispatchRuntime *runtime = [ZNStaticDispatchRuntime sharedRuntime];
        ZNActivationTraceLog(@"[static-dispatch] prepare complete; refresh timer armed +350ms");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ZNActivationTraceLog(@"[static-dispatch] refresh timer fired");
            [runtime refresh];
        });
    }
}
'''
    new_prepare = '''extern "C" void ZNPrepareStaticDispatchRuntimeDeferred(void) {
    @autoreleasepool {
        ZNStaticDispatchRuntime *runtime = [ZNStaticDispatchRuntime sharedRuntime];
        ZNActivationTraceLog(@"[static-dispatch] prepare complete; initial refresh requested +350ms");
        [runtime zn44_scheduleRefreshAfter:0.35 reason:@"first-activation"];
    }
}
'''
    if old_prepare not in s:
        raise SystemExit('StaticDispatch prepare anchor missing')
    s = s.replace(old_prepare, new_prepare, 1)
    p.write_text(s)

# --- Version/log markers.
p = root / 'ZNActivationTrace.mm'
s = p.read_text().replace('ZonoPatch-v0.5.6.1.log', 'ZonoPatch-v0.5.6.2.log')
s = s.replace('ZonoPatch v0.5.6.1 activation trace start', 'ZonoPatch v0.5.6.2 activation trace start')
p.write_text(s)

p = root / 'ZNDeferredBootstrap.mm'
s = p.read_text().replace('v0.5.6.1 deferred activation failed', 'v0.5.6.2 deferred activation failed')
s = s.replace('// The only v0.5.6.1 load-time constructor.', '// The only v0.5.6.2 load-time constructor.')
p.write_text(s)

p = root / 'ZonoeRuntimeMenu.mm'
s = p.read_text().replace('static NSString * const kZNMenuVersion = @"0.5.6-ui-core";',
                          'static NSString * const kZNMenuVersion = @"0.5.6.2-ui-core";')
p.write_text(s)

print('v0.5.6.2 original-binary activation fix applied')
