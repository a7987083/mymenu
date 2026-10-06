#import "ZNDirectNativeCallEngine.h"
#import "ZNIL2CPPABIMetadata.h"
#import "ZNIL2CPPInstanceResolver.h"
#import "ZNIL2CPPInstanceSelectionV2.h"
#import "ZNIL2CPPResolver.h"
#import "ZNIL2CPPRuntimeCommon.h"
#import "ZNComplexStructCodec.h"
#import "ZNComplexStructCodecResolver.h"
#import "ZNPatchCore.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

@interface ZNDirectNativeCallEngine ()
@property(nonatomic,copy,readwrite) NSDictionary<NSString *,id> *lastResult;
@end

static BOOL ZNDNCGPRKind(ZNIL2CPPABIValueKind kind) {
    return kind==ZNIL2CPPABIValueKindBool ||
           kind==ZNIL2CPPABIValueKindSigned32 ||
           kind==ZNIL2CPPABIValueKindUnsigned32 ||
           kind==ZNIL2CPPABIValueKindSigned64 ||
           kind==ZNIL2CPPABIValueKindUnsigned64 ||
           kind==ZNIL2CPPABIValueKindPointer ||
           kind==ZNIL2CPPABIValueKindObjectReference;
}

static BOOL ZNDNCParseUnsigned(NSString *text, uint64_t *out) {
    NSString *s=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!s.length)return NO;
    const char *raw=s.UTF8String;
    if(!raw)return NO;
    errno=0; char *end=NULL;
    unsigned long long v=strtoull(raw,&end,0);
    if(errno||end==raw||*end!='\0')return NO;
    if(out)*out=(uint64_t)v;
    return YES;
}

static BOOL ZNDNCParseSigned(NSString *text, int64_t *out) {
    NSString *s=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!s.length)return NO;
    const char *raw=s.UTF8String;
    if(!raw)return NO;
    errno=0; char *end=NULL;
    long long v=strtoll(raw,&end,0);
    if(errno||end==raw||*end!='\0')return NO;
    if(out)*out=(int64_t)v;
    return YES;
}

static BOOL ZNDNCIsObscuredIntParam(NSDictionary *param) {
    if([param[@"byRef"] boolValue])return NO;
    ZNIL2CPPABIValueKind kind=(ZNIL2CPPABIValueKind)[param[@"kind"] integerValue];
    if(kind!=ZNIL2CPPABIValueKindComplexValueType)return NO;
    NSString *type=[param[@"name"] isKindOfClass:NSString.class]?param[@"name"]:@"";
    return [ZNComplexStructNormalizedManagedType(type) isEqualToString:@"CodeStage.AntiCheat.ObscuredTypes.ObscuredInt"];
}

typedef void *(*ZNDNCDomainGetFn)(void);
typedef const void **(*ZNDNCDomainGetAssembliesFn)(const void *,size_t *);
typedef const void *(*ZNDNCAssemblyGetImageFn)(const void *);
typedef void *(*ZNDNCClassFromNameFn)(const void *,const char *,const char *);
typedef int32_t (*ZNDNCClassValueSizeFn)(void *,uint32_t *);

static int32_t ZNDNCObscuredIntValueSize(NSString *imagePath, NSString **error) {
    ZNDNCDomainGetFn domainGet=(ZNDNCDomainGetFn)ZNIL2CPPResolveSymbol(imagePath,"il2cpp_domain_get");
    ZNDNCDomainGetAssembliesFn assembliesFn=(ZNDNCDomainGetAssembliesFn)ZNIL2CPPResolveSymbol(imagePath,"il2cpp_domain_get_assemblies");
    ZNDNCAssemblyGetImageFn imageFn=(ZNDNCAssemblyGetImageFn)ZNIL2CPPResolveSymbol(imagePath,"il2cpp_assembly_get_image");
    ZNDNCClassFromNameFn classFn=(ZNDNCClassFromNameFn)ZNIL2CPPResolveSymbol(imagePath,"il2cpp_class_from_name");
    ZNDNCClassValueSizeFn sizeFn=(ZNDNCClassValueSizeFn)ZNIL2CPPResolveSymbol(imagePath,"il2cpp_class_value_size");
    if(!domainGet||!assembliesFn||!imageFn||!classFn||!sizeFn){
        if(error)*error=@"ObscuredInt bridge 缺少 class/value-size Runtime API";
        return 0;
    }
    void *domain=domainGet(); if(!domain){if(error)*error=@"ObscuredInt bridge：IL2CPP domain 不可用";return 0;}
    size_t count=0; const void **assemblies=assembliesFn(domain,&count);
    if(!assemblies||!count){if(error)*error=@"ObscuredInt bridge：程序集列表为空";return 0;}
    void *klass=NULL;
    for(size_t i=0;i<count&&!klass;i++){
        const void *image=imageFn(assemblies[i]);
        if(image)klass=classFn(image,"CodeStage.AntiCheat.ObscuredTypes","ObscuredInt");
    }
    if(!klass){if(error)*error=@"ObscuredInt bridge：找不到目标 ValueType";return 0;}
    uint32_t align=0; int32_t size=sizeFn(klass,&align);
    if(size<=16||size>256){
        if(error)*error=[NSString stringWithFormat:@"ObscuredInt bridge：value-size=%d，不符合 ARM64 indirect struct 条件",size];
        return 0;
    }
    return size;
}

static BOOL ZNDNCPrepareObscuredIntIndirect(NSString *text, void **outBuffer, NSString **error) {
    if(outBuffer)*outBuffer=NULL;
    int64_t parsed=0;
    if(!ZNDNCParseSigned(text,&parsed)||parsed<INT32_MIN||parsed>INT32_MAX){
        if(error)*error=@"ObscuredInt 参数必须是 int32";
        return NO;
    }

    ZNIL2CPPResolver *resolver=[ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    if(!resolver.isAvailable){if(error)*error=resolver.lastError?:@"IL2CPP Resolver 不可用";return NO;}

    NSString *inner=nil;
    NSDictionary *codec=[[ZNComplexStructCodecResolver sharedResolver]
        resolveManagedType:@"CodeStage.AntiCheat.ObscuredTypes.ObscuredInt" error:&inner];
    if(!codec){
        if(error)*error=inner?:@"ObscuredInt Codec resolve 失败";
        return NO;
    }

    int32_t valueSize=ZNDNCObscuredIntValueSize(resolver.unityPath,&inner);
    if(valueSize<=0){if(error)*error=inner?:@"ObscuredInt value-size 不可用";return NO;}

    typedef int32_t (*EncryptFn)(int32_t,int32_t,uintptr_t);
    typedef void (*SetEncryptedFn)(uintptr_t,int32_t,int32_t,uintptr_t);
    typedef int32_t (*GetDecryptedFn)(uintptr_t,uintptr_t);
    EncryptFn encrypt=(EncryptFn)[codec[@"function2"] unsignedLongLongValue];
    SetEncryptedFn setEncrypted=(SetEncryptedFn)[codec[@"function3"] unsignedLongLongValue];
    GetDecryptedFn getDecrypted=(GetDecryptedFn)[codec[@"function0"] unsignedLongLongValue];
    uintptr_t encryptMI=[codec[@"methodInfo2"] unsignedLongLongValue];
    uintptr_t setMI=[codec[@"methodInfo3"] unsignedLongLongValue];
    uintptr_t getMI=[codec[@"methodInfo0"] unsignedLongLongValue];
    if(!encrypt||!setEncrypted||!getDecrypted||!encryptMI||!setMI||!getMI){
        if(error)*error=@"ObscuredInt Codec 缺少 Encrypt/SetEncrypted/GetDecrypted";
        return NO;
    }

    void *buffer=calloc(1,(size_t)valueSize);
    if(!buffer){if(error)*error=@"ObscuredInt bridge 分配失败";return NO;}

    const int32_t key=(int32_t)0x6A09E667u;
    int32_t encrypted=encrypt((int32_t)parsed,key,encryptMI);
    setEncrypted((uintptr_t)buffer,encrypted,key,setMI);
    int32_t roundTrip=getDecrypted((uintptr_t)buffer,getMI);
    if(roundTrip!=(int32_t)parsed){
        free(buffer);
        if(error)*error=[NSString stringWithFormat:@"ObscuredInt Codec round-trip 失败：%d != %d",roundTrip,(int32_t)parsed];
        return NO;
    }
    if(outBuffer)*outBuffer=buffer;
    return YES;
}

static BOOL ZNDNCEncodeArgument(NSString *text, NSDictionary *param, uintptr_t *out, NSString **error) {
    ZNIL2CPPABIValueKind kind=(ZNIL2CPPABIValueKind)[param[@"kind"] integerValue];
    if([param[@"byRef"] boolValue] || !ZNDNCGPRKind(kind)){
        if(error)*error=[NSString stringWithFormat:@"Direct Native Call V1 不支持参数 ABI：%@",param[@"name"]?:@"?"];
        return NO;
    }
    if(kind==ZNIL2CPPABIValueKindBool){
        NSString *lower=[[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
        if([lower isEqualToString:@"true"]||[lower isEqualToString:@"yes"]||[lower isEqualToString:@"1"]){if(out)*out=1;return YES;}
        if([lower isEqualToString:@"false"]||[lower isEqualToString:@"no"]||[lower isEqualToString:@"0"]){if(out)*out=0;return YES;}
        if(error)*error=@"bool 参数请输入 true/false 或 1/0";
        return NO;
    }
    if(kind==ZNIL2CPPABIValueKindSigned32||kind==ZNIL2CPPABIValueKindSigned64){
        int64_t v=0;
        if(!ZNDNCParseSigned(text,&v)){if(error)*error=@"Direct Native Call 有符号整数参数格式错误";return NO;}
        if(kind==ZNIL2CPPABIValueKindSigned32 && (v<INT32_MIN||v>INT32_MAX)){if(error)*error=@"Direct Native Call int32 参数越界";return NO;}
        if(out)*out=(uintptr_t)v;
        return YES;
    }
    uint64_t v=0;
    if(!ZNDNCParseUnsigned(text,&v)){if(error)*error=@"Direct Native Call 无符号/指针参数格式错误";return NO;}
    if(kind==ZNIL2CPPABIValueKindUnsigned32 && v>UINT32_MAX){if(error)*error=@"Direct Native Call uint32 参数越界";return NO;}
    if(out)*out=(uintptr_t)v;
    return YES;
}

typedef uintptr_t (*ZNDNCFn0)(void);
typedef uintptr_t (*ZNDNCFn1)(uintptr_t);
typedef uintptr_t (*ZNDNCFn2)(uintptr_t,uintptr_t);
typedef uintptr_t (*ZNDNCFn3)(uintptr_t,uintptr_t,uintptr_t);
typedef uintptr_t (*ZNDNCFn4)(uintptr_t,uintptr_t,uintptr_t,uintptr_t);
typedef uintptr_t (*ZNDNCFn5)(uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t);
typedef uintptr_t (*ZNDNCFn6)(uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t);
typedef uintptr_t (*ZNDNCFn7)(uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t);
typedef uintptr_t (*ZNDNCFn8)(uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t);

static uintptr_t ZNDNCCall(uintptr_t target, const uintptr_t *a, NSUInteger count) {
    switch(count){
        case 0:return ((ZNDNCFn0)target)();
        case 1:return ((ZNDNCFn1)target)(a[0]);
        case 2:return ((ZNDNCFn2)target)(a[0],a[1]);
        case 3:return ((ZNDNCFn3)target)(a[0],a[1],a[2]);
        case 4:return ((ZNDNCFn4)target)(a[0],a[1],a[2],a[3]);
        case 5:return ((ZNDNCFn5)target)(a[0],a[1],a[2],a[3],a[4]);
        case 6:return ((ZNDNCFn6)target)(a[0],a[1],a[2],a[3],a[4],a[5]);
        case 7:return ((ZNDNCFn7)target)(a[0],a[1],a[2],a[3],a[4],a[5],a[6]);
        case 8:return ((ZNDNCFn8)target)(a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7]);
        default:return 0;
    }
}

@implementation ZNDirectNativeCallEngine
+ (instancetype)sharedEngine {
    static ZNDirectNativeCallEngine *engine;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{engine=[ZNDirectNativeCallEngine new];engine.lastResult=@{};});
    return engine;
}
- (BOOL)prepare:(NSString **)error {(void)error;return YES;}

- (BOOL)supportsCandidate:(NSDictionary<NSString *,id> *)candidate reason:(NSString **)reason {
    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    if(![abi[@"available"] boolValue]){if(reason)*reason=abi[@"reason"]?:@"ABI 不可用";return NO;}
    if([abi[@"generic"] boolValue]||[abi[@"inflated"] boolValue]){if(reason)*reason=@"Direct Native Call V1 不支持 generic/inflated";return NO;}
    uintptr_t target=[abi[@"methodPointer"] unsignedLongLongValue];
    uintptr_t methodInfo=[abi[@"methodInfo"] unsignedLongLongValue];
    if(!target||!methodInfo){if(reason)*reason=@"Direct Native Call 缺少 methodPointer/MethodInfo";return NO;}
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    for(NSDictionary *p in params){
        if([p[@"byRef"] boolValue]){
            if(reason)*reason=[NSString stringWithFormat:@"参数 %@ 是 by-ref；Direct Native Call fail-closed",p[@"name"]?:@"?"];
            return NO;
        }
        ZNIL2CPPABIValueKind pk=(ZNIL2CPPABIValueKind)[p[@"kind"] integerValue];
        if(ZNDNCGPRKind(pk))continue;
        if(ZNDNCIsObscuredIntParam(p))continue; // exact codec-backed ARM64 indirect struct bridge
        if(reason)*reason=[NSString stringWithFormat:@"参数 %@ 不是 GPR-safe，且没有已验证的 indirect struct codec",p[@"name"]?:@"?"];
        return NO;
    }
    NSDictionary *ret=[abi[@"return"] isKindOfClass:NSDictionary.class]?abi[@"return"]:@{};
    ZNIL2CPPABIValueKind rk=(ZNIL2CPPABIValueKind)[ret[@"kind"] integerValue];
    if(rk!=ZNIL2CPPABIValueKindVoid&&!ZNDNCGPRKind(rk)){
        if(reason)*reason=[NSString stringWithFormat:@"返回 %@ 不是 GPR-safe；V1 fail-closed",ret[@"name"]?:@"?"];
        return NO;
    }
    NSUInteger total=params.count+1+([abi[@"instance"] boolValue]?1u:0u); // + hidden MethodInfo
    if(total>8){if(reason)*reason=@"Direct Native Call V1 超过 x0~x7 参数预算";return NO;}
    return YES;
}

- (NSDictionary<NSString *,id> *)executeCandidate:(NSDictionary<NSString *,id> *)candidate
                                    argumentValues:(NSArray<NSString *> *)argumentValues
                                             error:(NSString **)error {
    NSString *reason=nil;
    if(![self supportsCandidate:candidate reason:&reason]){if(error)*error=reason;return nil;}
    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSArray *params=abi[@"parameters"];
    if(argumentValues.count!=params.count){
        if(error)*error=[NSString stringWithFormat:@"Direct Native Call 参数数量不匹配：需要%lu，当前%lu",
                         (unsigned long)params.count,(unsigned long)argumentValues.count];
        return nil;
    }

    uintptr_t argv[8]={0}; void *ownedStructs[8]={0}; NSUInteger ownedCount=0; NSUInteger n=0;
    BOOL instance=[abi[@"instance"] boolValue];
    uintptr_t receiver=0;
    if(instance){
        NSString *assembly=[candidate[@"assembly"] isKindOfClass:NSString.class]?candidate[@"assembly"]:@"Assembly-CSharp.dll";
        NSString *ns=[candidate[@"namespace"] isKindOfClass:NSString.class]?candidate[@"namespace"]:@"";
        NSString *cls=[candidate[@"class"] isKindOfClass:NSString.class]?candidate[@"class"]:@"";
        ZNIL2CPPInstanceResolver *resolver=[ZNIL2CPPInstanceResolver sharedResolver];
        receiver=[resolver znm44_selectedInstanceForAssembly:assembly namespace:ns className:cls];
        if(!receiver){
            NSString *diag=nil,*inner=nil;
            receiver=(uintptr_t)[resolver resolveUniqueInstanceForAssembly:assembly namespace:ns className:cls diagnostics:&diag error:&inner];
        }
        if(!receiver){if(error)*error=@"Direct Native Call instance 方法需要先选择唯一实例";return nil;}
        argv[n++]=receiver;
    }
    for(NSUInteger i=0;i<params.count;i++){
        NSDictionary *param=params[i];
        if(ZNDNCIsObscuredIntParam(param)){
            void *buffer=NULL;NSString *inner=nil;
            if(!ZNDNCPrepareObscuredIntIndirect(argumentValues[i],&buffer,&inner)){
                for(NSUInteger j=0;j<ownedCount;j++)free(ownedStructs[j]);
                if(error)*error=[NSString stringWithFormat:@"参数%lu：%@",(unsigned long)i+1,inner?:@"ObscuredInt 编码失败"];
                return nil;
            }
            ownedStructs[ownedCount++]=buffer;
            argv[n++]=(uintptr_t)buffer;
            continue;
        }
        uintptr_t raw=0;NSString *inner=nil;
        if(!ZNDNCEncodeArgument(argumentValues[i],param,&raw,&inner)){
            for(NSUInteger j=0;j<ownedCount;j++)free(ownedStructs[j]);
            if(error)*error=[NSString stringWithFormat:@"参数%lu：%@",(unsigned long)i+1,inner?:@"编码失败"];
            return nil;
        }
        argv[n++]=raw;
    }
    uintptr_t methodInfo=[abi[@"methodInfo"] unsignedLongLongValue];
    argv[n++]=methodInfo;
    uintptr_t target=[abi[@"methodPointer"] unsignedLongLongValue];
    uintptr_t rawReturn=ZNDNCCall(target,argv,n);
    for(NSUInteger j=0;j<ownedCount;j++)free(ownedStructs[j]);

    NSDictionary *ret=abi[@"return"]?:@{};
    ZNIL2CPPABIValueKind rk=(ZNIL2CPPABIValueKind)[ret[@"kind"] integerValue];
    id display=[NSNull null];
    if(rk==ZNIL2CPPABIValueKindBool)display=@((BOOL)(rawReturn&1u));
    else if(rk==ZNIL2CPPABIValueKindSigned32)display=@((int32_t)rawReturn);
    else if(rk==ZNIL2CPPABIValueKindUnsigned32)display=@((uint32_t)rawReturn);
    else if(rk==ZNIL2CPPABIValueKindSigned64)display=@((int64_t)rawReturn);
    else if(rk!=ZNIL2CPPABIValueKindVoid)display=@((uint64_t)rawReturn);

    self.lastResult=@{@"ok":@YES,
                      @"methodPointer":@(target),
                      @"methodInfo":@(methodInfo),
                      @"instance":@(receiver),
                      @"returnType":ret[@"name"]?:@"void",
                      @"returnKind":@(rk),
                      @"returnValue":display};
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[direct-native-call] %@ target=0x%llX instance=0x%llX return=%@",
      candidate[@"canonical"]?:candidate[@"method"]?:@"method",
      (unsigned long long)target,(unsigned long long)receiver,display]];
    return self.lastResult;
}
@end
