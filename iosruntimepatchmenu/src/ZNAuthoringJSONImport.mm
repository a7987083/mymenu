#import "ZNAuthoringJSONImport.h"
#import "ZNRuntimeActionModel.h"
#import "ZNNativeHookAction.h"
#import "ZNIL2CPPResolver.h"
#import "ZNIL2CPPMethodSignature.h"

static NSDictionary *ZNPortableRuntimeRecord(ZNRuntimeMethodAction *a) {
    return @{
        @"title":a.title?:@"", @"description":a.featureDescription?:@"",
        @"group":a.group?:@"Runtime Methods", @"executionKind":@(a.executionKind),
        @"assembly":a.assembly?:@"Assembly-CSharp.dll",
        @"namespace":a.namespaceName?:@"", @"class":a.className?:@"",
        @"method":a.methodName?:@"", @"argumentCount":@(a.argumentCount),
        @"parameterTypeNames":a.parameterTypeNames?:@[],
        @"signatureAvailable":@(a.signatureAvailable),
        @"argumentValues":a.argumentValues?:@[],
        @"argumentControlConfigs":a.argumentControlConfigs?:@[],
        @"immediateChain":a.immediateChain?:@{}
    };
}
static NSDictionary *ZNPortableNativeRecord(ZNNativeHookAction *a) {
    return @{
        @"actionID":@(a.actionID), @"title":a.title?:@"",
        @"group":a.group?:@"Native Hooks", @"description":a.featureDescription?:@"",
        @"assembly":a.assembly?:@"Assembly-CSharp.dll",
        @"namespace":a.namespaceName?:@"", @"class":a.className?:@"",
        @"method":a.methodName?:@"", @"argumentCount":@(a.argumentCount),
        @"parameterTypeNames":a.parameterTypeNames?:@[],
        @"signatureAvailable":@(a.signatureAvailable),
        @"templateKind":@(a.templateKind), @"argumentIndex":@(a.argumentIndex),
        @"min":@(a.minValue), @"max":@(a.maxValue), @"default":@(a.defaultValue),
        @"callbackArgumentIndex":@(a.callbackArgumentIndex==NSNotFound?NSUIntegerMax:a.callbackArgumentIndex),
        @"callbackValue":@(a.callbackValue), @"skipOriginal":@(a.skipOriginal),
        @"returnBoolValue":@(a.returnBoolValue),
        @"fieldArgumentIndex":@(a.fieldArgumentIndex==NSNotFound?NSUIntegerMax:a.fieldArgumentIndex),
        @"fieldArgumentMode":a.fieldArgumentMode?:@"indirect-pointer",
        @"fieldOffset":@(a.fieldOffset), @"fieldCodec":a.fieldCodec?:@"",
        @"codecAssembly":a.codecAssembly?:@"", @"codecNamespace":a.codecNamespaceName?:@"",
        @"codecClass":a.codecClassName?:@"", @"codecGetterMethod":a.codecGetterMethod?:@"",
        @"codecSetterMethod":a.codecSetterMethod?:@"",
        @"codecGetterArgumentCount":@(a.codecGetterArgumentCount),
        @"codecSetterArgumentCount":@(a.codecSetterArgumentCount)
    };
}

@implementation ZNAuthoringJSONImport

+ (NSData *)exportDataWithError:(NSString **)error {
    NSArray<ZNRuntimeMethodAction *> *methods=[[ZNRuntimeActionStore sharedStore] actionsSnapshot];
    NSArray<ZNNativeHookAction *> *hooks=[[ZNNativeHookStore sharedStore] actionsSnapshot];
    if(!methods.count&&!hooks.count){
        if(error)*error=@"没有可导出的 Runtime Method 或 Native Hook";
        return nil;
    }
    if(methods.count>256||hooks.count>256){
        if(error)*error=@"配置数量超过导入器的 256 条限制";
        return nil;
    }
    NSMutableArray *runtime=[NSMutableArray arrayWithCapacity:methods.count];
    NSMutableArray *native=[NSMutableArray arrayWithCapacity:hooks.count];
    for(ZNRuntimeMethodAction *a in methods)[runtime addObject:ZNPortableRuntimeRecord(a)];
    for(ZNNativeHookAction *a in hooks)[native addObject:ZNPortableNativeRecord(a)];
    NSDictionary *root=@{@"format":@"zonoe-authoring",
                          @"schemaVersion":@1,
                          @"runtimeMethods":runtime, @"nativeHooks":native};
    NSError *jsonError=nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:&jsonError];
    if(!data&&error)*error=jsonError.localizedDescription?:@"JSON 序列化失败";
    return data;
}

+ (BOOL)isAuthoringConfiguration:(id)root {
    return [root isKindOfClass:NSDictionary.class] &&
        [root[@"format"] isKindOfClass:NSString.class] &&
        [root[@"format"] isEqualToString:@"zonoe-authoring"];
}

+ (BOOL)importData:(NSData *)data status:(NSString **)status error:(NSString **)error {
    NSError *jsonError=nil;
    id decoded=[NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if(![self isAuthoringConfiguration:decoded]){
        if(error)*error=jsonError.localizedDescription?:@"不是受支持的 Zonoe Authoring JSON";
        return NO;
    }
    NSDictionary *root=(NSDictionary *)decoded;
    if(![root[@"schemaVersion"] isKindOfClass:NSNumber.class]||
       [root[@"schemaVersion"] integerValue]!=1){
        if(error)*error=@"不支持的配置 Schema 版本";
        return NO;
    }
    NSArray *methods=root[@"runtimeMethods"]?:@[];
    NSArray *hooks=root[@"nativeHooks"]?:@[];
    if(![methods isKindOfClass:NSArray.class]||![hooks isKindOfClass:NSArray.class]||
       (!methods.count&&!hooks.count)||methods.count>256||hooks.count>256){
        if(error)*error=@"配置列表为空、类型错误或数量超过 256";
        return NO;
    }

    ZNRuntimeActionStore *store=[ZNRuntimeActionStore sharedStore];
    ZNNativeHookStore *hookStore=[ZNNativeHookStore sharedStore];
    ZNIL2CPPResolver *resolver=[ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    if(!resolver.available){
        if(error)*error=@"IL2CPP 尚未就绪，无法自动验证目标方法；未导入";
        return NO;
    }
    NSMutableSet<NSString *> *existingMethods=[NSMutableSet set];
    for(ZNRuntimeMethodAction *a in [store actionsSnapshot])
        [existingMethods addObject:[NSString stringWithFormat:@"%@|%@|%@|%@|%lu",a.assembly?:@"",a.namespaceName?:@"",a.className?:@"",a.methodName?:@"",(unsigned long)a.argumentCount]];
    NSMutableSet<NSString *> *existingHooks=[NSMutableSet set];
    for(ZNNativeHookAction *a in [hookStore actionsSnapshot])
        [existingHooks addObject:[NSString stringWithFormat:@"%@|%u|%lu|%lu",a.canonicalIdentity?:@"",
            (unsigned)a.templateKind,(unsigned long)a.argumentIndex,(unsigned long)a.fieldArgumentIndex]];

    // Preflight every record BEFORE adding anything. No silent partial import.
    NSMutableSet<NSString *> *pendingMethods=[NSMutableSet set],*pendingHooks=[NSMutableSet set];
    for(id obj in methods){
        if(![obj isKindOfClass:NSDictionary.class]){
            if(error)*error=@"Runtime Method 条目不是对象";
            return NO;
        }
        NSDictionary *d=obj;
        NSString *assembly=[d[@"assembly"] isKindOfClass:NSString.class]?d[@"assembly"]:@"Assembly-CSharp.dll";
        NSString *ns=[d[@"namespace"] isKindOfClass:NSString.class]?d[@"namespace"]:@"";
        NSString *cls=[d[@"class"] isKindOfClass:NSString.class]?d[@"class"]:@"";
        NSString *method=[d[@"method"] isKindOfClass:NSString.class]?d[@"method"]:@"";
        NSNumber *argc=d[@"argumentCount"];
        if(!cls.length||!method.length||![argc isKindOfClass:NSNumber.class]||argc.integerValue<0||argc.integerValue>8||
           ![d[@"argumentValues"] isKindOfClass:NSArray.class]||
           [d[@"argumentValues"] count]!=(NSUInteger)argc.integerValue||
           ![d[@"argumentControlConfigs"] isKindOfClass:NSArray.class]||
           [d[@"argumentControlConfigs"] count]!=(NSUInteger)argc.integerValue){
            if(error)*error=[NSString stringWithFormat:@"Runtime 参数配置非法：%@::%@",cls,method];
            return NO;
        }
        for(id value in d[@"argumentValues"])if(![value isKindOfClass:NSString.class]){
            if(error)*error=@"Runtime 参数值必须是字符串";
            return NO;
        }
        for(id control in d[@"argumentControlConfigs"])if(![control isKindOfClass:NSDictionary.class]){
            if(error)*error=@"Runtime 控件配置必须是对象";
            return NO;
        }
        for(NSDictionary *config in d[@"argumentControlConfigs"]){
            NSString *type=[config[@"type"] isKindOfClass:NSString.class]?config[@"type"]:@"";
            if(![@[@"fixed",@"switch",@"button",@"number",@"slider"] containsObject:type]){
                if(error)*error=@"Runtime 控件类型不支持";return NO;
            }
        }
        id chain=d[@"immediateChain"];
        if(chain && ![chain isKindOfClass:NSDictionary.class]){
            if(error)*error=@"Immediate Chain 类型无效";return NO;
        }
        if([chain isKindOfClass:NSDictionary.class] && [chain count]){
            NSString *chainClass=chain[@"class"],*chainMethod=chain[@"method"];
            NSNumber *chainArgc=chain[@"argumentCount"];
            if(![chainClass isKindOfClass:NSString.class]||!chainClass.length||
               ![chainMethod isKindOfClass:NSString.class]||!chainMethod.length||
               ![chainArgc isKindOfClass:NSNumber.class]||chainArgc.integerValue<0||chainArgc.integerValue>8){
                if(error)*error=@"Immediate Chain 描述符无效";return NO;
            }
        }
        NSString *key=[NSString stringWithFormat:@"%@|%@|%@|%@|%@",assembly,ns,cls,method,argc];
        if([existingMethods containsObject:key] || [pendingMethods containsObject:key]){
            if(error)*error=[NSString stringWithFormat:@"Runtime 方法已存在或 JSON 重复：%@",key];
            return NO;
        }
        [pendingMethods addObject:key];
        NSArray *types=d[@"parameterTypeNames"];
        if(![d[@"signatureAvailable"] boolValue]||![types isKindOfClass:NSArray.class]||
           types.count!=(NSUInteger)argc.integerValue){
            if(error)*error=[NSString stringWithFormat:@"Runtime 缺少完整方法签名，需在旧游戏重新定位：%@",key];
            return NO;
        }
        for(id type in types)if(![type isKindOfClass:NSString.class]||![type length]){
            if(error)*error=@"Runtime 参数类型无效";return NO;
        }
        NSString *resolveError=nil;
        if(![[ZNIL2CPPFullSignatureResolver sharedResolver] resolveAssembly:assembly namespace:ns
            className:cls method:method parameterTypeNames:types error:&resolveError]){
            if(error)*error=[NSString stringWithFormat:@"Runtime 签名不匹配：%@ · %@",key,resolveError?:@""];
            return NO;
        }
    }
    for(id obj in hooks){
        if(![obj isKindOfClass:NSDictionary.class]||![hookStore validateAuthoringDictionary:obj error:error])return NO;
        NSDictionary *d=obj;
        NSString *assembly=[d[@"assembly"] isKindOfClass:NSString.class]?d[@"assembly"]:@"Assembly-CSharp.dll";
        NSString *ns=[d[@"namespace"] isKindOfClass:NSString.class]?d[@"namespace"]:@"";
        NSString *cls=d[@"class"],*method=d[@"method"];
        NSNumber *argc=d[@"argumentCount"];
        if(![argc isKindOfClass:NSNumber.class]||argc.integerValue<0||argc.integerValue>8){
            if(error)*error=@"Native Hook 参数数量无效";return NO;
        }
        NSString *key=[NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@",
            assembly,ns,cls,method,argc,d[@"templateKind"]?:@0,d[@"argumentIndex"]?:@0];
        if([pendingHooks containsObject:key]){
            if(error)*error=[NSString stringWithFormat:@"重复 Native Hook：%@",key];return NO;
        }
        for(ZNNativeHookAction *oldAction in [hookStore actionsSnapshot]){
            if([oldAction.assembly isEqualToString:assembly]&&
               [oldAction.namespaceName isEqualToString:ns]&&
               [oldAction.className isEqualToString:cls]&&
               [oldAction.methodName isEqualToString:method]&&
               oldAction.argumentCount==(NSUInteger)argc.integerValue&&
               oldAction.templateKind==[d[@"templateKind"] unsignedIntValue]&&
               oldAction.argumentIndex==[d[@"argumentIndex"] unsignedIntegerValue]){
                if(error)*error=@"目标 Native Hook 已存在，请勿重复导入";return NO;
            }
        }
        [pendingHooks addObject:key];
        NSArray *types=d[@"parameterTypeNames"];
        if(![d[@"signatureAvailable"] boolValue]||![types isKindOfClass:NSArray.class]||
           types.count!=(NSUInteger)argc.integerValue){
            if(error)*error=[NSString stringWithFormat:@"Native Hook 缺少完整方法签名：%@",key];
            return NO;
        }
        for(id type in types)if(![type isKindOfClass:NSString.class]||![type length]){
            if(error)*error=@"Native Hook 参数类型无效";return NO;
        }
        NSString *resolveError=nil;
        if(![[ZNIL2CPPFullSignatureResolver sharedResolver] resolveAssembly:assembly namespace:ns
            className:cls method:method parameterTypeNames:types error:&resolveError]){
            if(error)*error=[NSString stringWithFormat:@"Native Hook 签名不匹配：%@ · %@",key,resolveError?:@""];
            return NO;
        }
    }

    NSUInteger addedMethods=0,addedHooks=0;
    for(NSDictionary *d in methods){
        NSMutableDictionary *candidate=[d mutableCopy];
        NSString *title=[d[@"title"] isKindOfClass:NSString.class]?d[@"title"]:@"";
        NSArray *values=d[@"argumentValues"];
        NSString *err=nil;
        ZNRuntimeExecutionKind kind=(ZNRuntimeExecutionKind)[d[@"executionKind"] integerValue];
        ZNRuntimeMethodAction *a=kind==ZNRuntimeExecutionKindDirectNativeCall?
            [store addDirectNativeCallCandidate:candidate title:title argumentValues:values error:&err]:
            [store addMethodCandidate:candidate title:title argumentValues:values error:&err];
        if(!a){if(error)*error=err?:@"Runtime 方法添加失败";return NO;}
        NSUInteger index=[[store actionsSnapshot] count]-1;
        if(![store updateArgumentControlConfigs:d[@"argumentControlConfigs"] atIndex:index error:&err]){
            if(error)*error=err?:@"Runtime 控件配置失败";return NO;
        }
        NSDictionary *chain=[d[@"immediateChain"] isKindOfClass:NSDictionary.class]?d[@"immediateChain"]:@{};
        if(chain.count&&![store updateImmediateChain:chain atIndex:index error:&err]){
            if(error)*error=err?:@"Runtime 链式配置无效";return NO;
        }
        NSString *description=[d[@"description"] isKindOfClass:NSString.class]?d[@"description"]:@"";
        [store updateFeatureDescription:description atIndex:index error:nil];
        addedMethods++;
    }
    for(NSDictionary *d in hooks){
        NSString *err=nil;
        if(![hookStore importAuthoringDictionary:d error:&err]){
            if(error)*error=err?:@"Native Hook 导入失败";return NO;
        }
        addedHooks++;
    }
    if(status)*status=[NSString stringWithFormat:@"导入成功：Runtime Method %lu，Native Hook %lu；旧 RVA 已废弃",
                       (unsigned long)addedMethods,(unsigned long)addedHooks];
    return YES;
}
@end
