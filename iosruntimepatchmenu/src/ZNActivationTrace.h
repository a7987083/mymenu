#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// v0.5.6.2 sealed build: activation tracing is disabled. Keep trace arguments
// in a compile-time-dead branch so diagnostic-only locals remain warning-clean,
// while the optimizer removes the branch and emits no logging/file I/O.
#define ZNActivationTraceLog(...) do { if (0) { (void)(__VA_ARGS__); } } while (0)
#define ZNActivationTraceLogPath() @""

static inline double ZNActivationTraceNow(void) {
    return CFAbsoluteTimeGetCurrent();
}

NS_ASSUME_NONNULL_END
