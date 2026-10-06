#import "ZNRuntimeCapabilityCoordinator.h"

#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>

#import "ZNStaticDispatchRuntime.h"
#import "ZNRuntimeActionRuntime.h"
#import "ZNNativeHookAction.h"
#import "ZNCapabilityRegistry.h"
#import "ZNBuiltInCapabilityAdapters.h"
#import "ZNPatchCore.h"

NSNotificationName const ZNRuntimeCapabilitySnapshotDidChangeNotification =
    @"ZNRuntimeCapabilitySnapshotDidChangeNotification";

@interface ZNRuntimeCapabilitySnapshot ()
@property(nonatomic,copy,readwrite) NSArray<ZNStaticPatchRecord *> *staticRecords;
@property(nonatomic,copy,readwrite) NSArray<ZNRuntimeMethodActionRecord *> *runtimeMethods;
@property(nonatomic,copy,readwrite) NSArray<ZNRuntimeMethodActionRecord *> *directNativeCalls;
@property(nonatomic,copy,readwrite) NSArray<ZNNativeHookAction *> *nativeHooks;
@property(nonatomic,assign,readwrite) uint64_t generation;
@property(nonatomic,assign,readwrite) uint32_t imageCount;
@end

@implementation ZNRuntimeCapabilitySnapshot
@end

@interface ZNRuntimeCapabilityCoordinator ()
@property(nonatomic,strong) dispatch_queue_t discoveryQueue;
@property(nonatomic,strong) ZNRuntimeCapabilitySnapshot *snapshotStorage;
@property(nonatomic,assign) BOOL started;
@property(nonatomic,assign) BOOL refreshScheduled;
@property(nonatomic,assign) BOOL refreshRequested;
@property(nonatomic,assign) uint64_t nextGeneration;
@end

static void ZNRuntimeCapabilityImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh;
    (void)slide;
    [[ZNRuntimeCapabilityCoordinator sharedCoordinator] requestRefresh];
}

@implementation ZNRuntimeCapabilityCoordinator

+ (instancetype)sharedCoordinator {
    static ZNRuntimeCapabilityCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator=[ZNRuntimeCapabilityCoordinator new];
    });
    return coordinator;
}

- (instancetype)init {
    self=[super init];
    if(!self)return nil;
    _discoveryQueue=dispatch_queue_create("com.zonoe.runtime-capability.discovery",DISPATCH_QUEUE_SERIAL);
    ZNRuntimeCapabilitySnapshot *empty=[ZNRuntimeCapabilitySnapshot new];
    empty.staticRecords=@[];
    empty.runtimeMethods=@[];
    empty.directNativeCalls=@[];
    empty.nativeHooks=@[];
    empty.generation=0;
    empty.imageCount=0;
    _snapshotStorage=empty;
    _nextGeneration=1;
    ZNRegisterBuiltInCapabilityAdapters();
    return self;
}

- (ZNRuntimeCapabilitySnapshot *)currentSnapshot {
    @synchronized(self) {
        return self.snapshotStorage;
    }
}

- (void)start {
    @synchronized(self) {
        if(self.started)return;
        self.started=YES;
    }

    // Register once. dyld invokes the callback for currently loaded images too;
    // requestRefresh coalesces those callbacks into one serial discovery pass.
    _dyld_register_func_for_add_image(ZNRuntimeCapabilityImageAdded);

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(zn_applicationBecameActive:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
    [self requestRefresh];
    [[ZNRuntimeLogger sharedLogger] log:@"[runtime-capability] coordinator started; UI is snapshot-only"];
}

- (void)zn_applicationBecameActive:(NSNotification *)note {
    (void)note;
    [self requestRefresh];
}

- (void)requestRefresh {
    uint32_t imageCount=_dyld_image_count();
    @synchronized(self) {
        // O(1) fast path for UI callers. dyld add-image changes imageCount,
        // so a stable count means the published immutable snapshot is current.
        if(self.snapshotStorage.generation>0 &&
           self.snapshotStorage.imageCount==imageCount &&
           !self.refreshScheduled) return;
        self.refreshRequested=YES;
        if(self.refreshScheduled)return;
        self.refreshScheduled=YES;
    }

    __weak typeof(self) weakSelf=self;
    dispatch_async(self.discoveryQueue, ^{
        typeof(self) self=weakSelf;
        if(!self)return;

        for(;;){
            @synchronized(self) {
                self.refreshRequested=NO;
            }

            uint32_t beforeCount=_dyld_image_count();
            double startedAt=CFAbsoluteTimeGetCurrent();

            ZNCapabilityRegistry *registry=[ZNCapabilityRegistry sharedRegistry];
            NSString *prepareError=nil;
            BOOL prepared=[registry prepareAllForImageCount:beforeCount error:&prepareError];

            id<ZNRuntimeCapabilityAdapter> staticAdapter=[registry adapterForIdentifier:ZNCapabilityStaticPatchIdentifier];
            id<ZNRuntimeCapabilityAdapter> methodAdapter=[registry adapterForIdentifier:ZNCapabilityRuntimeMethodIdentifier];
            id<ZNRuntimeCapabilityAdapter> hookAdapter=[registry adapterForIdentifier:ZNCapabilityNativeHookIdentifier];
            id<ZNRuntimeCapabilityAdapter> directAdapter=[registry adapterForIdentifier:ZNCapabilityDirectNativeCallIdentifier];

            ZNRuntimeCapabilitySnapshot *snapshot=[ZNRuntimeCapabilitySnapshot new];
            snapshot.staticRecords=(NSArray<ZNStaticPatchRecord *> *)[[staticAdapter snapshotItems] copy] ?: @[];
            snapshot.runtimeMethods=(NSArray<ZNRuntimeMethodActionRecord *> *)[[methodAdapter snapshotItems] copy] ?: @[];
            snapshot.directNativeCalls=(NSArray<ZNRuntimeMethodActionRecord *> *)[[directAdapter snapshotItems] copy] ?: @[];
            snapshot.nativeHooks=(NSArray<ZNNativeHookAction *> *)[[hookAdapter snapshotItems] copy] ?: @[];
            snapshot.imageCount=_dyld_image_count();

            @synchronized(self) {
                snapshot.generation=self.nextGeneration++;
                self.snapshotStorage=snapshot;
            }

            double elapsed=(CFAbsoluteTimeGetCurrent()-startedAt)*1000.0;
            [[ZNRuntimeLogger sharedLogger] log:
             [NSString stringWithFormat:@"[runtime-capability] snapshot gen=%llu images=%u static=%lu runtime=%lu direct=%lu hooks=%lu %.2fms thread=%@",
              snapshot.generation,
              snapshot.imageCount,
              (unsigned long)snapshot.staticRecords.count,
              (unsigned long)snapshot.runtimeMethods.count,
              (unsigned long)snapshot.directNativeCalls.count,
              (unsigned long)snapshot.nativeHooks.count,
              elapsed,
              NSThread.isMainThread ? @"main" : @"background"]];
            if(!prepared){
                [[ZNRuntimeLogger sharedLogger] log:
                 [NSString stringWithFormat:@"[runtime-capability] prewarm partial failure: %@",prepareError?:@"unknown"]];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter
                    postNotificationName:ZNRuntimeCapabilitySnapshotDidChangeNotification
                                  object:self];
            });

            BOOL rerun=NO;
            @synchronized(self) {
                rerun=self.refreshRequested || (_dyld_image_count()!=beforeCount);
                if(!rerun)self.refreshScheduled=NO;
            }
            if(!rerun)break;
        }
    });
}

@end
