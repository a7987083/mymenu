#import "ZNNativeHookBuildPrepare.h"

#import "ZNNativeHookAction.h"
#import "ZNIL2CPPResolver.h"

#import <dlfcn.h>
#import <mach-o/loader.h>
#import <stdint.h>
#import <uuid/uuid.h>

static const uint32_t kZNM69MethodAttributeStatic = 0x0010u;
typedef uint32_t (*ZNM69MethodGetFlagsFn)(const void *, uint32_t *);

static NSString *ZNM69Trim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *ZNM69UUIDForHeader(const struct mach_header_64 *mh) {
    if(!mh || mh->magic!=MH_MAGIC_64)return @"";
    const uint8_t *cursor=(const uint8_t *)(mh+1);
    const uint8_t *limit=cursor+mh->sizeofcmds;
    if(mh->ncmds>4096 || mh->sizeofcmds>16*1024*1024)return @"";
    for(uint32_t i=0;i<mh->ncmds;i++){
        if(cursor+sizeof(struct load_command)>limit)return @"";
        const struct load_command *lc=(const struct load_command *)cursor;
        if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit)return @"";
        if(lc->cmd==LC_UUID && lc->cmdsize>=sizeof(struct uuid_command)){
            const struct uuid_command *uc=(const struct uuid_command *)cursor;
            uuid_t bytes={0};
            memcpy(bytes,uc->uuid,sizeof(bytes));
            NSUUID *uuid=[[NSUUID alloc] initWithUUIDBytes:bytes];
            return uuid.UUIDString.uppercaseString ?: @"";
        }
        cursor+=lc->cmdsize;
    }
    return @"";
}

static BOOL ZNM69PreparedAddress(uintptr_t pointer,
                                 uintptr_t *outBase,
                                 uint64_t *outRVA,
                                 NSString **outUUID,
                                 NSString **error) {
    if(!pointer){
        if(error)*error=@"Prepared Native Hook methodPointer 为空";
        return NO;
    }
    Dl_info info={0};
    if(dladdr((const void *)pointer,&info)==0 || !info.dli_fbase){
        if(error)*error=@"Prepared Native Hook 无法定位目标 Mach-O";
        return NO;
    }
    NSString *path=info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname] : @"";
    BOOL unity=[path.lastPathComponent isEqualToString:@"UnityFramework"] ||
               [path rangeOfString:@"UnityFramework.framework/UnityFramework"
                           options:NSCaseInsensitiveSearch].location!=NSNotFound;
    if(!unity){
        if(error)*error=[NSString stringWithFormat:@"Prepared Native Hook target 不在 UnityFramework：%@",
                         path.lastPathComponent ?: @"unknown"];
        return NO;
    }
    uintptr_t base=(uintptr_t)info.dli_fbase;
    if(pointer<base){
        if(error)*error=@"Prepared Native Hook RVA 下溢";
        return NO;
    }
    uint64_t rva=(uint64_t)(pointer-base);
    if(!rva || (rva&3ULL)!=0){
        if(error)*error=[NSString stringWithFormat:@"Prepared Native Hook RVA 无效：0x%llX",
                         (unsigned long long)rva];
        return NO;
    }
    NSString *uuid=ZNM69UUIDForHeader((const struct mach_header_64 *)base);
    if(!uuid.length){
        if(error)*error=@"Prepared Native Hook 无法读取 UnityFramework UUID";
        return NO;
    }
    if(outBase)*outBase=base;
    if(outRVA)*outRVA=rva;
    if(outUUID)*outUUID=uuid;
    return YES;
}

static NSDictionary<NSString *,id> *ZNM69ResolvePreparedDescriptor(
    ZNNativeHookAction *action,
    ZNIL2CPPResolver *resolver,
    ZNM69MethodGetFlagsFn methodGetFlags,
    NSString **error)
{
    NSDictionary *resolved=[resolver resolveMethodAssembly:action.assembly
                                                 namespace:action.namespaceName ?: @""
                                                 className:action.className
                                                    method:action.methodName
                                             argumentCount:(NSInteger)action.argumentCount];
    uintptr_t methodInfo=[resolved[@"methodInfo"] unsignedLongLongValue];
    uintptr_t pointer=[resolved[@"methodPointer"] unsignedLongLongValue];
    if(!methodInfo||!pointer){
        if(error)*error=[NSString stringWithFormat:@"生成 Native Hook descriptor 失败：%@",
                         action.canonicalIdentity ?: action.methodName];
        return nil;
    }

    uintptr_t unityBase=0;
    uint64_t rva=0;
    NSString *uuid=nil;
    if(!ZNM69PreparedAddress(pointer,&unityBase,&rva,&uuid,error))return nil;

    uint32_t implFlags=0;
    uint32_t flags=methodGetFlags((const void *)methodInfo,&implFlags);
    BOOL isStatic=(flags&kZNM69MethodAttributeStatic)!=0;

    uint64_t codecGetterRVA=0,codecSetterRVA=0;
    // Legacy field-offset codec still bakes two accessor RVAs.
    // ComplexStructTransform resolves its exact type codec during capability
    // prewarm/install because codecs may require more than two functions.
    if(action.templateKind==ZNNativeHookTemplateStructFieldTransform){
        NSDictionary *getter=[resolver resolveMethodAssembly:action.codecAssembly
                                                   namespace:action.codecNamespaceName ?: @""
                                                   className:action.codecClassName
                                                      method:action.codecGetterMethod
                                               argumentCount:(NSInteger)action.codecGetterArgumentCount];
        NSDictionary *setter=[resolver resolveMethodAssembly:action.codecAssembly
                                                   namespace:action.codecNamespaceName ?: @""
                                                   className:action.codecClassName
                                                      method:action.codecSetterMethod
                                               argumentCount:(NSInteger)action.codecSetterArgumentCount];
        uintptr_t getterPointer=[getter[@"methodPointer"] unsignedLongLongValue];
        uintptr_t setterPointer=[setter[@"methodPointer"] unsignedLongLongValue];
        uintptr_t getterBase=0,setterBase=0;
        NSString *getterUUID=nil,*setterUUID=nil;
        if(!ZNM69PreparedAddress(getterPointer,&getterBase,&codecGetterRVA,&getterUUID,error) ||
           !ZNM69PreparedAddress(setterPointer,&setterBase,&codecSetterRVA,&setterUUID,error))
            return nil;
        if(getterBase!=unityBase || setterBase!=unityBase ||
           ![getterUUID isEqualToString:uuid] || ![setterUUID isEqualToString:uuid]){
            if(error)*error=@"StructField codec 与目标方法不在同一 UnityFramework build";
            return nil;
        }
    }

    return @{
        @"rva":@(rva),
        @"uuid":uuid ?: @"",
        @"staticKnown":@YES,
        @"isStatic":@(isStatic),
        @"methodFlags":@(flags),
        @"codecGetterRVA":@(codecGetterRVA),
        @"codecSetterRVA":@(codecSetterRVA),
    };
}

BOOL ZNBuildPrepareNativeHookDescriptorsV1(NSString **report, NSString **error) {
    ZNNativeHookStore *store=[ZNNativeHookStore sharedStore];
    NSArray<ZNNativeHookAction *> *actions=[store actionsSnapshot];
    if(!actions.count){
        if(report)*report=@"Prepared Native Hook：无待处理 action";
        return YES;
    }

    ZNIL2CPPResolver *resolver=[ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    if(!resolver.isAvailable){
        if(error)*error=@"生成 Native Hook 二进制前 IL2CPP Runtime 必须已 Ready";
        return NO;
    }

    void *handle=NULL;
#ifdef RTLD_NOLOAD
    if(resolver.unityPath.length)
        handle=dlopen(resolver.unityPath.fileSystemRepresentation,RTLD_LAZY|RTLD_NOLOAD);
#else
    if(resolver.unityPath.length)
        handle=dlopen(resolver.unityPath.fileSystemRepresentation,RTLD_LAZY);
#endif
    ZNM69MethodGetFlagsFn methodGetFlags=(ZNM69MethodGetFlagsFn)
        (handle?dlsym(handle,"il2cpp_method_get_flags"):NULL);
    if(!methodGetFlags)
        methodGetFlags=(ZNM69MethodGetFlagsFn)dlsym(RTLD_DEFAULT,"il2cpp_method_get_flags");
    if(!methodGetFlags){
        if(handle)dlclose(handle);
        if(error)*error=@"生成 Native Hook descriptor 时无法读取 il2cpp_method_get_flags";
        return NO;
    }

    NSMutableArray<NSDictionary<NSString *,id> *> *prepared=
        [NSMutableArray arrayWithCapacity:actions.count];
    for(ZNNativeHookAction *action in actions){
        NSString *local=nil;
        NSDictionary *descriptor=ZNM69ResolvePreparedDescriptor(action,resolver,methodGetFlags,&local);
        if(!descriptor){
            if(handle)dlclose(handle);
            if(error)*error=local ?: [NSString stringWithFormat:@"%@：Prepared descriptor 失败",
                                      ZNM69Trim(action.title)];
            return NO;
        }
        [prepared addObject:descriptor];
    }
    if(handle)dlclose(handle);

    // Commit only after every action prepared successfully, so a failed build
    // cannot leave a half-updated Native Hook store.
    for(NSUInteger i=0;i<prepared.count;i++){
        NSString *local=nil;
        if(![store updatePreparedDescriptor:prepared[i] atIndex:i error:&local]){
            if(error)*error=local ?: @"Prepared Native Hook descriptor 持久化失败";
            return NO;
        }
    }

    NSUInteger structCodecCount=0;
    for(ZNNativeHookAction *action in actions)
        if(action.templateKind==ZNNativeHookTemplateStructFieldTransform ||
           action.templateKind==ZNNativeHookTemplateComplexStructTransform)structCodecCount++;
    if(report)*report=[NSString stringWithFormat:
        @"Prepared Native Hook：%lu actions · RVA/UUID/static%@",
        (unsigned long)prepared.count,
        structCodecCount ? @" + codec prepare" : @""];
    return YES;
}
