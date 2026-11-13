#import "ZNCustomerAdapter.h"
#import "ZNCustomerCatalog.h"
#import "../iosruntimepatchmenu/src/ZNRuntimeActionModel.h"
#include <cmath>
#import "../iosruntimepatchmenu/src/ZNStaticDispatchRuntime.h"
#import "../iosruntimepatchmenu/src/ZNRuntimeActionRuntime.h"
#import "../iosruntimepatchmenu/src/ZNRuntimeActionFormat.h"
#import "../iosruntimepatchmenu/src/ZNDirectNativeCallEngine.h"
#import "../iosruntimepatchmenu/src/ZNIL2CPPHybridFinder.h"
#import "../iosruntimepatchmenu/src/ZNIL2CPPMethodSignature.h"

@implementation ZNCustomerItem
@end

// Do not route Direct Native Call through runtime_invoke: it uses a distinct ABI.
static BOOL ZNCustomerExecuteMethodRecord(ZNRuntimeMethodActionRecord *record,
                                          NSUInteger argumentIndex,
                                          NSString *overrideValue,
                                          NSString **error) {
    if (!record) { if(error)*error=@"Runtime Action 不存在"; return NO; }
    if(record.executionKind==ZNRuntimeActionKindIL2CPPMethodCall)
        return [[ZNRuntimeActionRuntime sharedRuntime] executeRecord:record
                                                       argumentIndex:argumentIndex
                                                               value:overrideValue
                                                               error:error];
    if(record.executionKind!=ZNRuntimeActionKindDirectNativeCall){
        if(error)*error=@"不支持的 Runtime Action 类型"; return NO;
    }
    NSMutableArray<NSString *> *values=[record.argumentValues mutableCopy]?:[NSMutableArray array];
    if(values.count!=record.argumentCount){
        if(error)*error=@"Direct Native Call 预埋参数数量不一致"; return NO;
    }
    if(argumentIndex!=NSNotFound){
        if(argumentIndex>=values.count||!overrideValue){
            if(error)*error=@"Direct Native Call 参数索引无效"; return NO;
        }
        values[argumentIndex]=overrideValue;
    }
    NSString *owner=record.namespaceName.length
        ? [NSString stringWithFormat:@"%@.%@",record.namespaceName,record.className]
        : record.className;
    NSString *expression=[NSString stringWithFormat:@"%@!%@::%@/%lu",
        record.assembly,owner,record.methodName,(unsigned long)record.argumentCount];
    NSString *resolveError=nil;
    NSDictionary *candidate=[[ZNIL2CPPHybridFinder sharedFinder] resolveExpression:expression error:&resolveError];
    if(!candidate){if(error)*error=resolveError?:@"Direct Native Call 无法解析目标方法";return NO;}
    NSDictionary *expected=@{@"assembly":record.assembly?:@"",
                             @"namespace":record.namespaceName?:@"",
                             @"class":record.className?:@"",
                             @"method":record.methodName?:@""};
    for(NSString *key in expected){
        NSString *actual=[candidate[key] isKindOfClass:NSString.class]?candidate[key]:@"";
        if(![actual isEqualToString:expected[key]]){
            if(error)*error=[NSString stringWithFormat:@"Direct Native Call 方法身份不匹配：%@",key];
            return NO;
        }
    }
    if([candidate[@"argumentCount"] unsignedIntegerValue]!=record.argumentCount){
        if(error)*error=@"Direct Native Call 参数数量与 Runtime 元数据不匹配"; return NO;
    }
    if(record.signatureAvailable){
        NSString *signatureError=nil;
        NSArray<NSString *> *types=ZNIL2CPPParameterTypeNamesForCandidate(candidate,&signatureError);
        if(!types||![types isEqualToArray:record.parameterTypeNames]){
            if(error)*error=signatureError?:@"Direct Native Call 参数签名与目标版本不匹配";
            return NO;
        }
    }
    NSString *abiError=nil;
    if(![[ZNDirectNativeCallEngine sharedEngine] supportsCandidate:candidate reason:&abiError]){
        if(error)*error=abiError?:@"Direct Native Call ABI 不支持"; return NO;
    }
    return [[ZNDirectNativeCallEngine sharedEngine] executeCandidate:candidate
                                                       argumentValues:values error:error]!=nil;
}

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
        NSMutableArray<ZNRuntimeMethodActionRecord *> *allMethodActions=[NSMutableArray arrayWithArray:methods.records?:@[]];
        [allMethodActions addObjectsFromArray:methods.directRecords?:@[]];
        for(ZNRuntimeMethodActionRecord *record in allMethodActions) {
            NSString *prefix=record.executionKind==ZNRuntimeActionKindDirectNativeCall?@"direct":@"method";
            NSString *base=[NSString stringWithFormat:@"%@:%@:%u:%@",prefix,record.sourceImage?:@"",record.actionID,record.canonicalIdentity?:@""];
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
            BOOL success=ZNCustomerExecuteMethodRecord(method,argumentIndex,argumentValue,error);
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
    if(!index)return ZNCustomerExecuteMethodRecord(record,NSNotFound,nil,error);
    if(!value){
        // Button controls retain their authored argument value.
        return ZNCustomerExecuteMethodRecord(record,NSNotFound,nil,error);
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
    BOOL success=ZNCustomerExecuteMethodRecord(record,index.unsignedIntegerValue,valueText,error);
    if(success)@synchronized(self){_lastControlValues[identifier]=value;}
    return success;
}
@end
