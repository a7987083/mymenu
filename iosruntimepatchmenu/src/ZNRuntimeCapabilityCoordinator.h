#import <Foundation/Foundation.h>

@class ZNStaticPatchRecord;
@class ZNRuntimeMethodActionRecord;
@class ZNNativeHookAction;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const ZNRuntimeCapabilitySnapshotDidChangeNotification;

@interface ZNRuntimeCapabilitySnapshot : NSObject
@property(nonatomic,copy,readonly) NSArray<ZNStaticPatchRecord *> *staticRecords;
@property(nonatomic,copy,readonly) NSArray<ZNRuntimeMethodActionRecord *> *runtimeMethods;
@property(nonatomic,copy,readonly) NSArray<ZNRuntimeMethodActionRecord *> *directNativeCalls;
@property(nonatomic,copy,readonly) NSArray<ZNNativeHookAction *> *nativeHooks;
@property(nonatomic,assign,readonly) uint64_t generation;
@property(nonatomic,assign,readonly) uint32_t imageCount;
@end

// M6.8.5: single runtime discovery owner.
//
// UI/renderers are consumers only. They may call requestRefresh (O(1) enqueue)
// but must never perform dyld discovery, Runtime Action parsing, IL2CPP resolve,
// or Native Hook installation while rendering.
@interface ZNRuntimeCapabilityCoordinator : NSObject
+ (instancetype)sharedCoordinator;
@property(nonatomic,strong,readonly) ZNRuntimeCapabilitySnapshot *currentSnapshot;
- (void)start;
- (void)requestRefresh;
@end

NS_ASSUME_NONNULL_END
