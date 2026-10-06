#import <Foundation/Foundation.h>

@class ZNNativeHookAction;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZNNativeHookLifecycleState) {
    ZNNativeHookLifecycleStateDiscovered = 0,
    ZNNativeHookLifecycleStatePreparing,
    ZNNativeHookLifecycleStateActive,
    ZNNativeHookLifecycleStateRetryPending,
    ZNNativeHookLifecycleStateFailed,
    ZNNativeHookLifecycleStateTeardown,
};

FOUNDATION_EXPORT NSNotificationName const ZNNativeHookSchedulerStateDidChangeNotification;

// M6.8.6 — Permanent Hook Lifecycle + Prepare Scheduler V1.
//
// Contract:
// - discovery publishes actions;
// - scheduler serializes prepare/install/retry;
// - a successful hook remains installed for the process lifetime;
// - feature controls submit desired state only;
// - OFF/neutral updates atomics and never DobbyDestroy;
// - teardown is explicit diagnostics/development behavior only.
@interface ZNNativeHookScheduler : NSObject
+ (instancetype)sharedScheduler;

- (void)reconcileActions:(NSArray<ZNNativeHookAction *> *)actions;
- (void)setDesiredValue:(NSInteger)value forAction:(ZNNativeHookAction *)action;

// Explicit teardown only. Normal feature OFF must never call this.
- (void)teardownAction:(ZNNativeHookAction *)action;

- (ZNNativeHookLifecycleState)stateForActionID:(uint32_t)actionID;
- (nullable NSString *)lastErrorForActionID:(uint32_t)actionID;
@end

NS_ASSUME_NONNULL_END
