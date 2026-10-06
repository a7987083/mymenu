#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// M6.8.6 Hook-only early lifecycle bootstrap.
//
// This component intentionally owns only Native Hook discovery/prepare.
// Static Patch and Runtime Method retain their existing deferred/menu lifecycle.
@interface ZNNativeHookLifecycleBootstrap : NSObject
+ (instancetype)sharedBootstrap;
- (void)start;
- (void)requestReconcile;
@end

NS_ASSUME_NONNULL_END
