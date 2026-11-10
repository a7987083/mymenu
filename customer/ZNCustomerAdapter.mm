#import "ZNCustomerAdapter.h"
#import "../iosruntimepatchmenu/src/ZNStaticDispatchRuntime.h"
#import "../iosruntimepatchmenu/src/ZNRuntimeActionRuntime.h"

@implementation ZNCustomerItem
@end

// Static Dispatch is reused verbatim: ownership, atomic target writes and rollback
// stay in the audited developer runtime. Never write executable memory here.
@implementation ZNCustomerAdapter {
    NSDictionary<NSString *, ZNStaticPatchRecord *> *_staticByIdentifier;
    NSDictionary<NSString *, ZNRuntimeMethodActionRecord *> *_methodByIdentifier;
}
+ (instancetype)shared {
    static ZNCustomerAdapter *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [ZNCustomerAdapter new]; });
    return instance;
}
- (NSArray<ZNCustomerItem *> *)snapshot {
    @synchronized(self) {
        ZNStaticDispatchRuntime *runtime=[ZNStaticDispatchRuntime sharedRuntime];
        // Runtime owns the discovery cache and image invalidation. The adapter
        // must not maintain a second, weaker cache keyed only by image count.
        [runtime refresh];
        NSMutableArray<ZNCustomerItem *> *items=[NSMutableArray array];
        NSMutableDictionary<NSString *,ZNStaticPatchRecord *> *mapping=[NSMutableDictionary dictionary];
        for(ZNStaticPatchRecord *record in runtime.records) {
            NSString *identifier=[NSString stringWithFormat:@"static:%@:%u:%llx",
                                  record.target?:@"",record.patchID,(unsigned long long)record.siteRVA];
            if(mapping[identifier])continue;
            mapping[identifier]=record;
            ZNCustomerItem *item=[ZNCustomerItem new];
            item.identifier=identifier;
            item.title=record.title?:@"未命名功能";
            item.detail=record.featureDescription.length?record.featureDescription:(record.group?:@"");
            item.kind=ZNCustomerControlSwitch;
            item.enabled=record.enabled;
            item.minimum=0;item.maximum=1;item.value=record.enabled?1:0;
            [items addObject:item];
        }
        _staticByIdentifier=[mapping copy];
        ZNRuntimeActionRuntime *methods=[ZNRuntimeActionRuntime sharedRuntime];
        [methods refresh];
        NSMutableDictionary<NSString *,ZNRuntimeMethodActionRecord *> *methodMap=[NSMutableDictionary dictionary];
        for(ZNRuntimeMethodActionRecord *record in methods.records) {
            NSString *identifier=[NSString stringWithFormat:@"method:%@:%u",record.sourceImage?:@"",record.actionID];
            if(methodMap[identifier])continue;
            methodMap[identifier]=record;
            ZNCustomerItem *item=[ZNCustomerItem new];
            item.identifier=identifier;
            item.title=record.title.length?record.title:(record.methodName?:@"未命名方法");
            item.detail=record.featureDescription.length?record.featureDescription:(record.group?:@"");
            item.kind=ZNCustomerControlButton;
            item.enabled=NO;
            item.minimum=0;item.maximum=1;item.value=0;
            [items addObject:item];
        }
        _methodByIdentifier=[methodMap copy];
        return items;
    }
}
- (BOOL)setEnabled:(BOOL)enabled identifier:(NSString *)identifier error:(NSString **)error {
    ZNStaticPatchRecord *record=nil;
    @synchronized(self){record=_staticByIdentifier[identifier];}
    if(!record){
        if(error)*error=@"预埋功能不存在或已失效，请重新打开菜单";
        return NO;
    }
    return [[ZNStaticDispatchRuntime sharedRuntime] setEnabled:enabled forRecord:record error:error];
}
- (BOOL)execute:(NSString *)identifier value:(NSNumber *)value error:(NSString **)error {
    (void)value;
    ZNRuntimeMethodActionRecord *record=nil;
    @synchronized(self){record=_methodByIdentifier[identifier];}
    if(!record){
        if(error)*error=@"Runtime Method 不存在或已失效，请重新打开菜单";
        return NO;
    }
    return [[ZNRuntimeActionRuntime sharedRuntime] executeRecord:record error:error];
}
@end
