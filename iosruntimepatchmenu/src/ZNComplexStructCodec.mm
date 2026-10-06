#import "ZNComplexStructCodec.h"
#import "ZNNativeHookTemplate.h"

NSString * const ZNComplexStructCodecSecureLongWholeAccessor=@"secure-long-whole-accessor";
NSString * const ZNComplexStructCodecObscuredInt=@"codestage-obscured-int";

NSString *ZNComplexStructNormalizedManagedType(NSString *managedTypeName) {
    NSString *value=[managedTypeName?:@"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while([value hasSuffix:@"&"]||[value hasSuffix:@"*"]){
        value=[[value substringToIndex:value.length-1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return value;
}

NSString *ZNComplexStructCodecKeyForManagedType(NSString *managedTypeName) {
    NSString *type=ZNComplexStructNormalizedManagedType(managedTypeName);
    if([type isEqualToString:@"CodeStage.AntiCheat.ObscuredTypes.ObscuredInt"])
        return ZNComplexStructCodecObscuredInt;
    if([type isEqualToString:@"Percent.Scripting.Stdlib.SecureValue.SecureLong"] ||
       [type isEqualToString:@"SecureLong"])
        return ZNComplexStructCodecSecureLongWholeAccessor;
    return nil;
}

typedef int64_t (*ZNCSLongGetterFn)(uintptr_t,uintptr_t);
typedef void (*ZNCSLongSetterFn)(uintptr_t,int64_t,uintptr_t);

static BOOL ZNCSecureLongWholeTransform(uintptr_t base,
                                        const ZNComplexStructResolvedFunctions *f,
                                        int32_t multiplier,
                                        int64_t *before,
                                        int64_t *after) {
    if(base<0x1000||!f||!f->function0||!f->function1)return NO;
    ZNCSLongGetterFn getter=(ZNCSLongGetterFn)f->function0;
    ZNCSLongSetterFn setter=(ZNCSLongSetterFn)f->function1;
    int64_t input=getter(base,f->methodInfo0);
    int64_t output=ZNNativeHookScaleInt64(input,multiplier);
    setter(base,output,f->methodInfo1);
    if(before)*before=input;
    if(after)*after=output;
    return YES;
}

typedef int32_t (*ZNCSObscuredGetDecryptedFn)(uintptr_t,uintptr_t);
typedef int32_t (*ZNCSObscuredGetEncryptedModernFn)(uintptr_t,int32_t *,uintptr_t);
typedef int32_t (*ZNCSObscuredEncryptFn)(int32_t,int32_t,uintptr_t);
typedef void (*ZNCSObscuredSetEncryptedModernFn)(uintptr_t,int32_t,int32_t,uintptr_t);

static BOOL ZNCSObscuredIntTransform(uintptr_t base,
                                     const ZNComplexStructResolvedFunctions *f,
                                     int32_t multiplier,
                                     int64_t *before,
                                     int64_t *after) {
    if(base<0x1000||!f||f->variant!=1||
       !f->function0||!f->function1||!f->function2||!f->function3)return NO;

    ZNCSObscuredGetDecryptedFn getDecrypted=(ZNCSObscuredGetDecryptedFn)f->function0;
    ZNCSObscuredGetEncryptedModernFn getEncrypted=(ZNCSObscuredGetEncryptedModernFn)f->function1;
    ZNCSObscuredEncryptFn encrypt=(ZNCSObscuredEncryptFn)f->function2;
    ZNCSObscuredSetEncryptedModernFn setEncrypted=(ZNCSObscuredSetEncryptedModernFn)f->function3;

    int32_t key=0;
    (void)getEncrypted(base,&key,f->methodInfo1);
    int32_t input=getDecrypted(base,f->methodInfo0);
    int32_t output=ZNNativeHookScaleInt32(input,multiplier);
    int32_t encrypted=encrypt(output,key,f->methodInfo2);
    setEncrypted(base,encrypted,key,f->methodInfo3);

    if(before)*before=(int64_t)input;
    if(after)*after=(int64_t)output;
    return YES;
}

@interface ZNComplexStructCodecRegistry ()
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSValue *> *transforms;
@end

@implementation ZNComplexStructCodecRegistry
+ (instancetype)sharedRegistry {
    static ZNComplexStructCodecRegistry *registry;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{registry=[ZNComplexStructCodecRegistry new];registry.transforms=[NSMutableDictionary dictionary];});
    return registry;
}
- (void)registerCodecKey:(NSString *)key transform:(ZNComplexStructTransformFn)transform {
    if(!key.length||!transform)return;
    @synchronized(self){self.transforms[key]=[NSValue valueWithPointer:(const void *)transform];}
}
- (NSValue *)transformValueForCodecKey:(NSString *)key {
    if(!key.length)return nil;
    @synchronized(self){return self.transforms[key];}
}
- (BOOL)supportsCodecKey:(NSString *)key {
    return [self transformValueForCodecKey:key]!=nil;
}
@end

void ZNRegisterBuiltInComplexStructCodecs(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        ZNComplexStructCodecRegistry *registry=[ZNComplexStructCodecRegistry sharedRegistry];
        [registry registerCodecKey:ZNComplexStructCodecSecureLongWholeAccessor transform:ZNCSecureLongWholeTransform];
        [registry registerCodecKey:ZNComplexStructCodecObscuredInt transform:ZNCSObscuredIntTransform];
    });
}
