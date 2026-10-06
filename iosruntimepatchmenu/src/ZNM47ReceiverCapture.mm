#import "ZNM47ReceiverCapture.h"
#import "ZNM47DobbyCompat.h"
#import "ZNPatchCore.h"

#include <atomic>

static std::atomic<bool> gZNM47CaptureActive(false);
static std::atomic<uintptr_t> gZNM47CapturedReceiver(0);
static void *gZNM47InstrumentAddress = NULL;
static ZNM47ReceiverCaptureCompletion gZNM47Completion = nil;

static void ZNM47FinishReceiverCapture(BOOL timedOut) {
    bool expected = true;
    if (!gZNM47CaptureActive.compare_exchange_strong(expected, false)) return;

    void *address = gZNM47InstrumentAddress;
    gZNM47InstrumentAddress = NULL;
    if (address) DobbyDestroy(address);

    uintptr_t receiver = gZNM47CapturedReceiver.exchange(0);
    ZNM47ReceiverCaptureCompletion completion = gZNM47Completion;
    gZNM47Completion = nil;

    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m4.7-receiver-capture] finish address=%p receiver=0x%llX timeout=%d",
                                         address,
                                         (unsigned long long)receiver,
                                         timedOut ? 1 : 0]];

    if (completion) {
        if (receiver) completion(receiver, nil);
        else completion(0, timedOut ? @"捕获窗口结束：目标方法没有被调用" : @"未捕获到有效 receiver");
    }
}

static void ZNM47DobbyPreHandler(void *address, ZNM47DobbyRegisterContextPrefix *ctx) {
    (void)address;
    if (!ctx || !gZNM47CaptureActive.load(std::memory_order_relaxed)) return;
#if defined(__arm64__) || defined(__aarch64__)
    uintptr_t receiver = (uintptr_t)ctx->general.regs.x0;
#else
    uintptr_t receiver = 0;
#endif
    if (!receiver) return;

    uintptr_t expected = 0;
    if (!gZNM47CapturedReceiver.compare_exchange_strong(expected, receiver)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        ZNM47FinishReceiverCapture(NO);
    });
}

BOOL ZNM47ReceiverCaptureBusy(void) {
    return gZNM47CaptureActive.load();
}

BOOL ZNM47StartReceiverCapture(NSDictionary *candidate,
                               NSTimeInterval timeout,
                               ZNM47ReceiverCaptureCompletion completion,
                               NSString **error) {
    uintptr_t methodPointer = [candidate[@"methodPointer"] respondsToSelector:@selector(unsignedLongLongValue)]
        ? [candidate[@"methodPointer"] unsignedLongLongValue]
        : 0;
    if (!methodPointer || (methodPointer & 3ULL)) {
        if (error) *error = @"M4.7：候选没有可安全 instrument 的 arm64 methodPointer";
        return NO;
    }

    bool expected = false;
    if (!gZNM47CaptureActive.compare_exchange_strong(expected, true)) {
        if (error) *error = @"M4.7：已有 receiver 捕获任务正在运行";
        return NO;
    }

    gZNM47CapturedReceiver.store(0);
    gZNM47InstrumentAddress = (void *)methodPointer;
    gZNM47Completion = [completion copy];

    int rc = DobbyInstrument((void *)methodPointer, ZNM47DobbyPreHandler);
    if (rc != 0) {
        gZNM47CaptureActive.store(false);
        gZNM47InstrumentAddress = NULL;
        gZNM47Completion = nil;
        if (error) *error = [NSString stringWithFormat:@"M4.7：DobbyInstrument 失败 rc=%d", rc];
        return NO;
    }

    NSTimeInterval safeTimeout = MAX(0.5, MIN(timeout > 0 ? timeout : 5.0, 15.0));
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m4.7-receiver-capture] armed method=%@ pointer=0x%llX timeout=%.1fs",
                                         candidate[@"method"] ?: @"?",
                                         (unsigned long long)methodPointer,
                                         safeTimeout]];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(safeTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ZNM47FinishReceiverCapture(YES);
    });
    if (error) *error = nil;
    return YES;
}

void ZNM47CancelReceiverCapture(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        ZNM47FinishReceiverCapture(NO);
    });
}
