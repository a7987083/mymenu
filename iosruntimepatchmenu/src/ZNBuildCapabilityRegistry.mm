#import "ZNBuildCapabilityRegistry.h"
#import "ZNBinaryPatchWorkspace.h"
#import "ZNRuntimeActionModel.h"
#import "ZNNativeHookAction.h"
#import "ZNBuildManifest.h"

@interface ZNBuildCapabilityRegistry ()
@property(nonatomic,strong) NSMutableDictionary<NSString *, ZNBuildCapabilityProbe> *providers;
@property(nonatomic,assign) BOOL builtinsInstalled;
@end

@implementation ZNBuildCapabilityRegistry

+ (instancetype)sharedRegistry {
    static ZNBuildCapabilityRegistry *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry=[ZNBuildCapabilityRegistry new]; });
    [registry installBuiltinsIfNeeded];
    return registry;
}

- (instancetype)init {
    self=[super init];
    if(!self)return nil;
    _providers=[NSMutableDictionary dictionary];
    return self;
}

- (void)installBuiltinsIfNeeded {
    @synchronized(self) {
        if(self.builtinsInstalled)return;
        self.builtinsInstalled=YES;

        // Built-ins are registered exactly like future capabilities. UI never
        // needs to know which concrete stores exist.
        self.providers[@"static-patch"] = [^BOOL{
            return [ZNBinaryPatchWorkspace sharedWorkspace].filledCount > 0;
        } copy];
        self.providers[@"runtime-method-call"] = [^BOOL{
            return [ZNRuntimeActionStore sharedStore].actionsSnapshot.count > 0;
        } copy];
        self.providers[@"native-hook"] = [^BOOL{
            return [ZNNativeHookStore sharedStore].actionsSnapshot.count > 0;
        } copy];
    }
}

- (void)registerProviderIdentifier:(NSString *)identifier
             hasBuildableContent:(ZNBuildCapabilityProbe)probe {
    NSString *key=[identifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!key.length||!probe)return;
    @synchronized(self){ self.providers[key]=[probe copy]; }
}

- (void)unregisterProviderIdentifier:(NSString *)identifier {
    if(!identifier.length)return;
    @synchronized(self){ [self.providers removeObjectForKey:identifier]; }
}

- (NSArray<NSString *> *)activeProviderIdentifiers {
    NSMutableArray<NSString *> *active=[NSMutableArray array];
    NSDictionary<NSString *,ZNBuildCapabilityProbe> *snapshot=nil;
    @synchronized(self){ snapshot=[self.providers copy]; }
    NSArray<NSString *> *keys=[[snapshot allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for(NSString *key in keys){
        ZNBuildCapabilityProbe probe=snapshot[key];
        BOOL ready=NO;
        @try { ready=probe ? probe() : NO; }
        @catch(__unused NSException *exception) { ready=NO; }
        if(ready)[active addObject:key];
    }
    return [active copy];
}

- (BOOL)hasBuildableContent {
    return self.activeProviderIdentifiers.count > 0;
}

@end

@implementation ZNBinaryBuildCoordinator

+ (instancetype)sharedCoordinator {
    static ZNBinaryBuildCoordinator *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ coordinator=[ZNBinaryBuildCoordinator new]; });
    return coordinator;
}

- (NSArray<NSString *> *)activeProviderIdentifiers {
    ZNBinaryPatchWorkspace *workspace=[ZNBinaryPatchWorkspace sharedWorkspace];
    return [ZNBuildManifest manifestForWorkspace:workspace].activeProviderIdentifiers;
}

- (BOOL)canBuild {
    ZNBinaryPatchWorkspace *workspace=[ZNBinaryPatchWorkspace sharedWorkspace];
    if(workspace.isBuilding)return NO;
    if(workspace.hasAnyApplied)return NO;
    return [ZNBuildManifest manifestForWorkspace:workspace].itemCount > 0;
}

- (NSString *)blockedReason {
    ZNBinaryPatchWorkspace *workspace=[ZNBinaryPatchWorkspace sharedWorkspace];
    if(workspace.isBuilding)return @"正在生成二进制";
    if(workspace.hasAnyApplied)return @"生成前必须先恢复 Runtime Patch";
    if([ZNBuildManifest manifestForWorkspace:workspace].itemCount==0)return @"没有可生成的 BuildItem";
    return @"";
}

@end

void ZNRegisterBuildCapabilityProvider(NSString *identifier, ZNBuildCapabilityProbe probe) {
    [[ZNBuildCapabilityRegistry sharedRegistry] registerProviderIdentifier:identifier hasBuildableContent:probe];
}

void ZNUnregisterBuildCapabilityProvider(NSString *identifier) {
    [[ZNBuildCapabilityRegistry sharedRegistry] unregisterProviderIdentifier:identifier];
}
