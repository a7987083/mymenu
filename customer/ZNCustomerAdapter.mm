#import "ZNCustomerAdapter.h"
#import "ZNCustomerCatalog.h"
#import "../iosruntimepatchmenu/src/ZNRuntimeActionModel.h"
#include <cmath>
#import "../iosruntimepatchmenu/src/ZNStaticDispatchRuntime.h"
#import "../iosruntimepatchmenu/src/ZNRuntimeActionRuntime.h"

@implementation ZNCustomerItem
@end

// Static Dispatch is reused verbatim: ownership, atomic target writes and rollback
// stay in the audited developer runtime. Never write executable memory here.
@implementation ZNCustomerAdapter {
    NSDictionary<NSString *, ZNStaticPatchRecord *> *_staticByIdentifier;
    NSDictionary<NSString *, ZNRuntimeMethodActionRecord *> *_methodByIdentifier;
    NSDictionary<NSString *, NSNumber *> *_methodArgumentIndex;
    NSMutableDictionary<NSString *, NSNumber *> *_lastControlValues;
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
        NSMutableDictionary<NSString *,NSNumber *> *argumentMap=[NSMutableDictionary dictionary];
        if(!_lastControlValues)_lastControlValues=[NSMutableDictionary dictionary];
        for(ZNRuntimeMethodActionRecord *record in methods.records) {
            NSString *base=[NSString stringWithFormat:@"method:%@:%u:%@",record.sourceImage?:@"",record.actionID,record.canonicalIdentity?:@""];
            NSMutableArray<NSNumber *> *visibleArguments=[NSMutableArray array];
            if(record.argumentControlConfigs.count==record.argumentCount) {
                for(NSUInteger index=0;index<record.argumentCount;index++){
                    NSDictionary *config=record.argumentControlConfigs[index];
                    if(![config isKindOfClass:NSDictionary.class]||![config[@"enabled"] boolValue])continue;
                    NSString *type=[config[@"type"] isKindOfClass:NSString.class]?config[@"type"]:@"fixed";
                    if(![type isEqualToString:@"fixed"])[visibleArguments addObject:@(index)];
                }
            }
            // No explicitly enabled parameter controls: keep one trigger button.
            if(!visibleArguments.count)[visibleArguments addObject:@(NSNotFound)];
            for(NSNumber *indexNumber in visibleArguments) {
                NSUInteger index=indexNumber.unsignedIntegerValue;
                NSString *identifier=index==NSNotFound?base:[base stringByAppendingFormat:@":arg:%lu",(unsigned long)index];
                if(methodMap[identifier])continue;
                methodMap[identifier]=record;
                ZNCustomerItem *item=[ZNCustomerItem new];
                item.identifier=identifier;
                item.title=record.title.length?record.title:(record.methodName?:@"未命名方法");
                item.detail=record.featureDescription.length?record.featureDescription:(record.group?:@"");
                item.kind=ZNCustomerControlButton;
                item.minimum=0;item.maximum=1;item.value=0;item.enabled=NO;
                if(index!=NSNotFound) {
                    argumentMap[identifier]=@(index);
                    NSDictionary *config=record.argumentControlConfigs[index];
                    NSString *type=[config[@"type"] isKindOfClass:NSString.class]?config[@"type"]:@"";
                    if([type isEqualToString:@"switch"])item.kind=ZNCustomerControlSwitch;
                    else if([type isEqualToString:@"slider"])item.kind=ZNCustomerControlSlider;
                    else if([type isEqualToString:@"number"])item.kind=ZNCustomerControlNumber;
                    NSNumber *minimum=[config[@"min"] isKindOfClass:NSNumber.class]?config[@"min"]:@0;
                    NSNumber *maximum=[config[@"max"] isKindOfClass:NSNumber.class]?config[@"max"]:@1;
                    NSNumber *initial=[config[@"default"] isKindOfClass:NSNumber.class]?config[@"default"]:@0;
                    item.minimum=minimum.doubleValue;
                    item.maximum=maximum.doubleValue;
                    NSNumber *current=_lastControlValues[identifier]?:initial;
                    // A method switch is initially OFF; an authored nonzero argument
                    // is the ON payload, not evidence the method was already called.
                    if(item.kind==ZNCustomerControlSwitch) {
                        item.enabled=(_lastControlValues[identifier]?:@NO).boolValue;
                        item.value=item.enabled?1:0;
                    } else {
                        item.value=current.doubleValue;
                        item.enabled=NO;
                    }
                    if(visibleArguments.count>1)item.title=[item.title stringByAppendingFormat:@" · 参数%lu",(unsigned long)index+1];
                }
                [items addObject:item];
            }
        }
        _methodByIdentifier=[methodMap copy];
        _methodArgumentIndex=[argumentMap copy];
        // Native Hook metadata is displayed only; no backend is linked.
        for (ZNCustomerItem *candidate in [ZNCustomerCatalog discover]) {
            if (![candidate.identifier hasPrefix:@"action:"]) continue;
            NSArray<NSString *> *parts=[candidate.identifier componentsSeparatedByString:@":"];
            if (parts.count!=4 || ![parts[2] isEqualToString:@"2"]) continue;
            candidate.identifier=[@"preview:" stringByAppendingString:candidate.identifier];
            candidate.detail=[NSString stringWithFormat:@"%@ · Native Hook（仅显示）",candidate.detail?:@""];
            candidate.kind=ZNCustomerControlSwitch;
            candidate.enabled=NO;
            [items addObject:candidate];
        }
        return items;
    }
}
- (BOOL)setEnabled:(BOOL)enabled identifier:(NSString *)identifier error:(NSString **)error {
    ZNStaticPatchRecord *record=nil;
    @synchronized(self){record=_staticByIdentifier[identifier];}
    if(!record){
        NSNumber *index=nil;
        ZNRuntimeMethodActionRecord *method=nil;
        @synchronized(self){index=_methodArgumentIndex[identifier];method=_methodByIdentifier[identifier];}
        if(index&&method){
            // ON invokes the authored parameter; OFF invokes zero by design.
            // Do not confuse the UI toggle boolean with the method argument.
            NSUInteger argumentIndex=index.unsignedIntegerValue;
            NSString *onValue=argumentIndex<method.argumentValues.count?
                method.argumentValues[argumentIndex]:nil;
            if(enabled && !onValue.length){
                if(error)*error=@"开关缺少开发端预埋的开启参数";
                return NO;
            }
            NSString *argumentValue=enabled?onValue:@"0";
            BOOL success=[[ZNRuntimeActionRuntime sharedRuntime] executeRecord:method argumentIndex:argumentIndex value:argumentValue error:error];
            if(success)@synchronized(self){_lastControlValues[identifier]=@(enabled);}
            return success;
        }
        if(error)*error=[identifier hasPrefix:@"preview:"]?@"Native Hook 仅支持显示，执行器尚未接入":@"预埋功能不存在或已失效，请重新打开菜单";
        return NO;
    }
    return [[ZNStaticDispatchRuntime sharedRuntime] setEnabled:enabled forRecord:record error:error];
}
- (BOOL)execute:(NSString *)identifier value:(NSNumber *)value error:(NSString **)error {
    ZNRuntimeMethodActionRecord *record=nil;
    NSNumber *index=nil;
    @synchronized(self){record=_methodByIdentifier[identifier];index=_methodArgumentIndex[identifier];}
    if(!record){
        if(error)*error=@"Runtime Method 不存在或已失效，请重新打开菜单";
        return NO;
    }
    if(!index)return [[ZNRuntimeActionRuntime sharedRuntime] executeRecord:record error:error];
    if(!value){
        // Button controls retain their authored argument value.
        return [[ZNRuntimeActionRuntime sharedRuntime] executeRecord:record error:error];
    }
    if(!std::isfinite(value.doubleValue)){
        if(error)*error=@"数值必须是有限数";
        return NO;
    }
    NSDictionary *config=record.argumentControlConfigs[index.unsignedIntegerValue];
    double min=[config[@"min"] doubleValue],max=[config[@"max"] doubleValue];
    if(value.doubleValue<min||value.doubleValue>max){
        if(error)*error=[NSString stringWithFormat:@"数值超出范围：%.6g ~ %.6g",min,max];
        return NO;
    }
    NSString *valueText=[value stringValue];
    BOOL success=[[ZNRuntimeActionRuntime sharedRuntime] executeRecord:record argumentIndex:index.unsignedIntegerValue value:valueText error:error];
    if(success)@synchronized(self){_lastControlValues[identifier]=value;}
    return success;
}
@end
