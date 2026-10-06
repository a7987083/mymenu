#import "ZNNativeHookAction.h"
#import "ZNIL2CPPABIMetadata.h"
#import "ZNComplexStructCodec.h"
#import "ZNIL2CPPMethodSignature.h"
#import "ZNPatchCore.h"

static NSString * const kZNNativeHookStoreKey = @"zonoe.native-hook-actions.v1";

static NSString *ZNNHTrim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static uint32_t ZNNHFNV1a32(NSString *text) {
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding]?:[NSData data];
    const uint8_t *bytes=(const uint8_t *)data.bytes;
    uint32_t h=UINT32_C(2166136261);
    for(NSUInteger i=0;i<data.length;i++){h^=bytes[i];h*=UINT32_C(16777619);}
    return h?:1u;
}

@implementation ZNNativeHookAction
- (instancetype)init {
    self=[super init];
    if(!self)return nil;
    _title=@"";
    _group=@"Native Hooks";
    _featureDescription=@"";
    _assembly=@"Assembly-CSharp.dll";
    _namespaceName=@"";
    _className=@"";
    _methodName=@"";
    _parameterTypeNames=@[];
    _templateKind=ZNNativeHookTemplateInvalid;
    _minValue=1;
    _maxValue=20;
    _defaultValue=1;
    _callbackArgumentIndex=NSNotFound;
    _callbackValue=YES;
    _skipOriginal=YES;
    _returnBoolValue=YES;
    _fieldArgumentIndex=NSNotFound;
    _fieldArgumentMode=@"indirect-pointer";
    _fieldOffset=0;
    _fieldCodec=@"";
    _codecAssembly=@"";
    _codecNamespaceName=@"";
    _codecClassName=@"";
    _codecGetterMethod=@"";
    _codecSetterMethod=@"";
    _codecGetterArgumentCount=0;
    _codecSetterArgumentCount=1;
    _preparedDescriptor=NO;
    _preparedRVA=0;
    _preparedUUID=@"";
    _preparedStaticKnown=NO;
    _preparedIsStatic=NO;
    _preparedCodecGetterRVA=0;
    _preparedCodecSetterRVA=0;
    _staticPrepatch=NO;
    _staticHookSlotRVA=0;
    _staticTrampolineRVA=0;
    _staticCodeCaveRVA=0;
    _staticDisplacedInstruction=0;
    _fallbackUUID=@"";
    return self;
}
- (NSString *)canonicalIdentity {
    if(self.signatureAvailable&&self.parameterTypeNames.count==self.argumentCount)
        return ZNIL2CPPFullMethodIdentity(self.assembly?:@"",self.namespaceName?:@"",self.className?:@"",self.methodName?:@"",self.parameterTypeNames?:@[]);
    NSString *owner=self.namespaceName.length?[NSString stringWithFormat:@"%@.%@",self.namespaceName,self.className]:self.className;
    return [NSString stringWithFormat:@"%@!%@::%@/%lu",self.assembly?:@"",owner?:@"",self.methodName?:@"",(unsigned long)self.argumentCount];
}
- (id)copyWithZone:(NSZone *)zone {
    ZNNativeHookAction *c=[[[self class] allocWithZone:zone]init];
    c.actionID=self.actionID;c.title=self.title;c.group=self.group;c.featureDescription=self.featureDescription;
    c.assembly=self.assembly;c.namespaceName=self.namespaceName;c.className=self.className;c.methodName=self.methodName;
    c.argumentCount=self.argumentCount;c.parameterTypeNames=self.parameterTypeNames;c.signatureAvailable=self.signatureAvailable;
    c.templateKind=self.templateKind;c.argumentIndex=self.argumentIndex;c.minValue=self.minValue;c.maxValue=self.maxValue;
    c.defaultValue=self.defaultValue;c.callbackArgumentIndex=self.callbackArgumentIndex;
    c.callbackValue=self.callbackValue;c.skipOriginal=self.skipOriginal;c.returnBoolValue=self.returnBoolValue;
    c.fieldArgumentIndex=self.fieldArgumentIndex;c.fieldArgumentMode=self.fieldArgumentMode;c.fieldOffset=self.fieldOffset;
    c.fieldCodec=self.fieldCodec;c.codecAssembly=self.codecAssembly;c.codecNamespaceName=self.codecNamespaceName;
    c.codecClassName=self.codecClassName;c.codecGetterMethod=self.codecGetterMethod;c.codecSetterMethod=self.codecSetterMethod;
    c.codecGetterArgumentCount=self.codecGetterArgumentCount;c.codecSetterArgumentCount=self.codecSetterArgumentCount;
    c.preparedDescriptor=self.preparedDescriptor;c.preparedRVA=self.preparedRVA;c.preparedUUID=self.preparedUUID;
    c.preparedStaticKnown=self.preparedStaticKnown;c.preparedIsStatic=self.preparedIsStatic;
    c.preparedCodecGetterRVA=self.preparedCodecGetterRVA;c.preparedCodecSetterRVA=self.preparedCodecSetterRVA;
    c.staticPrepatch=self.staticPrepatch;c.staticHookSlotRVA=self.staticHookSlotRVA;
    c.staticTrampolineRVA=self.staticTrampolineRVA;c.staticCodeCaveRVA=self.staticCodeCaveRVA;
    c.staticDisplacedInstruction=self.staticDisplacedInstruction;
    c.fallbackRVA=self.fallbackRVA;c.fallbackUUID=self.fallbackUUID;
    return c;
}
@end

@interface ZNNativeHookStore ()
@property(nonatomic,strong) NSMutableArray<ZNNativeHookAction *> *mutableActions;
@end

@implementation ZNNativeHookStore

+ (instancetype)sharedStore {
    static ZNNativeHookStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store=[ZNNativeHookStore new]; });
    return store;
}

- (instancetype)init {
    self=[super init];
    if(!self)return nil;
    _mutableActions=[NSMutableArray array];
    [self loadPersisted];
    return self;
}

- (NSDictionary *)dictionaryForAction:(ZNNativeHookAction *)a {
    return @{
        @"actionID":@(a.actionID),@"title":a.title?:@"",@"group":a.group?:@"Native Hooks",
        @"description":a.featureDescription?:@"",@"assembly":a.assembly?:@"Assembly-CSharp.dll",
        @"namespace":a.namespaceName?:@"",@"class":a.className?:@"",@"method":a.methodName?:@"",
        @"argumentCount":@(a.argumentCount),@"parameterTypeNames":a.parameterTypeNames?:@[],
        @"signatureAvailable":@(a.signatureAvailable),@"template":ZNNativeHookTemplateKey(a.templateKind),
        @"templateKind":@(a.templateKind),@"argumentIndex":@(a.argumentIndex),
        @"min":@(a.minValue),@"max":@(a.maxValue),@"default":@(a.defaultValue),
        @"callbackArgumentIndex":@(a.callbackArgumentIndex==NSNotFound?NSUIntegerMax:a.callbackArgumentIndex),
        @"callbackValue":@(a.callbackValue),@"skipOriginal":@(a.skipOriginal),
        @"returnBoolValue":@(a.returnBoolValue),
        @"fieldArgumentIndex":@(a.fieldArgumentIndex==NSNotFound?NSUIntegerMax:a.fieldArgumentIndex),
        @"fieldArgumentMode":a.fieldArgumentMode?:@"indirect-pointer",
        @"fieldOffset":@(a.fieldOffset),@"fieldCodec":a.fieldCodec?:@"",
        @"codecAssembly":a.codecAssembly?:@"",@"codecNamespace":a.codecNamespaceName?:@"",
        @"codecClass":a.codecClassName?:@"",@"codecGetterMethod":a.codecGetterMethod?:@"",
        @"codecSetterMethod":a.codecSetterMethod?:@"",
        @"codecGetterArgumentCount":@(a.codecGetterArgumentCount),
        @"codecSetterArgumentCount":@(a.codecSetterArgumentCount),
        @"preparedDescriptor":@(a.preparedDescriptor),
        @"preparedRVA":@(a.preparedRVA),
        @"preparedUUID":a.preparedUUID?:@"",
        @"preparedStaticKnown":@(a.preparedStaticKnown),
        @"preparedIsStatic":@(a.preparedIsStatic),
        @"preparedCodecGetterRVA":@(a.preparedCodecGetterRVA),
        @"preparedCodecSetterRVA":@(a.preparedCodecSetterRVA),
        @"staticPrepatch":@(a.staticPrepatch),
        @"staticHookSlotRVA":@(a.staticHookSlotRVA),
        @"staticTrampolineRVA":@(a.staticTrampolineRVA),
        @"staticCodeCaveRVA":@(a.staticCodeCaveRVA),
        @"staticDisplacedInstruction":@(a.staticDisplacedInstruction),
        @"fallbackRVA":@(a.fallbackRVA),@"fallbackUUID":a.fallbackUUID?:@""
    };
}

- (ZNNativeHookAction *)actionFromDictionary:(NSDictionary *)d {
    if(![d isKindOfClass:NSDictionary.class])return nil;
    ZNNativeHookAction *a=[ZNNativeHookAction new];
    a.actionID=[d[@"actionID"] unsignedIntValue];
    a.title=[d[@"title"] isKindOfClass:NSString.class]?d[@"title"]:@"";
    a.group=[d[@"group"] isKindOfClass:NSString.class]?d[@"group"]:@"Native Hooks";
    a.featureDescription=[d[@"description"] isKindOfClass:NSString.class]?d[@"description"]:@"";
    a.assembly=[d[@"assembly"] isKindOfClass:NSString.class]?d[@"assembly"]:@"Assembly-CSharp.dll";
    a.namespaceName=[d[@"namespace"] isKindOfClass:NSString.class]?d[@"namespace"]:@"";
    a.className=[d[@"class"] isKindOfClass:NSString.class]?d[@"class"]:@"";
    a.methodName=[d[@"method"] isKindOfClass:NSString.class]?d[@"method"]:@"";
    a.argumentCount=[d[@"argumentCount"] unsignedIntegerValue];
    a.parameterTypeNames=[d[@"parameterTypeNames"] isKindOfClass:NSArray.class]?d[@"parameterTypeNames"]:@[];
    a.signatureAvailable=[d[@"signatureAvailable"] boolValue];
    a.templateKind=(ZNNativeHookTemplateKind)[d[@"templateKind"] unsignedIntValue];
    a.argumentIndex=[d[@"argumentIndex"] unsignedIntegerValue];
    a.minValue=[d[@"min"] integerValue];a.maxValue=[d[@"max"] integerValue];a.defaultValue=[d[@"default"] integerValue];
    NSUInteger storedCallback=[d[@"callbackArgumentIndex"] unsignedIntegerValue];
    a.callbackArgumentIndex=(storedCallback==NSUIntegerMax)?NSNotFound:storedCallback;
    a.callbackValue=d[@"callbackValue"]?[d[@"callbackValue"] boolValue]:YES;
    a.skipOriginal=d[@"skipOriginal"]?[d[@"skipOriginal"] boolValue]:YES;
    a.returnBoolValue=d[@"returnBoolValue"]?[d[@"returnBoolValue"] boolValue]:YES;
    NSUInteger storedFieldArg=[d[@"fieldArgumentIndex"] unsignedIntegerValue];
    a.fieldArgumentIndex=(storedFieldArg==NSUIntegerMax)?NSNotFound:storedFieldArg;
    a.fieldArgumentMode=[d[@"fieldArgumentMode"] isKindOfClass:NSString.class]?d[@"fieldArgumentMode"]:@"indirect-pointer";
    a.fieldOffset=[d[@"fieldOffset"] unsignedLongLongValue];
    a.fieldCodec=[d[@"fieldCodec"] isKindOfClass:NSString.class]?d[@"fieldCodec"]:@"";
    a.codecAssembly=[d[@"codecAssembly"] isKindOfClass:NSString.class]?d[@"codecAssembly"]:@"";
    a.codecNamespaceName=[d[@"codecNamespace"] isKindOfClass:NSString.class]?d[@"codecNamespace"]:@"";
    a.codecClassName=[d[@"codecClass"] isKindOfClass:NSString.class]?d[@"codecClass"]:@"";
    a.codecGetterMethod=[d[@"codecGetterMethod"] isKindOfClass:NSString.class]?d[@"codecGetterMethod"]:@"";
    a.codecSetterMethod=[d[@"codecSetterMethod"] isKindOfClass:NSString.class]?d[@"codecSetterMethod"]:@"";
    a.codecGetterArgumentCount=[d[@"codecGetterArgumentCount"] unsignedIntegerValue];
    a.codecSetterArgumentCount=d[@"codecSetterArgumentCount"]?[d[@"codecSetterArgumentCount"] unsignedIntegerValue]:1;
    a.preparedDescriptor=[d[@"preparedDescriptor"] boolValue];
    a.preparedRVA=[d[@"preparedRVA"] unsignedLongLongValue];
    a.preparedUUID=[d[@"preparedUUID"] isKindOfClass:NSString.class]?d[@"preparedUUID"]:@"";
    a.preparedStaticKnown=[d[@"preparedStaticKnown"] boolValue];
    a.preparedIsStatic=[d[@"preparedIsStatic"] boolValue];
    a.preparedCodecGetterRVA=[d[@"preparedCodecGetterRVA"] unsignedLongLongValue];
    a.preparedCodecSetterRVA=[d[@"preparedCodecSetterRVA"] unsignedLongLongValue];
    a.staticPrepatch=[d[@"staticPrepatch"] boolValue];
    a.staticHookSlotRVA=[d[@"staticHookSlotRVA"] unsignedLongLongValue];
    a.staticTrampolineRVA=[d[@"staticTrampolineRVA"] unsignedLongLongValue];
    a.staticCodeCaveRVA=[d[@"staticCodeCaveRVA"] unsignedLongLongValue];
    a.staticDisplacedInstruction=[d[@"staticDisplacedInstruction"] unsignedIntValue];
    a.fallbackRVA=[d[@"fallbackRVA"] unsignedLongLongValue];
    a.fallbackUUID=[d[@"fallbackUUID"] isKindOfClass:NSString.class]?d[@"fallbackUUID"]:@"";
    if(!a.actionID||!a.className.length||!a.methodName.length)return nil;
    if(a.templateKind==ZNNativeHookTemplateArgScaleInt32){
        if(a.argumentIndex>=a.argumentCount)return nil;
    }else if(a.templateKind==ZNNativeHookTemplateManagedCallbackShortCircuit){
        if(a.callbackArgumentIndex==NSNotFound||a.callbackArgumentIndex>=a.argumentCount||!a.skipOriginal)return nil;
    }else if(a.templateKind==ZNNativeHookTemplateReturnBoolOverride){
        // No additional persisted parameter index is required.
    }else if(a.templateKind==ZNNativeHookTemplateStructFieldTransform){
        if(a.fieldArgumentIndex==NSNotFound||a.fieldArgumentIndex>=a.argumentCount||
           ![a.fieldArgumentMode isEqualToString:@"indirect-pointer"]||
           ![a.fieldCodec isEqualToString:@"secure-long-accessor"]||
           !a.codecClassName.length||!a.codecGetterMethod.length||!a.codecSetterMethod.length)return nil;
    }else if(a.templateKind==ZNNativeHookTemplateComplexStructTransform){
        NSString *expected=ZNComplexStructCodecKeyForManagedType(a.codecClassName);
        if(a.fieldArgumentIndex==NSNotFound||a.fieldArgumentIndex>=a.argumentCount||
           ![a.fieldArgumentMode isEqualToString:@"indirect-pointer"]||
           !a.fieldCodec.length||![expected isEqualToString:a.fieldCodec]||
           a.fieldOffset!=0||!a.codecClassName.length)return nil;
    }else{
        return nil;
    }
    return a;
}

- (void)loadPersisted {
    NSArray *saved=[NSUserDefaults.standardUserDefaults objectForKey:kZNNativeHookStoreKey];
    if(![saved isKindOfClass:NSArray.class])return;
    for(id obj in saved){ZNNativeHookAction *a=[self actionFromDictionary:obj];if(a)[_mutableActions addObject:a];}
}

- (void)persist {
    NSMutableArray *items=[NSMutableArray arrayWithCapacity:self.mutableActions.count];
    for(ZNNativeHookAction *a in self.mutableActions)[items addObject:[self dictionaryForAction:a]];
    [NSUserDefaults.standardUserDefaults setObject:items forKey:kZNNativeHookStoreKey];
}

- (ZNNativeHookAction *)addArgScaleInt32Candidate:(NSDictionary<NSString *,id> *)candidate
                                             title:(NSString *)title
                                     argumentIndex:(NSUInteger)argumentIndex
                                               min:(NSInteger)minValue
                                               max:(NSInteger)maxValue
                                      defaultValue:(NSInteger)defaultValue
                                             error:(NSString **)error {
    NSString *assembly=ZNNHTrim([candidate[@"assembly"] isKindOfClass:NSString.class]?candidate[@"assembly"]:@"");
    if(!assembly.length)assembly=@"Assembly-CSharp.dll";
    NSString *ns=ZNNHTrim([candidate[@"namespace"] isKindOfClass:NSString.class]?candidate[@"namespace"]:@"");
    NSString *cls=ZNNHTrim([candidate[@"class"] isKindOfClass:NSString.class]?candidate[@"class"]:@"");
    NSString *method=ZNNHTrim([candidate[@"method"] isKindOfClass:NSString.class]?candidate[@"method"]:@"");
    NSInteger argc=[candidate[@"argumentCount"] respondsToSelector:@selector(integerValue)]?[candidate[@"argumentCount"] integerValue]:-1;
    if(!cls.length||!method.length||argc<=0||argumentIndex>=(NSUInteger)argc){if(error)*error=@"Native Hook 方法身份/参数索引无效";return nil;}
    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    if(![abi[@"available"] boolValue]||params.count!=(NSUInteger)argc){if(error)*error=@"Native Hook 需要完整 IL2CPP 参数 ABI";return nil;}
    NSDictionary *param=params[argumentIndex];
    if((ZNIL2CPPABIValueKind)[param[@"kind"] integerValue]!=ZNIL2CPPABIValueKindSigned32){if(error)*error=@"ArgScaleInt32 仅支持 int32/signed32 参数";return nil;}
    if(minValue<1||maxValue<minValue||maxValue>1000||defaultValue<minValue||defaultValue>maxValue){if(error)*error=@"倍率范围无效";return nil;}

    NSMutableArray *types=[NSMutableArray arrayWithCapacity:params.count];
    for(NSDictionary *p in params)[types addObject:[p[@"name"] isKindOfClass:NSString.class]?p[@"name"]:@"?"];

    ZNNativeHookAction *a=[ZNNativeHookAction new];
    a.assembly=assembly;a.namespaceName=ns;a.className=cls;a.methodName=method;a.argumentCount=(NSUInteger)argc;
    a.parameterTypeNames=[types copy];a.signatureAvailable=YES;a.templateKind=ZNNativeHookTemplateArgScaleInt32;
    a.argumentIndex=argumentIndex;a.minValue=minValue;a.maxValue=maxValue;a.defaultValue=defaultValue;
    a.title=ZNNHTrim(title).length?ZNNHTrim(title):[NSString stringWithFormat:@"%@ Multiplier",method];
    a.fallbackRVA=[candidate[@"rva"] unsignedLongLongValue];

    @synchronized(self){
        uint32_t serial=0;BOOL collision=NO;
        do{
            NSString *seed=[NSString stringWithFormat:@"%@|%@|%lu|%u",a.canonicalIdentity,a.title,(unsigned long)a.argumentIndex,serial++];
            a.actionID=ZNNHFNV1a32(seed);collision=NO;
            for(ZNNativeHookAction *e in self.mutableActions)if(e.actionID==a.actionID){collision=YES;break;}
        }while(collision);
        [self.mutableActions addObject:a];
        [self persist];
    }
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[native-hook-authoring] add id=%u %@ template=%@ arg=%lu",
                                           a.actionID,a.canonicalIdentity,ZNNativeHookTemplateKey(a.templateKind),(unsigned long)a.argumentIndex]];
    return [a copy];
}



- (ZNNativeHookAction *)addReturnBoolOverrideCandidate:(NSDictionary<NSString *,id> *)candidate
                                                 title:(NSString *)title
                                                 value:(BOOL)value
                                                 error:(NSString **)error {
    NSString *assembly=ZNNHTrim([candidate[@"assembly"] isKindOfClass:NSString.class]?candidate[@"assembly"]:@"");
    if(!assembly.length)assembly=@"Assembly-CSharp.dll";
    NSString *ns=ZNNHTrim([candidate[@"namespace"] isKindOfClass:NSString.class]?candidate[@"namespace"]:@"");
    NSString *cls=ZNNHTrim([candidate[@"class"] isKindOfClass:NSString.class]?candidate[@"class"]:@"");
    NSString *methodName=ZNNHTrim([candidate[@"method"] isKindOfClass:NSString.class]?candidate[@"method"]:@"");
    NSInteger argc=[candidate[@"argumentCount"] respondsToSelector:@selector(integerValue)]?[candidate[@"argumentCount"] integerValue]:-1;
    if(!cls.length||!methodName.length||argc<0){if(error)*error=@"ReturnBoolOverride 方法身份无效";return nil;}

    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSDictionary *ret=[abi[@"return"] isKindOfClass:NSDictionary.class]?abi[@"return"]:@{};
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    if(![abi[@"available"] boolValue]||params.count!=(NSUInteger)argc){if(error)*error=@"ReturnBoolOverride 需要完整 IL2CPP ABI";return nil;}
    if((ZNIL2CPPABIValueKind)[ret[@"kind"] integerValue]!=ZNIL2CPPABIValueKindBool){if(error)*error=@"ReturnBoolOverride V1 仅支持 bool 返回";return nil;}
    if([abi[@"generic"] boolValue]||[abi[@"inflated"] boolValue]){if(error)*error=@"ReturnBoolOverride V1 不支持 generic/inflated 方法";return nil;}
    for(NSDictionary *p in params){
        ZNIL2CPPABIValueKind kind=(ZNIL2CPPABIValueKind)[p[@"kind"] integerValue];
        BOOL gpr=(kind==ZNIL2CPPABIValueKindBool||kind==ZNIL2CPPABIValueKindSigned32||
                  kind==ZNIL2CPPABIValueKindUnsigned32||kind==ZNIL2CPPABIValueKindSigned64||
                  kind==ZNIL2CPPABIValueKindUnsigned64||kind==ZNIL2CPPABIValueKindPointer||
                  kind==ZNIL2CPPABIValueKindObjectReference);
        if(!gpr||[p[@"byRef"] boolValue]){
            if(error)*error=@"ReturnBoolOverride V1 仅支持 ARM64 GPR-safe 参数";
            return nil;
        }
    }

    NSMutableArray *types=[NSMutableArray arrayWithCapacity:params.count];
    for(NSDictionary *p in params)[types addObject:[p[@"name"] isKindOfClass:NSString.class]?p[@"name"]:@"?"];

    ZNNativeHookAction *a=[ZNNativeHookAction new];
    a.assembly=assembly;a.namespaceName=ns;a.className=cls;a.methodName=methodName;a.argumentCount=(NSUInteger)argc;
    a.parameterTypeNames=[types copy];a.signatureAvailable=YES;a.templateKind=ZNNativeHookTemplateReturnBoolOverride;
    a.returnBoolValue=value;a.minValue=0;a.maxValue=1;a.defaultValue=0;
    a.title=ZNNHTrim(title).length?ZNNHTrim(title):[NSString stringWithFormat:@"%@ Override",methodName];
    a.featureDescription=[NSString stringWithFormat:@"Return Bool Override · force %@",value?@"true":@"false"];
    a.fallbackRVA=[candidate[@"rva"] unsignedLongLongValue];

    @synchronized(self){
        uint32_t serial=0;BOOL collision=NO;
        do{
            NSString *seed=[NSString stringWithFormat:@"%@|%@|return-bool:%d|%u",a.canonicalIdentity,a.title,value?1:0,serial++];
            a.actionID=ZNNHFNV1a32(seed);collision=NO;
            for(ZNNativeHookAction *e in self.mutableActions)if(e.actionID==a.actionID){collision=YES;break;}
        }while(collision);
        [self.mutableActions addObject:a];
        [self persist];
    }
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[native-hook-authoring] add id=%u %@ template=%@ value=%@",
                                       a.actionID,a.canonicalIdentity,ZNNativeHookTemplateKey(a.templateKind),value?@"true":@"false"]];
    return [a copy];
}

- (ZNNativeHookAction *)addManagedCallbackShortCircuitCandidate:(NSDictionary<NSString *,id> *)candidate
                                                          title:(NSString *)title
                                          callbackArgumentIndex:(NSUInteger)argumentIndex
                                                  callbackValue:(BOOL)callbackValue
                                                   skipOriginal:(BOOL)skipOriginal
                                                          error:(NSString **)error {
    NSString *assembly=ZNNHTrim([candidate[@"assembly"] isKindOfClass:NSString.class]?candidate[@"assembly"]:@"");
    if(!assembly.length)assembly=@"Assembly-CSharp.dll";
    NSString *ns=ZNNHTrim([candidate[@"namespace"] isKindOfClass:NSString.class]?candidate[@"namespace"]:@"");
    NSString *cls=ZNNHTrim([candidate[@"class"] isKindOfClass:NSString.class]?candidate[@"class"]:@"");
    NSString *method=ZNNHTrim([candidate[@"method"] isKindOfClass:NSString.class]?candidate[@"method"]:@"");
    NSInteger argc=[candidate[@"argumentCount"] respondsToSelector:@selector(integerValue)]?[candidate[@"argumentCount"] integerValue]:-1;
    if(!cls.length||!method.length||argc<=0||argumentIndex>=(NSUInteger)argc){if(error)*error=@"ManagedCallback 方法身份/参数索引无效";return nil;}
    if(!skipOriginal){if(error)*error=@"M6.5 V1 只支持 Skip Original=YES";return nil;}

    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    NSDictionary *ret=[abi[@"return"] isKindOfClass:NSDictionary.class]?abi[@"return"]:@{};
    if(![abi[@"available"] boolValue]||params.count!=(NSUInteger)argc){if(error)*error=@"ManagedCallback 需要完整 IL2CPP 参数 ABI";return nil;}
    if((ZNIL2CPPABIValueKind)[ret[@"kind"] integerValue]!=ZNIL2CPPABIValueKindVoid){if(error)*error=@"M6.5 V1 仅允许 void 目标方法做 Skip Original";return nil;}
    NSDictionary *param=params[argumentIndex];
    NSString *type=[param[@"name"] isKindOfClass:NSString.class]?param[@"name"]:@"";
    NSString *lower=type.lowercaseString;
    BOOL actionBool=[lower containsString:@"system.action"]&&[lower containsString:@"system.boolean"];
    if((ZNIL2CPPABIValueKind)[param[@"kind"] integerValue]!=ZNIL2CPPABIValueKindObjectReference||!actionBool){
        if(error)*error=[NSString stringWithFormat:@"参数%lu 不是 System.Action<bool> 托管回调",(unsigned long)argumentIndex+1];
        return nil;
    }

    NSMutableArray *types=[NSMutableArray arrayWithCapacity:params.count];
    for(NSDictionary *p in params)[types addObject:[p[@"name"] isKindOfClass:NSString.class]?p[@"name"]:@"?"];

    ZNNativeHookAction *a=[ZNNativeHookAction new];
    a.assembly=assembly;a.namespaceName=ns;a.className=cls;a.methodName=method;a.argumentCount=(NSUInteger)argc;
    a.parameterTypeNames=[types copy];a.signatureAvailable=YES;
    a.templateKind=ZNNativeHookTemplateManagedCallbackShortCircuit;
    a.callbackArgumentIndex=argumentIndex;a.callbackValue=callbackValue;a.skipOriginal=YES;
    a.minValue=0;a.maxValue=1;a.defaultValue=0;
    a.title=ZNNHTrim(title).length?ZNNHTrim(title):[NSString stringWithFormat:@"%@ Short Circuit",method];
    a.featureDescription=@"Managed callback short circuit · Skip Original";
    a.fallbackRVA=[candidate[@"rva"] unsignedLongLongValue];

    @synchronized(self){
        uint32_t serial=0;BOOL collision=NO;
        do{
            NSString *seed=[NSString stringWithFormat:@"%@|%@|callback:%lu|%u",a.canonicalIdentity,a.title,(unsigned long)a.callbackArgumentIndex,serial++];
            a.actionID=ZNNHFNV1a32(seed);collision=NO;
            for(ZNNativeHookAction *e in self.mutableActions)if(e.actionID==a.actionID){collision=YES;break;}
        }while(collision);
        [self.mutableActions addObject:a];
        [self persist];
    }
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[native-hook-authoring] add id=%u %@ template=%@ callbackArg=%lu value=%@",
                                           a.actionID,a.canonicalIdentity,ZNNativeHookTemplateKey(a.templateKind),
                                           (unsigned long)a.callbackArgumentIndex,a.callbackValue?@"true":@"false"]];
    return [a copy];
}


- (ZNNativeHookAction *)addComplexStructTransformCandidate:(NSDictionary<NSString *,id> *)candidate
                                                     title:(NSString *)title
                                             argumentIndex:(NSUInteger)argumentIndex
                                              codecAssembly:(NSString *)codecAssembly
                                             codecNamespace:(NSString *)codecNamespace
                                                 codecClass:(NSString *)codecClass
                                              getterMethod:(NSString *)getterMethod
                                              setterMethod:(NSString *)setterMethod
                                                        min:(NSInteger)minValue
                                                        max:(NSInteger)maxValue
                                               defaultValue:(NSInteger)defaultValue
                                                      error:(NSString **)error {
    NSString *assembly=ZNNHTrim([candidate[@"assembly"] isKindOfClass:NSString.class]?candidate[@"assembly"]:@"");
    if(!assembly.length)assembly=@"Assembly-CSharp.dll";
    NSString *ns=ZNNHTrim([candidate[@"namespace"] isKindOfClass:NSString.class]?candidate[@"namespace"]:@"");
    NSString *cls=ZNNHTrim([candidate[@"class"] isKindOfClass:NSString.class]?candidate[@"class"]:@"");
    NSString *methodName=ZNNHTrim([candidate[@"method"] isKindOfClass:NSString.class]?candidate[@"method"]:@"");
    NSInteger argc=[candidate[@"argumentCount"] respondsToSelector:@selector(integerValue)]?[candidate[@"argumentCount"] integerValue]:-1;
    if(!cls.length||!methodName.length||argc<=0||argumentIndex>=(NSUInteger)argc){
        if(error)*error=@"ComplexStructTransform 方法身份/参数索引无效";
        return nil;
    }
    if(minValue<1||maxValue<minValue||maxValue>1000||defaultValue<minValue||defaultValue>maxValue){
        if(error)*error=@"倍率范围无效";
        return nil;
    }

    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    if(![abi[@"available"] boolValue]||params.count!=(NSUInteger)argc){
        if(error)*error=@"ComplexStructTransform 需要完整 IL2CPP 参数 ABI";
        return nil;
    }
    if([abi[@"generic"] boolValue]||[abi[@"inflated"] boolValue]){
        if(error)*error=@"ComplexStructTransform V1 不支持 generic/inflated 方法";
        return nil;
    }
    NSDictionary *param=params[argumentIndex];
    ZNIL2CPPABIValueKind kind=(ZNIL2CPPABIValueKind)[param[@"kind"] integerValue];
    BOOL eligible=(kind==ZNIL2CPPABIValueKindComplexValueType)||[param[@"byRef"] boolValue]||
                  kind==ZNIL2CPPABIValueKindPointer||kind==ZNIL2CPPABIValueKindObjectReference;
    if(!eligible){
        if(error)*error=@"ComplexStructTransform 参数必须是 complex/by-ref/pointer/object";
        return nil;
    }

    (void)codecAssembly;(void)codecNamespace;(void)codecClass;(void)getterMethod;(void)setterMethod;
    NSString *managedType=[param[@"name"] isKindOfClass:NSString.class]?param[@"name"]:@"";
    NSString *codecKey=ZNComplexStructCodecKeyForManagedType(managedType);
    if(!codecKey.length){
        if(error)*error=[NSString stringWithFormat:@"Complex Struct 未注册匹配 Codec：%@",managedType.length?managedType:@"?"];
        return nil;
    }
    NSString *normalizedType=ZNComplexStructNormalizedManagedType(managedType);

    NSMutableArray *types=[NSMutableArray arrayWithCapacity:params.count];
    for(NSDictionary *p in params)[types addObject:[p[@"name"] isKindOfClass:NSString.class]?p[@"name"]:@"?"];

    ZNNativeHookAction *a=[ZNNativeHookAction new];
    a.assembly=assembly;a.namespaceName=ns;a.className=cls;a.methodName=methodName;a.argumentCount=(NSUInteger)argc;
    a.parameterTypeNames=[types copy];a.signatureAvailable=YES;
    a.templateKind=ZNNativeHookTemplateComplexStructTransform;
    a.fieldArgumentIndex=argumentIndex;
    a.fieldArgumentMode=@"indirect-pointer";
    a.fieldOffset=0;
    a.fieldCodec=codecKey;
    a.codecAssembly=@"";a.codecNamespaceName=@"";a.codecClassName=normalizedType;
    a.codecGetterMethod=@"";a.codecSetterMethod=@"";a.codecGetterArgumentCount=0;a.codecSetterArgumentCount=0;
    a.minValue=minValue;a.maxValue=maxValue;a.defaultValue=defaultValue;
    a.title=ZNNHTrim(title).length?ZNNHTrim(title):[NSString stringWithFormat:@"%@ Struct Multiplier",methodName];
    a.featureDescription=[NSString stringWithFormat:@"Complex Struct Transform · arg%lu · decode/transform/encode · %@",
                          (unsigned long)argumentIndex+1,a.fieldCodec];
    a.fallbackRVA=[candidate[@"rva"] unsignedLongLongValue];

    @synchronized(self){
        uint32_t serial=0;BOOL collision=NO;
        do{
            NSString *seed=[NSString stringWithFormat:@"%@|%@|complex-struct:%lu:%@|%u",
                            a.canonicalIdentity,a.title,(unsigned long)a.fieldArgumentIndex,a.fieldCodec,serial++];
            a.actionID=ZNNHFNV1a32(seed);collision=NO;
            for(ZNNativeHookAction *e in self.mutableActions)if(e.actionID==a.actionID){collision=YES;break;}
        }while(collision);
        [self.mutableActions addObject:a];
        [self persist];
    }
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[native-hook-authoring] add id=%u %@ template=%@ arg=%lu codec=%@",
                                       a.actionID,a.canonicalIdentity,ZNNativeHookTemplateKey(a.templateKind),
                                       (unsigned long)a.fieldArgumentIndex,a.fieldCodec]];
    return [a copy];
}

- (ZNNativeHookAction *)addStructFieldTransformCandidate:(NSDictionary<NSString *,id> *)candidate
                                                   title:(NSString *)title
                                           argumentIndex:(NSUInteger)argumentIndex
                                            argumentMode:(NSString *)argumentMode
                                             fieldOffset:(uint64_t)fieldOffset
                                              fieldCodec:(NSString *)fieldCodec
                                           codecAssembly:(NSString *)codecAssembly
                                          codecNamespace:(NSString *)codecNamespace
                                              codecClass:(NSString *)codecClass
                                             getterMethod:(NSString *)getterMethod
                                             setterMethod:(NSString *)setterMethod
                                                   min:(NSInteger)minValue
                                                   max:(NSInteger)maxValue
                                          defaultValue:(NSInteger)defaultValue
                                                 error:(NSString **)error {
    NSString *assembly=ZNNHTrim([candidate[@"assembly"] isKindOfClass:NSString.class]?candidate[@"assembly"]:@"");
    if(!assembly.length)assembly=@"Assembly-CSharp.dll";
    NSString *ns=ZNNHTrim([candidate[@"namespace"] isKindOfClass:NSString.class]?candidate[@"namespace"]:@"");
    NSString *cls=ZNNHTrim([candidate[@"class"] isKindOfClass:NSString.class]?candidate[@"class"]:@"");
    NSString *methodName=ZNNHTrim([candidate[@"method"] isKindOfClass:NSString.class]?candidate[@"method"]:@"");
    NSInteger argc=[candidate[@"argumentCount"] respondsToSelector:@selector(integerValue)]?[candidate[@"argumentCount"] integerValue]:-1;
    if(!cls.length||!methodName.length||argc<=0||argumentIndex>=(NSUInteger)argc){if(error)*error=@"StructFieldTransform 方法身份/参数索引无效";return nil;}
    if(![argumentMode isEqualToString:@"indirect-pointer"]){if(error)*error=@"StructFieldTransform V1 仅支持 indirect-pointer 参数模式";return nil;}
    if(![fieldCodec isEqualToString:@"secure-long-accessor"]){if(error)*error=@"StructFieldTransform V1 仅支持 secure-long-accessor codec";return nil;}
    if(fieldOffset>0x100000ULL){if(error)*error=@"字段 offset 超出 V1 安全范围";return nil;}
    if(minValue<1||maxValue<minValue||maxValue>1000||defaultValue<minValue||defaultValue>maxValue){if(error)*error=@"倍率范围无效";return nil;}

    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    if(![abi[@"available"] boolValue]||params.count!=(NSUInteger)argc){if(error)*error=@"StructFieldTransform 需要完整 IL2CPP 参数 ABI";return nil;}
    NSDictionary *param=params[argumentIndex];
    ZNIL2CPPABIValueKind kind=(ZNIL2CPPABIValueKind)[param[@"kind"] integerValue];
    if(kind!=ZNIL2CPPABIValueKindComplexValueType&&kind!=ZNIL2CPPABIValueKindPointer&&kind!=ZNIL2CPPABIValueKindObjectReference){
        if(error)*error=@"StructFieldTransform V1 参数必须是 complex value/pointer/object-reference";
        return nil;
    }

    NSString *ca=ZNNHTrim(codecAssembly);if(!ca.length)ca=@"Percent.Scripting.Stdlib.dll";
    NSString *cn=ZNNHTrim(codecNamespace),*cc=ZNNHTrim(codecClass),*cg=ZNNHTrim(getterMethod),*cs=ZNNHTrim(setterMethod);
    if(!cc.length||!cg.length||!cs.length){if(error)*error=@"SecureLong codec 的类/getter/setter 不能为空";return nil;}

    NSMutableArray *types=[NSMutableArray arrayWithCapacity:params.count];
    for(NSDictionary *p in params)[types addObject:[p[@"name"] isKindOfClass:NSString.class]?p[@"name"]:@"?"];

    ZNNativeHookAction *a=[ZNNativeHookAction new];
    a.assembly=assembly;a.namespaceName=ns;a.className=cls;a.methodName=methodName;a.argumentCount=(NSUInteger)argc;
    a.parameterTypeNames=[types copy];a.signatureAvailable=YES;a.templateKind=ZNNativeHookTemplateStructFieldTransform;
    a.fieldArgumentIndex=argumentIndex;a.fieldArgumentMode=@"indirect-pointer";a.fieldOffset=fieldOffset;
    a.fieldCodec=@"secure-long-accessor";a.codecAssembly=ca;a.codecNamespaceName=cn;a.codecClassName=cc;
    a.codecGetterMethod=cg;a.codecSetterMethod=cs;a.codecGetterArgumentCount=0;a.codecSetterArgumentCount=1;
    a.minValue=minValue;a.maxValue=maxValue;a.defaultValue=defaultValue;
    a.title=ZNNHTrim(title).length?ZNNHTrim(title):[NSString stringWithFormat:@"%@ Field Multiplier",methodName];
    a.featureDescription=[NSString stringWithFormat:@"Struct Field Transform · arg%lu +0x%llX · SecureLong",
                          (unsigned long)argumentIndex,(unsigned long long)fieldOffset];
    a.fallbackRVA=[candidate[@"rva"] unsignedLongLongValue];

    @synchronized(self){
        uint32_t serial=0;BOOL collision=NO;
        do{
            NSString *seed=[NSString stringWithFormat:@"%@|%@|field:%lu:%llX:%@|%u",
                            a.canonicalIdentity,a.title,(unsigned long)a.fieldArgumentIndex,
                            (unsigned long long)a.fieldOffset,a.fieldCodec,serial++];
            a.actionID=ZNNHFNV1a32(seed);collision=NO;
            for(ZNNativeHookAction *e in self.mutableActions)if(e.actionID==a.actionID){collision=YES;break;}
        }while(collision);
        [self.mutableActions addObject:a];
        [self persist];
    }
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[native-hook-authoring] add id=%u %@ template=%@ arg=%lu offset=0x%llX codec=%@",
                                       a.actionID,a.canonicalIdentity,ZNNativeHookTemplateKey(a.templateKind),
                                       (unsigned long)a.fieldArgumentIndex,(unsigned long long)a.fieldOffset,a.fieldCodec]];
    return [a copy];
}

- (BOOL)updatePreparedDescriptor:(NSDictionary<NSString *,id> *)descriptor
                         atIndex:(NSUInteger)index
                           error:(NSString **)error {
    if(![descriptor isKindOfClass:NSDictionary.class]){
        if(error)*error=@"Prepared Native Hook descriptor 无效";
        return NO;
    }
    @synchronized(self){
        if(index>=self.mutableActions.count){
            if(error)*error=@"Prepared Native Hook index 越界";
            return NO;
        }
        uint64_t rva=[descriptor[@"rva"] unsignedLongLongValue];
        NSString *uuid=[descriptor[@"uuid"] isKindOfClass:NSString.class]?descriptor[@"uuid"]:@"";
        BOOL staticKnown=[descriptor[@"staticKnown"] boolValue];
        if(!rva||!uuid.length||!staticKnown){
            if(error)*error=@"Prepared Native Hook 缺少 RVA/UUID/static";
            return NO;
        }
        ZNNativeHookAction *a=self.mutableActions[index];
        a.preparedDescriptor=YES;
        a.preparedRVA=rva;
        a.preparedUUID=uuid;
        a.preparedStaticKnown=YES;
        a.preparedIsStatic=[descriptor[@"isStatic"] boolValue];
        a.preparedCodecGetterRVA=[descriptor[@"codecGetterRVA"] unsignedLongLongValue];
        a.preparedCodecSetterRVA=[descriptor[@"codecSetterRVA"] unsignedLongLongValue];

        // Keep authoring hints synchronized for diagnostics only.
        a.fallbackRVA=rva;
        a.fallbackUUID=uuid;
        [self persist];
    }
    return YES;
}

- (NSArray<ZNNativeHookAction *> *)actionsSnapshot {
    @synchronized(self){NSMutableArray *out=[NSMutableArray arrayWithCapacity:self.mutableActions.count];for(ZNNativeHookAction *a in self.mutableActions)[out addObject:[a copy]];return [out copy];}
}
- (BOOL)updateStaticPrepatchDescriptor:(NSDictionary<NSString *,id> *)descriptor
                               atIndex:(NSUInteger)index
                                 error:(NSString **)error {
    if(![descriptor isKindOfClass:NSDictionary.class]){
        if(error)*error=@"Static Prepared descriptor 无效";
        return NO;
    }
    @synchronized(self){
        if(index>=self.mutableActions.count){
            if(error)*error=@"Static Prepared Native Hook index 越界";
            return NO;
        }
        uint64_t slot=[descriptor[@"hookSlotRVA"] unsignedLongLongValue];
        uint64_t trampoline=[descriptor[@"trampolineRVA"] unsignedLongLongValue];
        uint64_t cave=[descriptor[@"codeCaveRVA"] unsignedLongLongValue];
        uint32_t displaced=[descriptor[@"displacedInstruction"] unsignedIntValue];
        if(!slot||!trampoline||!cave||!displaced){
            if(error)*error=@"Static Prepared descriptor 缺少 slot/trampoline/cave/instruction";
            return NO;
        }
        ZNNativeHookAction *a=self.mutableActions[index];
        a.staticPrepatch=YES;
        a.staticHookSlotRVA=slot;
        a.staticTrampolineRVA=trampoline;
        a.staticCodeCaveRVA=cave;
        a.staticDisplacedInstruction=displaced;
        [self persist];
    }
    return YES;
}

- (BOOL)updateTitle:(NSString *)title atIndex:(NSUInteger)index {
    @synchronized(self){if(index>=self.mutableActions.count)return NO;ZNNativeHookAction *a=self.mutableActions[index];NSString *v=ZNNHTrim(title);a.title=v.length?v:a.methodName;[self persist];return YES;}
}
- (BOOL)updateDescription:(NSString *)featureDescription atIndex:(NSUInteger)index {
    @synchronized(self){if(index>=self.mutableActions.count)return NO;self.mutableActions[index].featureDescription=ZNNHTrim(featureDescription);[self persist];return YES;}
}
- (BOOL)removeActionAtIndex:(NSUInteger)index {
    @synchronized(self){if(index>=self.mutableActions.count)return NO;[self.mutableActions removeObjectAtIndex:index];[self persist];return YES;}
}
- (void)clear {@synchronized(self){[self.mutableActions removeAllObjects];[self persist];}}

@end
