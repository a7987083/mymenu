#import "ZNComplexStructCodecResolver.h"
#import "ZNIL2CPPHybridFinder.h"

static NSDictionary *ZNCSResolveExpression(NSString *expression, NSString **error) {
    NSString *local=nil;
    NSDictionary *candidate=[[ZNIL2CPPHybridFinder sharedFinder] resolveExpression:expression error:&local];
    uintptr_t pointer=[candidate[@"methodPointer"] unsignedLongLongValue];
    uintptr_t methodInfo=[candidate[@"methodInfo"] unsignedLongLongValue];
    if(!candidate||!pointer||!methodInfo){
        if(error)*error=local.length?local:[NSString stringWithFormat:@"Codec accessor resolve 失败：%@",expression];
        return nil;
    }
    return candidate;
}

@implementation ZNComplexStructCodecResolver
+ (instancetype)sharedResolver {
    static ZNComplexStructCodecResolver *resolver;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{resolver=[ZNComplexStructCodecResolver new];});
    return resolver;
}

- (NSDictionary<NSString *,id> *)resolveManagedType:(NSString *)managedTypeName error:(NSString **)error {
    NSString *type=ZNComplexStructNormalizedManagedType(managedTypeName);
    NSString *codecKey=ZNComplexStructCodecKeyForManagedType(type);
    if(!codecKey.length){
        if(error)*error=[NSString stringWithFormat:@"Complex Struct 未注册匹配 Codec：%@",type.length?type:@"?"];
        return nil;
    }

    if([codecKey isEqualToString:ZNComplexStructCodecSecureLongWholeAccessor]){
        NSString *owner=@"Percent.Scripting.Stdlib.SecureValue.SecureLong";
        NSString *inner=nil;
        NSDictionary *getter=ZNCSResolveExpression([NSString stringWithFormat:@"%@::get_Value/0",owner],&inner);
        if(!getter){if(error)*error=inner;return nil;}
        NSDictionary *setter=ZNCSResolveExpression([NSString stringWithFormat:@"%@::set_Value/1",owner],&inner);
        if(!setter){if(error)*error=inner;return nil;}
        return @{
            @"codecKey":codecKey,
            @"managedType":type,
            @"displayName":@"SecureLong",
            @"variant":@1,
            @"function0":getter[@"methodPointer"],@"methodInfo0":getter[@"methodInfo"],
            @"function1":setter[@"methodPointer"],@"methodInfo1":setter[@"methodInfo"],
            @"function2":@0,@"methodInfo2":@0,@"function3":@0,@"methodInfo3":@0
        };
    }

    if([codecKey isEqualToString:ZNComplexStructCodecObscuredInt]){
        NSString *owner=@"CodeStage.AntiCheat.ObscuredTypes.ObscuredInt";
        NSString *inner=nil;
        NSDictionary *getDecrypted=ZNCSResolveExpression([NSString stringWithFormat:@"%@::GetDecrypted/0",owner],&inner);
        if(!getDecrypted){if(error)*error=inner;return nil;}

        // Modern ACTk exact path: key-aware get/set keeps the instance's own
        // crypto key instead of substituting a foreign codec or global key.
        NSDictionary *getEncrypted=ZNCSResolveExpression([NSString stringWithFormat:@"%@::GetEncrypted/1",owner],&inner);
        NSDictionary *encrypt=ZNCSResolveExpression([NSString stringWithFormat:@"%@::Encrypt/2",owner],&inner);
        NSDictionary *setEncrypted=ZNCSResolveExpression([NSString stringWithFormat:@"%@::SetEncrypted/2",owner],&inner);
        if(!getEncrypted||!encrypt||!setEncrypted){
            if(error)*error=[NSString stringWithFormat:
                @"ObscuredInt Codec 不完整：需要 GetDecrypted/0 + GetEncrypted/1 + Encrypt/2 + SetEncrypted/2；%@",
                inner?:@"目标版本 accessor 不匹配"];
            return nil;
        }

        return @{
            @"codecKey":codecKey,
            @"managedType":type,
            @"displayName":@"ObscuredInt",
            @"variant":@1,
            @"function0":getDecrypted[@"methodPointer"],@"methodInfo0":getDecrypted[@"methodInfo"],
            @"function1":getEncrypted[@"methodPointer"],@"methodInfo1":getEncrypted[@"methodInfo"],
            @"function2":encrypt[@"methodPointer"],@"methodInfo2":encrypt[@"methodInfo"],
            @"function3":setEncrypted[@"methodPointer"],@"methodInfo3":setEncrypted[@"methodInfo"]
        };
    }

    if(error)*error=[NSString stringWithFormat:@"Complex Struct Codec 未实现：%@",codecKey];
    return nil;
}
@end
