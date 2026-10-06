#import "ZNPatchCore.h"
#import "ZNRuntimePatchExecutor.h"
#import <objc/runtime.h>

// v0.4.1: route configured Bytes Actions through the real runtime executor.
// Features without Actions remain UI/mock placeholders until JSON/HFAMap supplies descriptors.

@interface ZNPatchManager (ZNRuntimeExecutorV041)
- (void)zn41_setFeature:(NSString *)identifier enabled:(BOOL)enabled;
- (BOOL)zn41_runSelfTest;
- (NSString *)zn41_diagnosticReport;
@end

@implementation ZNPatchManager (ZNRuntimeExecutorV041)
- (void)zn41_setFeature:(NSString *)identifier enabled:(BOOL)enabled {
    ZNPatchDescriptor *d = [self descriptorForIdentifier:identifier];
    if (!d || d.actions.count == 0) {
        [self zn41_setFeature:identifier enabled:enabled];
        return;
    }

    [self refreshResolution];
    NSString *error = nil;
    BOOL ok = [[ZNRuntimePatchExecutor sharedExecutor] setActions:d.actions enabled:enabled error:&error];
    if (!ok) {
        d.lastError = error ?: @"Runtime Patch 执行失败";
        BOOL unsupported = NO, mismatch = NO, conflict = NO, waiting = NO;
        for (ZNPatchActionDescriptor *a in d.actions) {
            unsupported |= (a.state == ZNPatchStateUnsupported);
            mismatch |= (a.state == ZNPatchStateByteMismatch);
            conflict |= (a.state == ZNPatchStateConflict);
            waiting |= (a.state == ZNPatchStateWaitingModule || a.state == ZNPatchStateTargetMissing);
        }
        if (unsupported) d.state = ZNPatchStateUnsupported;
        else if (mismatch) d.state = ZNPatchStateByteMismatch;
        else if (conflict) d.state = ZNPatchStateConflict;
        else if (waiting) d.state = ZNPatchStateWaitingModule;
        else d.state = ZNPatchStateFailed;
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"Feature %@ %@失败：%@", identifier, enabled?@"启用":@"关闭", d.lastError]];
        return;
    }

    // Persist only after the complete transaction succeeds.
    [self zn41_setFeature:identifier enabled:enabled];
    d.backend = @"RuntimeBytes";
    d.state = enabled ? ZNPatchStateEnabled : ZNPatchStateDisabled;
    d.lastError = @"";
}

- (BOOL)zn41_runSelfTest {
    BOOL foundationOK = [self zn41_runSelfTest];
    BOOL executorOK = [[ZNRuntimePatchExecutor sharedExecutor] runSelfTest];
    BOOL ok = foundationOK && executorOK;
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"v0.4.1 综合自检 %@ foundation=%d executor=%d", ok?@"PASS":@"FAIL", foundationOK, executorOK]];
    return ok;
}

- (NSString *)zn41_diagnosticReport {
    NSString *base = [self zn41_diagnosticReport];
    return [NSString stringWithFormat:@"%@\n%@", base ?: @"", [[ZNRuntimePatchExecutor sharedExecutor] diagnosticReport]];
}
@end

static void ZNSwapPatchManagerV041(SEL original, SEL replacement) {
    Class cls = [ZNPatchManager class];
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

extern "C" void ZNInstallRuntimeExecutorV041Deferred(void) {
    @autoreleasepool {
        ZNSwapPatchManagerV041(@selector(setFeature:enabled:), @selector(zn41_setFeature:enabled:));
        ZNSwapPatchManagerV041(@selector(runSelfTest), @selector(zn41_runSelfTest));
        ZNSwapPatchManagerV041(@selector(diagnosticReport), @selector(zn41_diagnosticReport));
        [[ZNRuntimeLogger sharedLogger] log:@"v0.4.1 Runtime Patch Executor installed：expected 校验 / 写入验证 / 恢复 / 多 Action 事务回滚"];
    }
}
