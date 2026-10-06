#import "ZNCapabilityRegistry.h"

static void *kZNCapabilityRegistryQueueKey=&kZNCapabilityRegistryQueueKey;

@interface ZNCapabilityRegistry ()
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) NSMutableDictionary<NSString *,id<ZNRuntimeCapabilityAdapter>> *adapters;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *states;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *preparedImageCounts;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSString *> *errors;
@end

@implementation ZNCapabilityRegistry
+ (instancetype)sharedRegistry {
    static ZNCapabilityRegistry *registry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ registry=[ZNCapabilityRegistry new]; });
    return registry;
}
- (instancetype)init {
    self=[super init];
    if(!self)return nil;
    _queue=dispatch_queue_create("com.zonoe.capability.registry",DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue,kZNCapabilityRegistryQueueKey,kZNCapabilityRegistryQueueKey,NULL);
    _adapters=[NSMutableDictionary dictionary];
    _states=[NSMutableDictionary dictionary];
    _preparedImageCounts=[NSMutableDictionary dictionary];
    _errors=[NSMutableDictionary dictionary];
    return self;
}
- (void)zn_sync:(dispatch_block_t)block {
    if(dispatch_get_specific(kZNCapabilityRegistryQueueKey))block();
    else dispatch_sync(self.queue,block);
}
- (void)registerAdapter:(id<ZNRuntimeCapabilityAdapter>)adapter {
    if(!adapter.capabilityIdentifier.length)return;
    [self zn_sync:^{
        NSString *identifier=[adapter.capabilityIdentifier copy];
        self.adapters[identifier]=adapter;
        if(!self.states[identifier])self.states[identifier]=@(ZNCapabilityLifecycleStateRegistered);
    }];
}
- (id<ZNRuntimeCapabilityAdapter>)adapterForIdentifier:(NSString *)identifier {
    if(!identifier.length)return nil;
    __block id<ZNRuntimeCapabilityAdapter> adapter=nil;
    [self zn_sync:^{ adapter=self.adapters[identifier]; }];
    return adapter;
}
- (NSArray<id<ZNRuntimeCapabilityAdapter>> *)adaptersSnapshot {
    __block NSArray *snapshot=nil;
    [self zn_sync:^{
        snapshot=[[self.adapters allValues] sortedArrayUsingComparator:^NSComparisonResult(id<ZNRuntimeCapabilityAdapter> a,id<ZNRuntimeCapabilityAdapter> b){
            return [a.capabilityIdentifier compare:b.capabilityIdentifier];
        }];
    }];
    return snapshot?:@[];
}
- (BOOL)zn_prepareAdapter:(id<ZNRuntimeCapabilityAdapter>)adapter imageCount:(uint32_t)imageCount error:(NSString **)error {
    NSString *identifier=adapter.capabilityIdentifier;
    NSNumber *prepared=self.preparedImageCounts[identifier];
    if(prepared && prepared.unsignedIntValue==imageCount &&
       [self.states[identifier] integerValue]==ZNCapabilityLifecycleStatePrepared) return YES;

    self.states[identifier]=@(ZNCapabilityLifecycleStatePreparing);
    NSString *inner=nil;
    BOOL ok=[adapter prepareForImageCount:imageCount error:&inner];
    if(ok){
        self.preparedImageCounts[identifier]=@(imageCount);
        self.states[identifier]=@(ZNCapabilityLifecycleStatePrepared);
        [self.errors removeObjectForKey:identifier];
        return YES;
    }
    self.states[identifier]=@(ZNCapabilityLifecycleStateFailed);
    self.errors[identifier]=inner?:@"Capability prepare failed";
    if(error)*error=self.errors[identifier];
    return NO;
}
- (BOOL)prepareCapability:(NSString *)identifier imageCount:(uint32_t)imageCount error:(NSString **)error {
    if(!identifier.length){
        if(error)*error=@"Capability identifier 为空";
        return NO;
    }
    __block BOOL ok=NO;
    __block NSString *inner=nil;
    [self zn_sync:^{
        id<ZNRuntimeCapabilityAdapter> adapter=self.adapters[identifier];
        if(!adapter){
            inner=[NSString stringWithFormat:@"Capability 未注册: %@",identifier];
            return;
        }
        ok=[self zn_prepareAdapter:adapter imageCount:imageCount error:&inner];
    }];
    if(!ok&&error)*error=inner;
    return ok;
}
- (BOOL)prepareAllForImageCount:(uint32_t)imageCount error:(NSString **)error {
    __block BOOL allOK=YES;
    __block NSString *firstError=nil;
    [self zn_sync:^{
        NSArray *adapters=[[self.adapters allValues] sortedArrayUsingComparator:^NSComparisonResult(id<ZNRuntimeCapabilityAdapter> a,id<ZNRuntimeCapabilityAdapter> b){
            return [a.capabilityIdentifier compare:b.capabilityIdentifier];
        }];
        for(id<ZNRuntimeCapabilityAdapter> adapter in adapters){
            NSString *inner=nil;
            if(![self zn_prepareAdapter:adapter imageCount:imageCount error:&inner]){
                allOK=NO;
                if(!firstError)firstError=inner;
            }
        }
    }];
    if(!allOK&&error)*error=firstError;
    return allOK;
}
- (ZNCapabilityLifecycleState)stateForIdentifier:(NSString *)identifier {
    __block NSInteger state=ZNCapabilityLifecycleStateRegistered;
    [self zn_sync:^{ state=[self.states[identifier] integerValue]; }];
    return (ZNCapabilityLifecycleState)state;
}
- (NSString *)lastErrorForIdentifier:(NSString *)identifier {
    __block NSString *value=nil;
    [self zn_sync:^{ value=self.errors[identifier]; }];
    return value;
}
- (uint32_t)preparedImageCountForIdentifier:(NSString *)identifier {
    __block uint32_t value=0;
    [self zn_sync:^{ value=[self.preparedImageCounts[identifier] unsignedIntValue]; }];
    return value;
}
@end
