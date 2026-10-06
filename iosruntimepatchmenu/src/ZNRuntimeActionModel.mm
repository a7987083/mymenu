#import "ZNRuntimeActionModel.h"
#import "ZNRuntimeActionFormat.h"
#import "ZNIL2CPPMethodSignature.h"
#import "ZNValueTypeModel.h"
#import "ZNPatchCore.h"

static NSString *ZNRMATrim(NSString *value) { return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }
static uint32_t ZNRMAFNV1a32(NSString *text) {
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding]?:[NSData data]; const uint8_t *bytes=(const uint8_t *)data.bytes; uint32_t h=UINT32_C(2166136261);
    for(NSUInteger i=0;i<data.length;i++){h^=bytes[i];h*=UINT32_C(16777619);} return h?:1u;
}

NSString *ZNRuntimeArgumentControlTypeName(ZNRuntimeArgumentControlType type) {
    switch(type){case ZNRuntimeArgumentControlTypeSwitch:return @"开关";case ZNRuntimeArgumentControlTypeButton:return @"按钮";case ZNRuntimeArgumentControlTypeNumber:return @"数值";case ZNRuntimeArgumentControlTypeSlider:return @"滑块";default:return @"固定";}
}
NSString *ZNRuntimeArgumentControlTypeKey(ZNRuntimeArgumentControlType type) {
    switch(type){case ZNRuntimeArgumentControlTypeSwitch:return @"switch";case ZNRuntimeArgumentControlTypeButton:return @"button";case ZNRuntimeArgumentControlTypeNumber:return @"number";case ZNRuntimeArgumentControlTypeSlider:return @"slider";default:return @"fixed";}
}
ZNRuntimeArgumentControlType ZNRuntimeArgumentControlTypeFromKey(NSString *key) {
    NSString *k=(key?:@"").lowercaseString; if([k isEqualToString:@"switch"])return ZNRuntimeArgumentControlTypeSwitch;if([k isEqualToString:@"button"])return ZNRuntimeArgumentControlTypeButton;if([k isEqualToString:@"number"])return ZNRuntimeArgumentControlTypeNumber;if([k isEqualToString:@"slider"])return ZNRuntimeArgumentControlTypeSlider;return ZNRuntimeArgumentControlTypeFixed;
}

static NSDictionary *ZNRMAConfig(BOOL enabled, ZNRuntimeArgumentControlType controlType, ZNValueType valueType, NSString *managedType) {
    ZNValueType resolved=valueType==ZNValueTypeAuto?ZNValueTypeForManagedTypeName(managedType):valueType;
    NSDictionary *range=ZNDefaultRangeForValueType(resolved, controlType==ZNRuntimeArgumentControlTypeSlider);
    return @{@"enabled":@(enabled),@"type":ZNRuntimeArgumentControlTypeKey(enabled?controlType:ZNRuntimeArgumentControlTypeFixed),@"valueType":ZNValueTypeKey(valueType),@"default":range[@"default"]?:@1,@"min":range[@"min"]?:@0,@"max":range[@"max"]?:@(INT32_MAX),@"step":range[@"step"]?:@1};
}

static NSArray<NSDictionary<NSString *,id> *> *ZNRMADefaultConfigs(NSUInteger count, NSArray<NSString *> *parameterTypes) {
    NSMutableArray *items=[NSMutableArray arrayWithCapacity:count];
    for(NSUInteger i=0;i<count;i++){NSString *managed=i<parameterTypes.count?parameterTypes[i]:@"";[items addObject:ZNRMAConfig(NO,ZNRuntimeArgumentControlTypeFixed,ZNValueTypeAuto,managed)];}
    return [items copy];
}

@implementation ZNRuntimeMethodAction
- (instancetype)init { self=[super init];if(!self)return nil;_executionKind=ZNRuntimeExecutionKindMethodCall;_title=@"";_group=@"Runtime Methods";_featureDescription=@"";_assembly=@"Assembly-CSharp.dll";_namespaceName=@"";_className=@"";_methodName=@"";_argumentValues=@[];_parameterTypeNames=@[];_signatureAvailable=NO;_argumentControlConfigs=@[];_immediateChain=@{};return self; }
- (NSString *)legacyCanonicalIdentity {NSString *owner=self.namespaceName.length?[NSString stringWithFormat:@"%@.%@",self.namespaceName,self.className]:self.className;return [NSString stringWithFormat:@"%@!%@::%@/%lu",self.assembly?:@"",owner?:@"",self.methodName?:@"",(unsigned long)self.argumentCount];}
- (NSString *)canonicalIdentity {if(self.signatureAvailable&&self.parameterTypeNames.count==self.argumentCount)return ZNIL2CPPFullMethodIdentity(self.assembly?:@"",self.namespaceName?:@"",self.className?:@"",self.methodName?:@"",self.parameterTypeNames?:@[]);return self.legacyCanonicalIdentity;}
- (id)copyWithZone:(NSZone *)zone {ZNRuntimeMethodAction *copy=[[[self class] allocWithZone:zone]init];copy.actionID=self.actionID;copy.executionKind=self.executionKind;copy.title=self.title;copy.group=self.group;copy.featureDescription=self.featureDescription?:@"";copy.assembly=self.assembly;copy.namespaceName=self.namespaceName;copy.className=self.className;copy.methodName=self.methodName;copy.argumentCount=self.argumentCount;copy.argumentValues=self.argumentValues?:@[];copy.parameterTypeNames=self.parameterTypeNames?:@[];copy.signatureAvailable=self.signatureAvailable;copy.argumentControlConfigs=self.argumentControlConfigs?:@[];copy.immediateChain=self.immediateChain?:@{};return copy;}
@end

@interface ZNRuntimeActionStore ()
@property(nonatomic,strong) NSMutableArray<ZNRuntimeMethodAction *> *mutableActions;
@end
@implementation ZNRuntimeActionStore
+ (instancetype)sharedStore {static ZNRuntimeActionStore *store;static dispatch_once_t once;dispatch_once(&once,^{store=[ZNRuntimeActionStore new];});return store;}
- (instancetype)init {self=[super init];if(!self)return nil;_mutableActions=[NSMutableArray array];return self;}
- (NSArray<ZNRuntimeMethodAction *> *)actions{return [self actionsSnapshot];}
- (ZNRuntimeMethodAction *)addMethodCandidate:(NSDictionary<NSString *,id> *)candidate title:(NSString *)title error:(NSString **)error{return [self addMethodCandidate:candidate title:title argumentValues:@[] error:error];}
- (ZNRuntimeMethodAction *)addMethodCandidate:(NSDictionary<NSString *,id> *)candidate title:(NSString *)title argumentValues:(NSArray<NSString *> *)argumentValues error:(NSString **)error {
    NSString *assembly=ZNRMATrim([candidate[@"assembly"] isKindOfClass:NSString.class]?candidate[@"assembly"]:@"");NSString *namespaceName=ZNRMATrim([candidate[@"namespace"] isKindOfClass:NSString.class]?candidate[@"namespace"]:@"");NSString *className=ZNRMATrim([candidate[@"class"] isKindOfClass:NSString.class]?candidate[@"class"]:@"");NSString *methodName=ZNRMATrim([candidate[@"method"] isKindOfClass:NSString.class]?candidate[@"method"]:@"");NSInteger argc=[candidate[@"argumentCount"] respondsToSelector:@selector(integerValue)]?[candidate[@"argumentCount"] integerValue]:-1;
    if(!assembly.length)assembly=@"Assembly-CSharp.dll";if(!className.length||!methodName.length||argc<0){if(error)*error=@"方法身份不完整，无法创建 Runtime Method Call";return nil;}if((NSUInteger)argc>ZN_RUNTIME_ACTION_MAX_ARGUMENTS){if(error)*error=[NSString stringWithFormat:@"参数数量超过上限 %u",ZN_RUNTIME_ACTION_MAX_ARGUMENTS];return nil;}
    NSArray<NSString *> *values=argumentValues?:@[];if(argc==0)values=@[];if(argc>0&&values.count!=(NSUInteger)argc){if(error)*error=[NSString stringWithFormat:@"/%ld 方法必须提供 %ld 个参数值",(long)argc,(long)argc];return nil;}
    NSArray<NSString *> *parameterTypes=nil;BOOL signatureAvailable=NO;id candidateTypes=candidate[@"parameterTypeNames"];
    if([candidateTypes isKindOfClass:NSArray.class]&&[(NSArray *)candidateTypes count]==(NSUInteger)argc){parameterTypes=[candidateTypes copy];signatureAvailable=![candidate[@"signatureAvailable"] respondsToSelector:@selector(boolValue)]||[candidate[@"signatureAvailable"] boolValue];}
    if(!signatureAvailable){NSString *signatureError=nil;NSArray<NSString *> *derived=ZNIL2CPPParameterTypeNamesForCandidate(candidate,&signatureError);if(derived&&derived.count==(NSUInteger)argc){parameterTypes=derived;signatureAvailable=YES;}else [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[m4.6-signature] authoring legacy fallback %@::%@/%ld reason=%@",className,methodName,(long)argc,signatureError?:@"signature unavailable"]];}
    ZNRuntimeMethodAction *action=[ZNRuntimeMethodAction new];
    NSInteger requestedKind=[candidate[@"znExecutionKind"] integerValue];
    action.executionKind=(requestedKind==ZNRuntimeExecutionKindDirectNativeCall)?ZNRuntimeExecutionKindDirectNativeCall:ZNRuntimeExecutionKindMethodCall;
    action.assembly=assembly;action.namespaceName=namespaceName;action.className=className;action.methodName=methodName;action.argumentCount=(NSUInteger)argc;action.argumentValues=[values copy];action.parameterTypeNames=parameterTypes?:@[];action.signatureAvailable=signatureAvailable;action.title=ZNRMATrim(title).length?ZNRMATrim(title):methodName;action.group=(action.executionKind==ZNRuntimeExecutionKindDirectNativeCall)?@"Direct Native Calls":@"Runtime Methods";action.argumentControlConfigs=ZNRMADefaultConfigs(action.argumentCount,action.parameterTypeNames);
    @synchronized(self){uint32_t serial=0;BOOL collision=NO;do{NSString *seed=[NSString stringWithFormat:@"%ld|%@|%@|%@|%lu|%u",(long)action.executionKind,action.canonicalIdentity?:@"",action.title?:@"",action.argumentValues?:@[],(unsigned long)self.mutableActions.count,serial++];action.actionID=ZNRMAFNV1a32(seed);collision=NO;for(ZNRuntimeMethodAction *existing in self.mutableActions)if(existing.actionID==action.actionID){collision=YES;break;}}while(collision);[self.mutableActions addObject:action];}
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[m5.5-typed] add id=%u %@ types=%@",action.actionID,action.canonicalIdentity,action.parameterTypeNames]];return [action copy];
}
- (ZNRuntimeMethodAction *)addDirectNativeCallCandidate:(NSDictionary<NSString *,id> *)candidate
                                                  title:(NSString *)title
                                         argumentValues:(NSArray<NSString *> *)argumentValues
                                                  error:(NSString **)error {
    NSMutableDictionary *tagged=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
    tagged[@"znExecutionKind"]=@(ZNRuntimeExecutionKindDirectNativeCall);
    return [self addMethodCandidate:tagged title:title argumentValues:argumentValues error:error];
}

- (BOOL)updateTitle:(NSString *)title atIndex:(NSUInteger)index error:(NSString **)error {NSString *trimmed=ZNRMATrim(title);@synchronized(self){if(index>=self.mutableActions.count){if(error)*error=@"Runtime Method Call 索引已失效";return NO;}ZNRuntimeMethodAction *action=self.mutableActions[index];action.title=trimmed.length?trimmed:action.methodName;return YES;}}
- (BOOL)updateFeatureDescription:(NSString *)featureDescription atIndex:(NSUInteger)index error:(NSString **)error {NSString *trimmed=ZNRMATrim(featureDescription);@synchronized(self){if(index>=self.mutableActions.count){if(error)*error=@"Runtime Method Call 索引已失效";return NO;}self.mutableActions[index].featureDescription=trimmed?:@"";return YES;}}
- (BOOL)updateArgumentValues:(NSArray<NSString *> *)argumentValues atIndex:(NSUInteger)index error:(NSString **)error {@synchronized(self){if(index>=self.mutableActions.count){if(error)*error=@"Runtime Method Call 索引已失效";return NO;}ZNRuntimeMethodAction *action=self.mutableActions[index];NSArray<NSString *> *values=argumentValues?:@[];if(action.argumentCount==0)values=@[];if(action.argumentCount>0&&values.count!=action.argumentCount){if(error)*error=@"参数数量不匹配";return NO;}action.argumentValues=[values copy];return YES;}}
- (BOOL)updateArgumentControlConfigs:(NSArray<NSDictionary<NSString *,id> *> *)configs atIndex:(NSUInteger)index error:(NSString **)error {
    @synchronized(self){if(index>=self.mutableActions.count){if(error)*error=@"Runtime Method Call 索引已失效";return NO;}ZNRuntimeMethodAction *action=self.mutableActions[index];if(configs.count!=action.argumentCount){if(error)*error=@"参数控件配置数量必须等于 argc";return NO;}NSMutableArray *clean=[NSMutableArray arrayWithCapacity:configs.count];
        for(NSUInteger i=0;i<configs.count;i++){NSDictionary *raw=configs[i];BOOL enabled=[raw[@"enabled"]boolValue];ZNRuntimeArgumentControlType control=enabled?ZNRuntimeArgumentControlTypeFromKey(raw[@"type"]):ZNRuntimeArgumentControlTypeFixed;ZNValueType vt=ZNValueTypeFromKey([raw[@"valueType"] isKindOfClass:NSString.class]?raw[@"valueType"]:@"auto");NSString *managed=i<action.parameterTypeNames.count?action.parameterTypeNames[i]:@"";ZNValueType resolved=vt==ZNValueTypeAuto?ZNValueTypeForManagedTypeName(managed):vt;NSDictionary *defaults=ZNDefaultRangeForValueType(resolved,control==ZNRuntimeArgumentControlTypeSlider);[clean addObject:@{@"enabled":@(enabled),@"type":ZNRuntimeArgumentControlTypeKey(control),@"valueType":ZNValueTypeKey(vt),@"default":raw[@"default"]?:defaults[@"default"]?:@1,@"min":raw[@"min"]?:defaults[@"min"]?:@0,@"max":raw[@"max"]?:defaults[@"max"]?:@(INT32_MAX),@"step":raw[@"step"]?:defaults[@"step"]?:@1}];}
        action.argumentControlConfigs=[clean copy];return YES;}
}
- (BOOL)updateImmediateChain:(NSDictionary<NSString *,id> *)chain atIndex:(NSUInteger)index error:(NSString **)error {@synchronized(self){if(index>=self.mutableActions.count){if(error)*error=@"Runtime Method Call 索引已失效";return NO;}ZNRuntimeMethodAction *action=self.mutableActions[index];if(!chain.count){action.immediateChain=@{};return YES;}NSString *className=[chain[@"class"] isKindOfClass:NSString.class]?chain[@"class"]:@"";NSString *method=[chain[@"method"] isKindOfClass:NSString.class]?chain[@"method"]:@"";NSInteger argc=[chain[@"argumentCount"]integerValue];if(!className.length||!method.length||argc<0||argc>(NSInteger)ZN_RUNTIME_ACTION_MAX_ARGUMENTS){if(error)*error=@"链式目标 Class/Method/argc 无效";return NO;}action.immediateChain=[chain copy];return YES;}}
- (BOOL)removeActionAtIndex:(NSUInteger)index {@synchronized(self){if(index>=self.mutableActions.count)return NO;[self.mutableActions removeObjectAtIndex:index];return YES;}}
- (void)clear {@synchronized(self){[self.mutableActions removeAllObjects];}}
- (NSArray<ZNRuntimeMethodAction *> *)actionsSnapshot {@synchronized(self){NSMutableArray *copy=[NSMutableArray arrayWithCapacity:self.mutableActions.count];for(ZNRuntimeMethodAction *action in self.mutableActions)[copy addObject:[action copy]];return [copy copy];}}
@end
