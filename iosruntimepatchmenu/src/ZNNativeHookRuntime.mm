#import "ZNNativeHookRuntime.h"

#import "ZNNativeHookAction.h"
#import "ZNNativeHookBackend.h"
#import "ZNNativeHookTemplate.h"
#import "ZNIL2CPPABIMetadata.h"
#import "ZNIL2CPPResolver.h"
#import "ZNIL2CPPRuntimeCommon.h"
#import "ZNPatchCore.h"
#import "ZNRuntimeActionFormat.h"
#import "ZNStaticPatchFormat.h"
#import "ZNGeneratedDataLayout.h"
#import "ZNIL2CPPMethodSignature.h"
#import "ZNComplexStructCodec.h"
#import "ZNComplexStructCodecResolver.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>

#import <atomic>
#import <limits.h>
#import <uuid/uuid.h>

const void * const ZNNativeHookCandidateAssociationKey = &ZNNativeHookCandidateAssociationKey;

static const uint32_t kZNNativeMethodAttributeStatic = 0x0010u;
static const NSUInteger kZNNativeMaxSlots = 16;

typedef NS_ENUM(uint32_t, ZNNativeHookSlotKind) {
    ZNNativeHookSlotKindInvalid = 0,
    ZNNativeHookSlotKindArgScale = 1,
    ZNNativeHookSlotKindManagedCallback = 2,
    ZNNativeHookSlotKindReturnBool = 3,
    ZNNativeHookSlotKindStructField = 4,
};

typedef struct {
    std::atomic<uint32_t> actionID;
    std::atomic<uint32_t> kind;
    std::atomic<uintptr_t> target;
    std::atomic<uintptr_t> original;
    std::atomic<uintptr_t> slot;
} ZNNativeHookRegistryEntry;

static const NSUInteger kZNNativeHookRegistryCapacity = 40;
static ZNNativeHookRegistryEntry gZNNativeHookRegistry[kZNNativeHookRegistryCapacity];

static ZNNativeHookRegistryEntry *ZNNativeHookRegistryFind(uint32_t actionID) {
    if(!actionID)return NULL;
    for(NSUInteger i=0;i<kZNNativeHookRegistryCapacity;i++){
        ZNNativeHookRegistryEntry *entry=&gZNNativeHookRegistry[i];
        if(entry->actionID.load(std::memory_order_acquire)==actionID &&
           entry->slot.load(std::memory_order_acquire)) return entry;
    }
    return NULL;
}

static BOOL ZNNativeHookRegistryBind(uint32_t actionID,
                                     ZNNativeHookSlotKind kind,
                                     uintptr_t target,
                                     uintptr_t original,
                                     void *slot) {
    if(!actionID||kind==ZNNativeHookSlotKindInvalid||!target||!slot)return NO;
    ZNNativeHookRegistryEntry *freeEntry=NULL;
    for(NSUInteger i=0;i<kZNNativeHookRegistryCapacity;i++){
        ZNNativeHookRegistryEntry *entry=&gZNNativeHookRegistry[i];
        uint32_t existing=entry->actionID.load(std::memory_order_acquire);
        if(existing==actionID){
            entry->kind.store((uint32_t)kind,std::memory_order_relaxed);
            entry->target.store(target,std::memory_order_relaxed);
            entry->original.store(original,std::memory_order_relaxed);
            entry->slot.store((uintptr_t)slot,std::memory_order_release);
            return YES;
        }
        if(!existing&&!freeEntry)freeEntry=entry;
    }
    if(!freeEntry)return NO;
    freeEntry->kind.store((uint32_t)kind,std::memory_order_relaxed);
    freeEntry->target.store(target,std::memory_order_relaxed);
    freeEntry->original.store(original,std::memory_order_relaxed);
    freeEntry->slot.store((uintptr_t)slot,std::memory_order_relaxed);
    freeEntry->actionID.store(actionID,std::memory_order_release);
    return YES;
}

static void ZNNativeHookRegistryUnbind(uint32_t actionID) {
    ZNNativeHookRegistryEntry *entry=ZNNativeHookRegistryFind(actionID);
    if(!entry)return;
    entry->slot.store(0,std::memory_order_release);
    entry->original.store(0,std::memory_order_relaxed);
    entry->target.store(0,std::memory_order_relaxed);
    entry->kind.store((uint32_t)ZNNativeHookSlotKindInvalid,std::memory_order_relaxed);
    entry->actionID.store(0,std::memory_order_release);
}

typedef uint32_t (*ZNNativeMethodGetFlagsFn)(const void *, uint32_t *);

typedef struct {
    std::atomic<uintptr_t> target;
    std::atomic<uintptr_t> original;
    std::atomic<int32_t> multiplier;
    std::atomic<uint32_t> enabled;
    std::atomic<uint64_t> hits;
    std::atomic<int32_t> lastBefore;
    std::atomic<int32_t> lastAfter;
    std::atomic<uint32_t> registerIndex;
    std::atomic<uint32_t> actionID;
} ZNNativeSlot;

static ZNNativeSlot gZNNativeSlots[kZNNativeMaxSlots];

static ZNNativeSlot *ZNNativeSlotForTarget(uintptr_t target) {
    if(!target)return NULL;
    for(NSUInteger i=0;i<kZNNativeMaxSlots;i++)
        if(gZNNativeSlots[i].target.load(std::memory_order_acquire)==target)return &gZNNativeSlots[i];
    return NULL;
}

static ZNNativeSlot *ZNNativeSlotForActionID(uint32_t actionID) {
    if(!actionID)return NULL;
    for(NSUInteger i=0;i<kZNNativeMaxSlots;i++)
        if(gZNNativeSlots[i].target.load(std::memory_order_acquire) &&
           gZNNativeSlots[i].actionID.load(std::memory_order_acquire)==actionID)return &gZNNativeSlots[i];
    return NULL;
}

static ZNNativeSlot *ZNNativeFreeSlot(void) {
    for(NSUInteger i=0;i<kZNNativeMaxSlots;i++)
        if(gZNNativeSlots[i].target.load(std::memory_order_acquire)==0)return &gZNNativeSlots[i];
    return NULL;
}


extern "C" {
void ZNArgScaleBridgeSlot0(void);  void ZNArgScaleBridgeSlot1(void);
void ZNArgScaleBridgeSlot2(void);  void ZNArgScaleBridgeSlot3(void);
void ZNArgScaleBridgeSlot4(void);  void ZNArgScaleBridgeSlot5(void);
void ZNArgScaleBridgeSlot6(void);  void ZNArgScaleBridgeSlot7(void);
void ZNArgScaleBridgeSlot8(void);  void ZNArgScaleBridgeSlot9(void);
void ZNArgScaleBridgeSlot10(void); void ZNArgScaleBridgeSlot11(void);
void ZNArgScaleBridgeSlot12(void); void ZNArgScaleBridgeSlot13(void);
void ZNArgScaleBridgeSlot14(void); void ZNArgScaleBridgeSlot15(void);
}

static void * const gZNArgScaleBridgeReplacements[kZNNativeMaxSlots]={
    (void *)&ZNArgScaleBridgeSlot0,(void *)&ZNArgScaleBridgeSlot1,
    (void *)&ZNArgScaleBridgeSlot2,(void *)&ZNArgScaleBridgeSlot3,
    (void *)&ZNArgScaleBridgeSlot4,(void *)&ZNArgScaleBridgeSlot5,
    (void *)&ZNArgScaleBridgeSlot6,(void *)&ZNArgScaleBridgeSlot7,
    (void *)&ZNArgScaleBridgeSlot8,(void *)&ZNArgScaleBridgeSlot9,
    (void *)&ZNArgScaleBridgeSlot10,(void *)&ZNArgScaleBridgeSlot11,
    (void *)&ZNArgScaleBridgeSlot12,(void *)&ZNArgScaleBridgeSlot13,
    (void *)&ZNArgScaleBridgeSlot14,(void *)&ZNArgScaleBridgeSlot15
};

extern "C" __attribute__((visibility("hidden")))
void ZNArgScaleBridgeMutate(uint32_t index, uint64_t *savedGPRs) {
    if(!savedGPRs||index>=kZNNativeMaxSlots)return;
    ZNNativeSlot *slot=&gZNNativeSlots[index];
    if(!slot->target.load(std::memory_order_acquire))return;
    if(!slot->enabled.load(std::memory_order_relaxed))return;
    uint32_t reg=slot->registerIndex.load(std::memory_order_relaxed);
    if(reg>8)return;
    uint64_t raw=savedGPRs[reg];
    int32_t before=(int32_t)(uint32_t)raw;
    int32_t multiplier=slot->multiplier.load(std::memory_order_relaxed);
    int32_t after=ZNNativeHookScaleInt32(before,multiplier);
    savedGPRs[reg]=(uint64_t)(uint32_t)after;
    slot->lastBefore.store(before,std::memory_order_relaxed);
    slot->lastAfter.store(after,std::memory_order_relaxed);
    slot->hits.fetch_add(1,std::memory_order_relaxed);
}

extern "C" __attribute__((visibility("hidden")))
uintptr_t ZNArgScaleBridgeOriginal(uint32_t index) {
    if(index>=kZNNativeMaxSlots)return 0;
    return gZNNativeSlots[index].original.load(std::memory_order_acquire);
}


static const NSUInteger kZNStructFieldMaxSlots = 8;
typedef int64_t (*ZNSecureLongGetterFn)(uintptr_t);
typedef void (*ZNSecureLongSetterFn)(uintptr_t,int64_t);

typedef struct {
    std::atomic<uintptr_t> target;
    std::atomic<uintptr_t> original;
    std::atomic<uintptr_t> getter;
    std::atomic<uintptr_t> setter;
    std::atomic<uintptr_t> function2;
    std::atomic<uintptr_t> function3;
    std::atomic<uintptr_t> methodInfo0;
    std::atomic<uintptr_t> methodInfo1;
    std::atomic<uintptr_t> methodInfo2;
    std::atomic<uintptr_t> methodInfo3;
    std::atomic<uint32_t> codecVariant;
    std::atomic<int32_t> multiplier;
    std::atomic<uint32_t> enabled;
    std::atomic<uint64_t> hits;
    std::atomic<uint64_t> failures;
    std::atomic<int64_t> lastBefore;
    std::atomic<int64_t> lastAfter;
    std::atomic<uintptr_t> lastBase;
    std::atomic<uintptr_t> lastField;
    std::atomic<uint32_t> argumentRegister;
    std::atomic<uint64_t> fieldOffset;
    std::atomic<uintptr_t> codecTransform;
    std::atomic<uint32_t> actionID;
} ZNStructFieldSlot;

static ZNStructFieldSlot gZNStructFieldSlots[kZNStructFieldMaxSlots];

static ZNStructFieldSlot *ZNStructFieldSlotForTarget(uintptr_t target) {
    if(!target)return NULL;
    for(NSUInteger i=0;i<kZNStructFieldMaxSlots;i++)
        if(gZNStructFieldSlots[i].target.load(std::memory_order_acquire)==target)return &gZNStructFieldSlots[i];
    return NULL;
}

static ZNStructFieldSlot *ZNStructFieldSlotForActionID(uint32_t actionID) {
    if(!actionID)return NULL;
    for(NSUInteger i=0;i<kZNStructFieldMaxSlots;i++)
        if(gZNStructFieldSlots[i].target.load(std::memory_order_acquire) &&
           gZNStructFieldSlots[i].actionID.load(std::memory_order_acquire)==actionID)return &gZNStructFieldSlots[i];
    return NULL;
}

static ZNStructFieldSlot *ZNStructFieldFreeSlot(void) {
    for(NSUInteger i=0;i<kZNStructFieldMaxSlots;i++)
        if(gZNStructFieldSlots[i].target.load(std::memory_order_acquire)==0)return &gZNStructFieldSlots[i];
    return NULL;
}

extern "C" {
void ZNStructFieldBridgeSlot0(void); void ZNStructFieldBridgeSlot1(void);
void ZNStructFieldBridgeSlot2(void); void ZNStructFieldBridgeSlot3(void);
void ZNStructFieldBridgeSlot4(void); void ZNStructFieldBridgeSlot5(void);
void ZNStructFieldBridgeSlot6(void); void ZNStructFieldBridgeSlot7(void);
}

static void * const gZNStructFieldBridgeReplacements[kZNStructFieldMaxSlots]={
    (void *)&ZNStructFieldBridgeSlot0,(void *)&ZNStructFieldBridgeSlot1,
    (void *)&ZNStructFieldBridgeSlot2,(void *)&ZNStructFieldBridgeSlot3,
    (void *)&ZNStructFieldBridgeSlot4,(void *)&ZNStructFieldBridgeSlot5,
    (void *)&ZNStructFieldBridgeSlot6,(void *)&ZNStructFieldBridgeSlot7
};

extern "C" __attribute__((visibility("hidden")))
void ZNStructFieldBridgeMutate(uint32_t index, uint64_t *savedGPRs) {
    if(!savedGPRs||index>=kZNStructFieldMaxSlots)return;
    ZNStructFieldSlot *slot=&gZNStructFieldSlots[index];
    if(!slot->target.load(std::memory_order_acquire))return;
    if(!slot->enabled.load(std::memory_order_relaxed))return;
    uint32_t reg=slot->argumentRegister.load(std::memory_order_relaxed);
    if(reg>=8){slot->failures.fetch_add(1,std::memory_order_relaxed);return;}
    uintptr_t base=(uintptr_t)savedGPRs[reg];
    uint64_t offset=slot->fieldOffset.load(std::memory_order_relaxed);
    uintptr_t getterAddr=slot->getter.load(std::memory_order_acquire);
    uintptr_t setterAddr=slot->setter.load(std::memory_order_acquire);
    if(base<0x1000||offset>0x100000ULL||!getterAddr||!setterAddr){
        slot->failures.fetch_add(1,std::memory_order_relaxed);
        return;
    }
    int32_t multiplier=slot->multiplier.load(std::memory_order_relaxed);
    uintptr_t transformAddr=slot->codecTransform.load(std::memory_order_acquire);
    int64_t before=0,after=0;
    uintptr_t field=base;
    if(transformAddr){
        ZNComplexStructResolvedFunctions functions={
            getterAddr,
            slot->methodInfo0.load(std::memory_order_acquire),
            setterAddr,
            slot->methodInfo1.load(std::memory_order_acquire),
            slot->function2.load(std::memory_order_acquire),
            slot->methodInfo2.load(std::memory_order_acquire),
            slot->function3.load(std::memory_order_acquire),
            slot->methodInfo3.load(std::memory_order_acquire),
            slot->codecVariant.load(std::memory_order_relaxed)
        };
        ZNComplexStructTransformFn transform=(ZNComplexStructTransformFn)transformAddr;
        if(!transform(base,&functions,multiplier,&before,&after)){
            slot->failures.fetch_add(1,std::memory_order_relaxed);
            return;
        }
    }else{
        field=base+(uintptr_t)offset;
        if(field<base){
            slot->failures.fetch_add(1,std::memory_order_relaxed);
            return;
        }
        ZNSecureLongGetterFn getter=(ZNSecureLongGetterFn)getterAddr;
        ZNSecureLongSetterFn setter=(ZNSecureLongSetterFn)setterAddr;
        before=getter(field);
        after=ZNNativeHookScaleInt64(before,multiplier);
        setter(field,after);
    }
    slot->lastBase.store(base,std::memory_order_relaxed);
    slot->lastField.store(field,std::memory_order_relaxed);
    slot->lastBefore.store(before,std::memory_order_relaxed);
    slot->lastAfter.store(after,std::memory_order_relaxed);
    slot->hits.fetch_add(1,std::memory_order_relaxed);
}

extern "C" __attribute__((visibility("hidden")))
uintptr_t ZNStructFieldBridgeOriginal(uint32_t index) {
    if(index>=kZNStructFieldMaxSlots)return 0;
    return gZNStructFieldSlots[index].original.load(std::memory_order_acquire);
}

static NSDictionary *ZNNativeResolveSecureLongCodec(NSString *assembly,
                                                        NSString *namespaceName,
                                                        NSString *className,
                                                        NSString *getterMethod,
                                                        NSString *setterMethod,
                                                        NSString **error) {
    if(![getterMethod length]||![setterMethod length]||![className length]){
        if(error)*error=@"SecureLong codec 描述不完整";
        return nil;
    }
    ZNIL2CPPResolver *resolver=[ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    if(!resolver.isAvailable){if(error)*error=@"IL2CPP Resolver 不可用";return nil;}
    NSDictionary *getter=[resolver resolveMethodAssembly:assembly namespace:namespaceName?:@"" className:className method:getterMethod argumentCount:0];
    NSDictionary *setter=[resolver resolveMethodAssembly:assembly namespace:namespaceName?:@"" className:className method:setterMethod argumentCount:1];
    uintptr_t gp=[getter[@"methodPointer"] unsignedLongLongValue];
    uintptr_t sp=[setter[@"methodPointer"] unsignedLongLongValue];
    if(!gp||!sp){
        if(error)*error=[NSString stringWithFormat:@"SecureLong codec resolve 失败：%@.%@::%@/0 + %@/1",
                         namespaceName?:@"",className?:@"",getterMethod?:@"",setterMethod?:@""];
        return nil;
    }
    return @{@"getter":@(gp),@"setter":@(sp)};
}

static const NSUInteger kZNReturnBoolMaxSlots = 8;
typedef struct {
    std::atomic<uintptr_t> target;
    std::atomic<uintptr_t> original;
    std::atomic<uint32_t> forcedValue;
    std::atomic<uint32_t> enabled;
    std::atomic<uint64_t> hits;
    std::atomic<uint32_t> lastOriginal;
    std::atomic<uint32_t> lastOverride;
    std::atomic<uint32_t> actionID;
} ZNReturnBoolSlot;

static ZNReturnBoolSlot gZNReturnBoolSlots[kZNReturnBoolMaxSlots];

static ZNReturnBoolSlot *ZNReturnBoolSlotForTarget(uintptr_t target) {
    if(!target)return NULL;
    for(NSUInteger i=0;i<kZNReturnBoolMaxSlots;i++)
        if(gZNReturnBoolSlots[i].target.load(std::memory_order_acquire)==target)return &gZNReturnBoolSlots[i];
    return NULL;
}

static ZNReturnBoolSlot *ZNReturnBoolSlotForActionID(uint32_t actionID) {
    if(!actionID)return NULL;
    for(NSUInteger i=0;i<kZNReturnBoolMaxSlots;i++)
        if(gZNReturnBoolSlots[i].target.load(std::memory_order_acquire) &&
           gZNReturnBoolSlots[i].actionID.load(std::memory_order_acquire)==actionID)return &gZNReturnBoolSlots[i];
    return NULL;
}

static ZNReturnBoolSlot *ZNReturnBoolFreeSlot(void) {
    for(NSUInteger i=0;i<kZNReturnBoolMaxSlots;i++)
        if(gZNReturnBoolSlots[i].target.load(std::memory_order_acquire)==0)return &gZNReturnBoolSlots[i];
    return NULL;
}

typedef uint8_t (*ZNReturnBoolOriginalFn)(uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t);

static uint8_t ZNReturnBoolHandle(NSUInteger index,
                                  uintptr_t x0,uintptr_t x1,uintptr_t x2,uintptr_t x3,
                                  uintptr_t x4,uintptr_t x5,uintptr_t x6,uintptr_t x7) {
    if(index>=kZNReturnBoolMaxSlots)return 0;
    ZNReturnBoolSlot *slot=&gZNReturnBoolSlots[index];
    if(!slot->target.load(std::memory_order_acquire))return 0;
    slot->hits.fetch_add(1,std::memory_order_relaxed);
    if(!slot->enabled.load(std::memory_order_relaxed)){
        uintptr_t original=slot->original.load(std::memory_order_acquire);
        if(!original)return 0;
        uint8_t value=((ZNReturnBoolOriginalFn)original)(x0,x1,x2,x3,x4,x5,x6,x7);
        slot->lastOriginal.store(value?1u:0u,std::memory_order_relaxed);
        return value;
    }
    uint8_t overrideValue=slot->forcedValue.load(std::memory_order_relaxed)?1:0;
    slot->lastOriginal.store(UINT32_MAX,std::memory_order_relaxed);
    slot->lastOverride.store(overrideValue,std::memory_order_relaxed);
    return overrideValue;
}

#define ZN_RETURN_BOOL_REPLACEMENT(N) \
    static uint8_t ZNReturnBoolReplacement##N(uintptr_t x0,uintptr_t x1,uintptr_t x2,uintptr_t x3, \
                                              uintptr_t x4,uintptr_t x5,uintptr_t x6,uintptr_t x7) { \
        return ZNReturnBoolHandle((N),x0,x1,x2,x3,x4,x5,x6,x7); \
    }

ZN_RETURN_BOOL_REPLACEMENT(0)
ZN_RETURN_BOOL_REPLACEMENT(1)
ZN_RETURN_BOOL_REPLACEMENT(2)
ZN_RETURN_BOOL_REPLACEMENT(3)
ZN_RETURN_BOOL_REPLACEMENT(4)
ZN_RETURN_BOOL_REPLACEMENT(5)
ZN_RETURN_BOOL_REPLACEMENT(6)
ZN_RETURN_BOOL_REPLACEMENT(7)

static void * const gZNReturnBoolReplacements[kZNReturnBoolMaxSlots]={
    (void *)&ZNReturnBoolReplacement0,(void *)&ZNReturnBoolReplacement1,
    (void *)&ZNReturnBoolReplacement2,(void *)&ZNReturnBoolReplacement3,
    (void *)&ZNReturnBoolReplacement4,(void *)&ZNReturnBoolReplacement5,
    (void *)&ZNReturnBoolReplacement6,(void *)&ZNReturnBoolReplacement7
};

static const NSUInteger kZNManagedCallbackMaxSlots = 8;

typedef void *(*ZNManagedObjectGetClassFn)(void *);
typedef const void *(*ZNManagedClassGetMethodFromNameFn)(void *, const char *, int);
typedef void *(*ZNManagedRuntimeInvokeFn)(const void *, void *, void **, void **);

static std::atomic<uintptr_t> gZNManagedObjectGetClass;
static std::atomic<uintptr_t> gZNManagedClassGetMethodFromName;
static std::atomic<uintptr_t> gZNManagedRuntimeInvoke;

static NSString *ZNNativeLoadedUnityFrameworkPath(void) {
    uint32_t count=_dyld_image_count();
    for(uint32_t i=0;i<count;i++){
        const char *cpath=_dyld_get_image_name(i);
        if(!cpath)continue;
        NSString *path=[NSString stringWithUTF8String:cpath]?:@"";
        if([path.lastPathComponent isEqualToString:@"UnityFramework"]||
           [path rangeOfString:@"UnityFramework.framework/UnityFramework"
                       options:NSCaseInsensitiveSearch].location!=NSNotFound)
            return path;
    }
    return @"";
}

static BOOL ZNManagedPrepareInvokeBridge(NSString **error) {
    if(gZNManagedObjectGetClass.load(std::memory_order_acquire) &&
       gZNManagedClassGetMethodFromName.load(std::memory_order_acquire) &&
       gZNManagedRuntimeInvoke.load(std::memory_order_acquire)) return YES;

    NSString *path=ZNNativeLoadedUnityFrameworkPath();
    if(!path.length){
        if(error)*error=@"Managed Callback prepare：UnityFramework 尚未加载";
        return NO;
    }
    void *handle=NULL;
#ifdef RTLD_NOLOAD
    handle=dlopen(path.fileSystemRepresentation,RTLD_LAZY|RTLD_NOLOAD);
#else
    handle=dlopen(path.fileSystemRepresentation,RTLD_LAZY);
#endif
    uintptr_t objectGetClass=(uintptr_t)(handle?dlsym(handle,"il2cpp_object_get_class"):NULL);
    uintptr_t classGetMethod=(uintptr_t)(handle?dlsym(handle,"il2cpp_class_get_method_from_name"):NULL);
    uintptr_t runtimeInvoke=(uintptr_t)(handle?dlsym(handle,"il2cpp_runtime_invoke"):NULL);
    if(!objectGetClass)objectGetClass=(uintptr_t)dlsym(RTLD_DEFAULT,"il2cpp_object_get_class");
    if(!classGetMethod)classGetMethod=(uintptr_t)dlsym(RTLD_DEFAULT,"il2cpp_class_get_method_from_name");
    if(!runtimeInvoke)runtimeInvoke=(uintptr_t)dlsym(RTLD_DEFAULT,"il2cpp_runtime_invoke");
    if(handle)dlclose(handle);
    if(!objectGetClass||!classGetMethod||!runtimeInvoke){
        if(error)*error=@"Managed Callback prepare：IL2CPP invoke API 不完整";
        return NO;
    }
    gZNManagedObjectGetClass.store(objectGetClass,std::memory_order_release);
    gZNManagedClassGetMethodFromName.store(classGetMethod,std::memory_order_release);
    gZNManagedRuntimeInvoke.store(runtimeInvoke,std::memory_order_release);
    return YES;
}

typedef struct {
    std::atomic<uintptr_t> target;
    std::atomic<uintptr_t> original;
    std::atomic<uint32_t> callbackRegister;
    std::atomic<uint32_t> callbackValue;
    std::atomic<uint32_t> enabled;
    std::atomic<uint64_t> hits;
    std::atomic<uint64_t> callbackSuccess;
    std::atomic<uint64_t> callbackFailure;
    std::atomic<uintptr_t> lastReceiver;
    std::atomic<uintptr_t> lastCallback;
    std::atomic<uint32_t> isStatic;
    std::atomic<uint32_t> actionID;
} ZNManagedCallbackSlot;

static ZNManagedCallbackSlot gZNManagedCallbackSlots[kZNManagedCallbackMaxSlots];

static ZNManagedCallbackSlot *ZNManagedCallbackSlotForTarget(uintptr_t target) {
    if(!target)return NULL;
    for(NSUInteger i=0;i<kZNManagedCallbackMaxSlots;i++)
        if(gZNManagedCallbackSlots[i].target.load(std::memory_order_acquire)==target)return &gZNManagedCallbackSlots[i];
    return NULL;
}

static ZNManagedCallbackSlot *ZNManagedCallbackSlotForActionID(uint32_t actionID) {
    if(!actionID)return NULL;
    for(NSUInteger i=0;i<kZNManagedCallbackMaxSlots;i++)
        if(gZNManagedCallbackSlots[i].target.load(std::memory_order_acquire) &&
           gZNManagedCallbackSlots[i].actionID.load(std::memory_order_acquire)==actionID)return &gZNManagedCallbackSlots[i];
    return NULL;
}

static ZNManagedCallbackSlot *ZNManagedCallbackFreeSlot(void) {
    for(NSUInteger i=0;i<kZNManagedCallbackMaxSlots;i++)
        if(gZNManagedCallbackSlots[i].target.load(std::memory_order_acquire)==0)return &gZNManagedCallbackSlots[i];
    return NULL;
}

static BOOL ZNManagedInvokeBoolCallback(uintptr_t callbackObject, BOOL value) {
    if(!callbackObject)return NO;
    ZNManagedObjectGetClassFn objectGetClass=(ZNManagedObjectGetClassFn)gZNManagedObjectGetClass.load(std::memory_order_acquire);
    ZNManagedClassGetMethodFromNameFn classGetMethod=(ZNManagedClassGetMethodFromNameFn)gZNManagedClassGetMethodFromName.load(std::memory_order_acquire);
    ZNManagedRuntimeInvokeFn runtimeInvoke=(ZNManagedRuntimeInvokeFn)gZNManagedRuntimeInvoke.load(std::memory_order_acquire);
    if(!objectGetClass||!classGetMethod||!runtimeInvoke)return NO;
    void *klass=objectGetClass((void *)callbackObject);
    if(!klass)return NO;
    const void *invoke=classGetMethod(klass,"Invoke",1);
    if(!invoke)return NO;
    uint8_t boolValue=value?1:0;
    void *params[1]={&boolValue};
    void *exception=NULL;
    (void)runtimeInvoke(invoke,(void *)callbackObject,params,&exception);
    return exception==NULL;
}

typedef uintptr_t (*ZNManagedCallbackOriginalFn)(uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t);

static uintptr_t ZNManagedCallbackHandle(NSUInteger index,
                                         uintptr_t x0,uintptr_t x1,uintptr_t x2,uintptr_t x3,
                                         uintptr_t x4,uintptr_t x5,uintptr_t x6,uintptr_t x7) {
    if(index>=kZNManagedCallbackMaxSlots)return 0;
    ZNManagedCallbackSlot *slot=&gZNManagedCallbackSlots[index];
    if(!slot->target.load(std::memory_order_acquire))return 0;
    slot->hits.fetch_add(1,std::memory_order_relaxed);
    if(!slot->enabled.load(std::memory_order_relaxed)){
        uintptr_t original=slot->original.load(std::memory_order_acquire);
        if(!original)return 0;
        return ((ZNManagedCallbackOriginalFn)original)(x0,x1,x2,x3,x4,x5,x6,x7);
    }
    uintptr_t regs[8]={x0,x1,x2,x3,x4,x5,x6,x7};
    uint32_t reg=slot->callbackRegister.load(std::memory_order_relaxed);
    slot->lastReceiver.store(slot->isStatic.load(std::memory_order_relaxed)?0:x0,std::memory_order_relaxed);
    slot->lastCallback.store(reg<8?regs[reg]:0,std::memory_order_relaxed);
    if(reg>=8||!regs[reg]){
        slot->callbackFailure.fetch_add(1,std::memory_order_relaxed);
        return 0;
    }
    BOOL ok=ZNManagedInvokeBoolCallback(regs[reg],slot->callbackValue.load(std::memory_order_relaxed)!=0);
    if(ok)slot->callbackSuccess.fetch_add(1,std::memory_order_relaxed);
    else slot->callbackFailure.fetch_add(1,std::memory_order_relaxed);
    return 0;
}

#define ZN_MANAGED_CALLBACK_REPLACEMENT(N) \
    static uintptr_t ZNManagedCallbackReplacement##N(uintptr_t x0,uintptr_t x1,uintptr_t x2,uintptr_t x3, \
                                                     uintptr_t x4,uintptr_t x5,uintptr_t x6,uintptr_t x7) { \
        return ZNManagedCallbackHandle((N),x0,x1,x2,x3,x4,x5,x6,x7); \
    }

ZN_MANAGED_CALLBACK_REPLACEMENT(0)
ZN_MANAGED_CALLBACK_REPLACEMENT(1)
ZN_MANAGED_CALLBACK_REPLACEMENT(2)
ZN_MANAGED_CALLBACK_REPLACEMENT(3)
ZN_MANAGED_CALLBACK_REPLACEMENT(4)
ZN_MANAGED_CALLBACK_REPLACEMENT(5)
ZN_MANAGED_CALLBACK_REPLACEMENT(6)
ZN_MANAGED_CALLBACK_REPLACEMENT(7)

static void * const gZNManagedCallbackReplacements[kZNManagedCallbackMaxSlots]={
    (void *)&ZNManagedCallbackReplacement0,(void *)&ZNManagedCallbackReplacement1,
    (void *)&ZNManagedCallbackReplacement2,(void *)&ZNManagedCallbackReplacement3,
    (void *)&ZNManagedCallbackReplacement4,(void *)&ZNManagedCallbackReplacement5,
    (void *)&ZNManagedCallbackReplacement6,(void *)&ZNManagedCallbackReplacement7
};

static NSString *ZNNativeString(id value) {
    return [value isKindOfClass:NSString.class]?value:@"";
}

static NSDictionary *ZNNativeResolveDescriptor(NSString *assembly,
                                                NSString *namespaceName,
                                                NSString *className,
                                                NSString *methodName,
                                                NSUInteger argumentCount,
                                                NSDictionary *candidate,
                                                NSString **error) {
    uintptr_t candidateMethodInfo=[candidate[@"methodInfo"] unsignedLongLongValue];
    uintptr_t candidatePointer=[candidate[@"methodPointer"] unsignedLongLongValue];
    uintptr_t methodInfo=candidateMethodInfo;
    uintptr_t pointer=candidatePointer;
    NSString *pointerSource=@"candidate";

    ZNIL2CPPResolver *resolver=[ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    if(resolver.isAvailable){
        NSDictionary *resolved=[resolver resolveMethodAssembly:assembly
                                                     namespace:namespaceName?:@""
                                                     className:className
                                                        method:methodName
                                                 argumentCount:(NSInteger)argumentCount];
        uintptr_t freshMethodInfo=[resolved[@"methodInfo"] unsignedLongLongValue];
        uintptr_t freshPointer=[resolved[@"methodPointer"] unsignedLongLongValue];
        if(freshMethodInfo)methodInfo=freshMethodInfo;
        if(freshPointer){
            pointer=freshPointer;
            pointerSource=[resolved[@"pointerSource"] isKindOfClass:NSString.class]?resolved[@"pointerSource"]:@"resolver";
        }
        if(candidatePointer&&freshPointer&&candidatePointer!=freshPointer){
            [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[native-hook-resolve] candidate pointer mismatch candidate=0x%llX resolver=0x%llX %@.%@::%@/%lu",
                                               (unsigned long long)candidatePointer,
                                               (unsigned long long)freshPointer,
                                               namespaceName?:@"",className?:@"",methodName?:@"",
                                               (unsigned long)argumentCount]];
        }
    }
    if(!methodInfo||!pointer){
        if(error)*error=[NSString stringWithFormat:@"Native Hook resolve 失败：%@.%@::%@/%lu",
                         namespaceName?:@"",className?:@"",methodName?:@"",(unsigned long)argumentCount];
        return nil;
    }

    ZNNativeMethodGetFlagsFn getFlags=(ZNNativeMethodGetFlagsFn)ZNIL2CPPResolveSymbol(resolver.unityPath,"il2cpp_method_get_flags");
    if(!getFlags){
        if(error)*error=@"Native Hook 无法读取 il2cpp_method_get_flags";
        return nil;
    }
    uint32_t implFlags=0;
    uint32_t flags=getFlags((const void *)methodInfo,&implFlags);
    BOOL isStatic=(flags&kZNNativeMethodAttributeStatic)!=0;
    return @{@"methodInfo":@(methodInfo),@"methodPointer":@(pointer),@"static":@(isStatic),@"methodFlags":@(flags),
             @"pointerSource":pointerSource?:@"unknown",@"candidateMethodPointer":@(candidatePointer)};
}

static NSString *ZNNativePreparedUUIDForHeader(const struct mach_header_64 *mh) {
    if(!mh||mh->magic!=MH_MAGIC_64)return @"";
    const uint8_t *cursor=(const uint8_t *)(mh+1),*limit=cursor+mh->sizeofcmds;
    if(mh->ncmds>4096||mh->sizeofcmds>16*1024*1024)return @"";
    for(uint32_t i=0;i<mh->ncmds;i++){
        if(cursor+sizeof(struct load_command)>limit)return @"";
        const struct load_command *lc=(const struct load_command *)cursor;
        if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit)return @"";
        if(lc->cmd==LC_UUID&&lc->cmdsize>=sizeof(struct uuid_command)){
            const struct uuid_command *uc=(const struct uuid_command *)cursor;
            uuid_t bytes={0};memcpy(bytes,uc->uuid,sizeof(bytes));
            NSUUID *uuid=[[NSUUID alloc]initWithUUIDBytes:bytes];
            return uuid.UUIDString.uppercaseString?:@"";
        }
        cursor+=lc->cmdsize;
    }
    return @"";
}

static BOOL ZNNativePreparedTargetForAction(ZNNativeHookAction *action,
                                             uintptr_t *outBase,
                                             uintptr_t *outTarget,
                                             NSString **error) {
    if(!action.preparedDescriptor||!action.preparedRVA||!action.preparedUUID.length||
       !action.preparedStaticKnown){
        if(error)*error=@"Native Hook 缺少 M6.9 Prepared Descriptor；请重新生成二进制";
        return NO;
    }

    uint32_t count=_dyld_image_count();
    for(uint32_t i=0;i<count;i++){
        const char *cpath=_dyld_get_image_name(i);
        const struct mach_header *raw=_dyld_get_image_header(i);
        if(!cpath||!raw||raw->magic!=MH_MAGIC_64)continue;
        NSString *path=[NSString stringWithUTF8String:cpath]?:@"";
        BOOL unity=[path.lastPathComponent isEqualToString:@"UnityFramework"]||
                   [path rangeOfString:@"UnityFramework.framework/UnityFramework"
                               options:NSCaseInsensitiveSearch].location!=NSNotFound;
        if(!unity)continue;

        const struct mach_header_64 *mh=(const struct mach_header_64 *)raw;
        NSString *uuid=ZNNativePreparedUUIDForHeader(mh);
        if(!uuid.length||[uuid caseInsensitiveCompare:action.preparedUUID]!=NSOrderedSame){
            if(error)*error=[NSString stringWithFormat:
                @"Native Hook UnityFramework UUID 不匹配：prepared=%@ runtime=%@",
                action.preparedUUID?:@"",uuid?:@""];
            return NO;
        }

        uintptr_t base=(uintptr_t)raw;
        if(action.preparedRVA>UINTPTR_MAX-base){
            if(error)*error=@"Native Hook Prepared RVA 地址溢出";
            return NO;
        }
        uintptr_t target=base+(uintptr_t)action.preparedRVA;

        const uint8_t *cursor=(const uint8_t *)(mh+1),*limit=cursor+mh->sizeofcmds;
        uint64_t textVM=UINT64_MAX;
        for(uint32_t j=0;j<mh->ncmds;j++){
            if(cursor+sizeof(struct load_command)>limit)break;
            const struct load_command *lc=(const struct load_command *)cursor;
            if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit)break;
            if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(struct segment_command_64)){
                const struct segment_command_64 *seg=(const struct segment_command_64 *)cursor;
                if(strncmp(seg->segname,SEG_TEXT,16)==0){textVM=seg->vmaddr;break;}
            }
            cursor+=lc->cmdsize;
        }
        if(textVM==UINT64_MAX){
            if(error)*error=@"Native Hook 无法读取 UnityFramework __TEXT";
            return NO;
        }

        BOOL executable=NO;
        cursor=(const uint8_t *)(mh+1);
        for(uint32_t j=0;j<mh->ncmds;j++){
            if(cursor+sizeof(struct load_command)>limit)break;
            const struct load_command *lc=(const struct load_command *)cursor;
            if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit)break;
            if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(struct segment_command_64)){
                const struct segment_command_64 *seg=(const struct segment_command_64 *)cursor;
                if((seg->initprot&VM_PROT_EXECUTE)&&seg->vmaddr>=textVM){
                    uintptr_t start=base+(uintptr_t)(seg->vmaddr-textVM);
                    uintptr_t finish=start+(uintptr_t)seg->vmsize;
                    if(target>=start&&target<finish){executable=YES;break;}
                }
            }
            cursor+=lc->cmdsize;
        }
        if(!executable){
            if(error)*error=[NSString stringWithFormat:
                @"Native Hook Prepared RVA 0x%llX 不在 executable segment",
                (unsigned long long)action.preparedRVA];
            return NO;
        }
        if(outBase)*outBase=base;
        if(outTarget)*outTarget=target;
        return YES;
    }

    if(error)*error=@"Native Hook 等待 UnityFramework image";
    return NO;
}

static BOOL ZNNativeRuntimeAddressHasProtection(uintptr_t imageBase,
                                                  uintptr_t address,
                                                  vm_prot_t required) {
    if(!imageBase||!address)return NO;
    const struct mach_header_64 *mh=(const struct mach_header_64 *)imageBase;
    if(mh->magic!=MH_MAGIC_64)return NO;
    const uint8_t *cursor=(const uint8_t *)(mh+1),*limit=cursor+mh->sizeofcmds;
    uint64_t textVM=UINT64_MAX;
    for(uint32_t i=0;i<mh->ncmds;i++){
        if(cursor+sizeof(struct load_command)>limit)return NO;
        const struct load_command *lc=(const struct load_command *)cursor;
        if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit)return NO;
        if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(struct segment_command_64)){
            const struct segment_command_64 *seg=(const struct segment_command_64 *)cursor;
            if(strncmp(seg->segname,SEG_TEXT,16)==0){textVM=seg->vmaddr;break;}
        }
        cursor+=lc->cmdsize;
    }
    if(textVM==UINT64_MAX)return NO;

    cursor=(const uint8_t *)(mh+1);
    for(uint32_t i=0;i<mh->ncmds;i++){
        const struct load_command *lc=(const struct load_command *)cursor;
        if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(struct segment_command_64)){
            const struct segment_command_64 *seg=(const struct segment_command_64 *)cursor;
            if(seg->vmaddr>=textVM){
                uintptr_t start=imageBase+(uintptr_t)(seg->vmaddr-textVM);
                uintptr_t finish=start+(uintptr_t)seg->vmsize;
                if(address>=start&&address<finish)
                    return (seg->initprot&required)==required;
            }
        }
        cursor+=lc->cmdsize;
    }
    return NO;
}

static BOOL ZNNativeStaticPrepatchBind(ZNNativeHookAction *action,
                                       uintptr_t target,
                                       void *replacement,
                                       uintptr_t *outOriginal,
                                       NSString **error) {
    if(!action.staticPrepatch||!action.staticHookSlotRVA||
       !action.staticTrampolineRVA||!action.staticCodeCaveRVA){
        if(error)*error=@"Native Hook 缺少 M6.10 Static Prepared Descriptor";
        return NO;
    }
    if(!target||!replacement||!action.preparedRVA||target<action.preparedRVA){
        if(error)*error=@"Static Prepared Native Hook target/replacement 无效";
        return NO;
    }
    uintptr_t imageBase=target-(uintptr_t)action.preparedRVA;
    if(action.staticHookSlotRVA>UINTPTR_MAX-imageBase||
       action.staticTrampolineRVA>UINTPTR_MAX-imageBase||
       action.staticCodeCaveRVA>UINTPTR_MAX-imageBase){
        if(error)*error=@"Static Prepared Native Hook RVA 地址溢出";
        return NO;
    }
    uintptr_t slot=imageBase+(uintptr_t)action.staticHookSlotRVA;
    uintptr_t trampoline=imageBase+(uintptr_t)action.staticTrampolineRVA;
    uintptr_t cave=imageBase+(uintptr_t)action.staticCodeCaveRVA;
    if(!ZNNativeRuntimeAddressHasProtection(imageBase,slot,VM_PROT_WRITE)){
        if(error)*error=@"Static Prepared hook slot 不是 writable memory";
        return NO;
    }
    if(!ZNNativeRuntimeAddressHasProtection(imageBase,trampoline,VM_PROT_EXECUTE)||
       !ZNNativeRuntimeAddressHasProtection(imageBase,cave,VM_PROT_EXECUTE)){
        if(error)*error=@"Static Prepared cave/trampoline 不是 executable memory";
        return NO;
    }

    // Verify that the signed UnityFramework still contains the build-time
    // instrumentation before activating the writable slot.
    uint32_t targetInsn=0,trampolineInsn=0;
    memcpy(&targetInsn,(const void *)target,sizeof(targetInsn));
    memcpy(&trampolineInsn,(const void *)trampoline,sizeof(trampolineInsn));
    if((targetInsn&UINT32_C(0xFC000000))!=UINT32_C(0x14000000)){
        if(error)*error=@"Static Prepared target 未检测到预埋 B 指令";
        return NO;
    }
    int32_t imm26=(int32_t)(targetInsn&UINT32_C(0x03FFFFFF));
    if(imm26&INT32_C(0x02000000))imm26|=(int32_t)UINT32_C(0xFC000000);
    uintptr_t decoded=(uintptr_t)((int64_t)target+((int64_t)imm26<<2));
    if(decoded!=cave){
        if(error)*error=@"Static Prepared target branch 与 descriptor 不一致";
        return NO;
    }
    if(trampolineInsn!=action.staticDisplacedInstruction){
        if(error)*error=@"Static Prepared trampoline 原指令校验失败";
        return NO;
    }

    __atomic_store_n((uintptr_t *)slot,(uintptr_t)replacement,__ATOMIC_RELEASE);
    if(outOriginal)*outOriginal=trampoline;
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:
        @"[static-prepatch-hook] bind action=%u target=0x%llX slot=0x%llX replacement=0x%llX trampoline=0x%llX",
        action.actionID,(unsigned long long)target,(unsigned long long)slot,
        (unsigned long long)(uintptr_t)replacement,(unsigned long long)trampoline]];
    return YES;
}

static BOOL ZNNativeStaticPrepatchClear(ZNNativeHookAction *action,
                                        uintptr_t target,
                                        NSString **error) {
    if(!action.staticPrepatch||!target||!action.preparedRVA||target<action.preparedRVA){
        if(error)*error=@"Static Prepared Native Hook clear descriptor 无效";
        return NO;
    }
    uintptr_t imageBase=target-(uintptr_t)action.preparedRVA;
    if(action.staticHookSlotRVA>UINTPTR_MAX-imageBase){
        if(error)*error=@"Static Prepared hook slot RVA 地址溢出";
        return NO;
    }
    uintptr_t slot=imageBase+(uintptr_t)action.staticHookSlotRVA;
    if(!ZNNativeRuntimeAddressHasProtection(imageBase,slot,VM_PROT_WRITE)){
        if(error)*error=@"Static Prepared hook slot 不可写";
        return NO;
    }
    __atomic_store_n((uintptr_t *)slot,(uintptr_t)0,__ATOMIC_RELEASE);
    return YES;
}

static uint64_t ZNNativeAlign8(uint64_t value){return (value+7ULL)&~7ULL;}

static uint64_t ZNNativeImageFingerprint(uint32_t count){
    uint64_t h=UINT64_C(1469598103934665603);
    for(uint32_t i=0;i<count;i++){
        uintptr_t header=(uintptr_t)_dyld_get_image_header(i);
        intptr_t slide=_dyld_get_image_vmaddr_slide(i);
        const char *path=_dyld_get_image_name(i);
        h^=(uint64_t)header;h*=UINT64_C(1099511628211);
        h^=(uint64_t)slide;h*=UINT64_C(1099511628211);
        if(path)for(const unsigned char *p=(const unsigned char *)path;*p;p++){h^=*p;h*=UINT64_C(1099511628211);}
    }
    return h;
}

static NSString *ZNNativeReadActionString(const uint8_t *table,const ZNRuntimeActionHeader *header,uint32_t offset){
    if(!table||!header)return nil;
    uint64_t poolStart=header->stringPoolOffset,poolEnd=(uint64_t)header->stringPoolOffset+header->stringPoolSize;
    if(poolEnd>header->totalSize||offset<poolStart||offset>=poolEnd)return nil;
    const uint8_t *start=table+offset,*end=table+poolEnd;
    const uint8_t *nul=(const uint8_t *)memchr(start,0,(size_t)(end-start));
    if(!nul)return nil;
    NSData *data=[NSData dataWithBytes:start length:(NSUInteger)(nul-start)];
    return [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
}

static NSDictionary *ZNNativeDecodeDict(NSString *json){
    NSData *data=[json dataUsingEncoding:NSUTF8StringEncoding];
    id obj=data.length?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    return [obj isKindOfClass:NSDictionary.class]?obj:nil;
}

static void ZNNativeParseGeneratedImage(uint32_t imageIndex,NSMutableArray<ZNNativeHookAction *> *out,NSMutableSet *dedupe){
    const struct mach_header *raw=_dyld_get_image_header(imageIndex);
    if(!raw||raw->magic!=MH_MAGIC_64)return;
    const struct mach_header_64 *mh=(const struct mach_header_64 *)raw;
    intptr_t slide=_dyld_get_image_vmaddr_slide(imageIndex);
    const uint8_t *cursor=(const uint8_t *)(mh+1),*limit=cursor+mh->sizeofcmds;
    const struct section_64 *zndata=NULL;
    for(uint32_t i=0;i<mh->ncmds;i++){
        if(cursor+sizeof(struct load_command)>limit)return;
        const struct load_command *lc=(const struct load_command *)cursor;
        if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit)return;
        if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(struct segment_command_64)){
            const struct segment_command_64 *seg=(const struct segment_command_64 *)cursor;
            uint64_t sectionBytes=(uint64_t)seg->nsects*sizeof(struct section_64);
            if(lc->cmdsize<sizeof(*seg)+sectionBytes)return;
            if(strncmp(seg->segname,"__ZNDATA",16)==0){
                const struct section_64 *sections=(const struct section_64 *)(seg+1);
                for(uint32_t j=0;j<seg->nsects;j++)
                    if(strncmp(sections[j].sectname,"__zndata",16)==0){zndata=&sections[j];break;}
            }
        }
        if(zndata)break;
        cursor+=lc->cmdsize;
    }
    if(!zndata||zndata->size<sizeof(ZN44StaticHeader))return;
    __int128 runtimeAddress=(__int128)zndata->addr+(__int128)slide;
    if(runtimeAddress<=0||runtimeAddress>UINTPTR_MAX)return;
    const uint8_t *section=(const uint8_t *)(uintptr_t)runtimeAddress;
    const ZN44StaticHeader *sh=(const ZN44StaticHeader *)section;
    if(sh->magic0!=ZN44_STATIC_MAGIC0||sh->magic1!=ZN44_STATIC_MAGIC1||sh->entrySize!=sizeof(ZN44StaticEntry)||sh->count>ZN44_STATIC_MAX_ENTRIES)return;
    uint64_t actionRelative=0;
    if(!ZNGeneratedDataLayoutV1LocateRuntimeAction(section,zndata->size,&actionRelative)||
       actionRelative>zndata->size||zndata->size-actionRelative<sizeof(ZNRuntimeActionHeader))return;
    const uint8_t *table=section+actionRelative;
    const ZNRuntimeActionHeader *header=(const ZNRuntimeActionHeader *)table;
    if(header->magic!=ZN_RUNTIME_ACTION_MAGIC||header->version!=ZN_RUNTIME_ACTION_VERSION||
       header->entrySize!=sizeof(ZNRuntimeMethodCallEntry)||header->count>ZN_RUNTIME_ACTION_MAX_ENTRIES||
       header->totalSize>zndata->size-actionRelative)return;
    uint64_t fixedEnd=sizeof(*header)+(uint64_t)header->count*header->entrySize;
    if(fixedEnd>header->totalSize||header->stringPoolOffset<fixedEnd||header->stringPoolOffset>header->totalSize)return;

    const ZNRuntimeMethodCallEntry *entries=(const ZNRuntimeMethodCallEntry *)(table+sizeof(*header));
    for(uint32_t i=0;i<header->count;i++){
        const ZNRuntimeMethodCallEntry *entry=&entries[i];
        if(entry->kind!=ZNRuntimeActionKindIL2CPPNativeHook||entry->argumentCount>ZN_RUNTIME_ACTION_MAX_ARGUMENTS||
           !(entry->flags&ZNRuntimeActionFlagNativeHookConfig))continue;
        NSString *title=ZNNativeReadActionString(table,header,entry->titleOffset);
        NSString *group=ZNNativeReadActionString(table,header,entry->groupOffset);
        NSString *assembly=ZNNativeReadActionString(table,header,entry->assemblyOffset);
        NSString *ns=ZNNativeReadActionString(table,header,entry->namespaceOffset);
        NSString *cls=ZNNativeReadActionString(table,header,entry->classOffset);
        NSString *method=ZNNativeReadActionString(table,header,entry->methodOffset);
        NSString *configJSON=ZNNativeReadActionString(table,header,entry->reserved[0]);
        NSDictionary *cfg=ZNNativeDecodeDict(configJSON);
        if(!title||!group||!assembly||!ns||!cls||!method||!cfg)continue;
        NSString *templateKey=[cfg[@"template"] isKindOfClass:NSString.class]?cfg[@"template"]:@"";
        BOOL isArgScale=[templateKey isEqual:@"arg-scale-int32"];
        BOOL isManagedCallback=[templateKey isEqual:@"managed-callback-short-circuit"];
        BOOL isReturnBool=[templateKey isEqual:@"return-bool-override"];
        BOOL isStructField=[templateKey isEqual:@"struct-field-transform"];
        BOOL isComplexStruct=[templateKey isEqual:@"complex-struct-transform"];
        if(!isArgScale&&!isManagedCallback&&!isReturnBool&&!isStructField&&!isComplexStruct)continue;

        NSUInteger arg=[cfg[@"argumentIndex"] unsignedIntegerValue];
        NSInteger min=[cfg[@"min"] integerValue],max=[cfg[@"max"] integerValue],def=[cfg[@"default"] integerValue];
        NSUInteger callbackArg=[cfg[@"callbackArgumentIndex"] unsignedIntegerValue];
        BOOL callbackValue=[cfg[@"callbackValue"] boolValue];
        BOOL skipOriginal=[cfg[@"skipOriginal"] boolValue];
        BOOL returnBoolValue=cfg[@"returnBoolValue"]?[cfg[@"returnBoolValue"] boolValue]:YES;
        NSUInteger fieldArg=[cfg[@"fieldArgumentIndex"] unsignedIntegerValue];
        NSString *fieldMode=[cfg[@"fieldArgumentMode"] isKindOfClass:NSString.class]?cfg[@"fieldArgumentMode"]:@"";
        uint64_t fieldOffset=[cfg[@"fieldOffset"] unsignedLongLongValue];
        NSString *fieldCodec=[cfg[@"fieldCodec"] isKindOfClass:NSString.class]?cfg[@"fieldCodec"]:@"";
        NSString *codecAssembly=[cfg[@"codecAssembly"] isKindOfClass:NSString.class]?cfg[@"codecAssembly"]:@"";
        NSString *codecNamespace=[cfg[@"codecNamespace"] isKindOfClass:NSString.class]?cfg[@"codecNamespace"]:@"";
        NSString *codecClass=[cfg[@"codecClass"] isKindOfClass:NSString.class]?cfg[@"codecClass"]:@"";
        NSString *codecGetter=[cfg[@"codecGetterMethod"] isKindOfClass:NSString.class]?cfg[@"codecGetterMethod"]:@"";
        NSString *codecSetter=[cfg[@"codecSetterMethod"] isKindOfClass:NSString.class]?cfg[@"codecSetterMethod"]:@"";
        if(isArgScale&&(arg>=entry->argumentCount||min<1||max<min||def<min||def>max))continue;
        if(isManagedCallback&&(callbackArg>=entry->argumentCount||!skipOriginal))continue;
        if(isStructField&&(fieldArg>=entry->argumentCount||![fieldMode isEqualToString:@"indirect-pointer"]||
                          ![fieldCodec isEqualToString:@"secure-long-accessor"]||fieldOffset>0x100000ULL||
                          !codecClass.length||!codecGetter.length||!codecSetter.length||
                          min<1||max<min||def<min||def>max))continue;
        if(isComplexStruct){
            NSString *expectedCodec=ZNComplexStructCodecKeyForManagedType(codecClass);
            if(fieldArg>=entry->argumentCount||![fieldMode isEqualToString:@"indirect-pointer"]||
               !fieldCodec.length||![expectedCodec isEqualToString:fieldCodec]||fieldOffset!=0||
               !codecClass.length||min<1||max<min||def<min||def>max)continue;
        }

        NSArray *types=@[];BOOL sig=NO;
        if(entry->flags&ZNRuntimeActionFlagParameterSignature){
            NSString *encoded=ZNNativeReadActionString(table,header,entry->reserved[1]);
            if(encoded){types=ZNIL2CPPDecodeParameterTypeNames(encoded);sig=types.count==entry->argumentCount;}
        }
        NSString *desc=@"";
        if(entry->flags&ZNRuntimeActionFlagFeatureDescription)desc=ZNNativeReadActionString(table,header,entry->reserved[5])?:@"";

        ZNNativeHookAction *a=[ZNNativeHookAction new];
        a.actionID=entry->actionID;a.title=title.length?title:method;a.group=group.length?group:@"Native Hooks";
        a.featureDescription=desc;a.assembly=assembly;a.namespaceName=ns;a.className=cls;a.methodName=method;
        a.argumentCount=entry->argumentCount;a.parameterTypeNames=types;a.signatureAvailable=sig;
        if(isArgScale){
            a.templateKind=ZNNativeHookTemplateArgScaleInt32;a.argumentIndex=arg;
            a.minValue=min;a.maxValue=max;a.defaultValue=def;
        }else if(isManagedCallback){
            a.templateKind=ZNNativeHookTemplateManagedCallbackShortCircuit;
            a.callbackArgumentIndex=callbackArg;a.callbackValue=callbackValue;a.skipOriginal=YES;
            a.minValue=0;a.maxValue=1;a.defaultValue=0;
        }else if(isReturnBool){
            a.templateKind=ZNNativeHookTemplateReturnBoolOverride;
            a.returnBoolValue=returnBoolValue;
            a.minValue=0;a.maxValue=1;a.defaultValue=0;
        }else{
            a.templateKind=isComplexStruct?ZNNativeHookTemplateComplexStructTransform:ZNNativeHookTemplateStructFieldTransform;
            a.fieldArgumentIndex=fieldArg;a.fieldArgumentMode=fieldMode;a.fieldOffset=fieldOffset;
            a.fieldCodec=fieldCodec;a.codecAssembly=codecAssembly;a.codecNamespaceName=codecNamespace;
            a.codecClassName=codecClass;a.codecGetterMethod=codecGetter;a.codecSetterMethod=codecSetter;
            a.codecGetterArgumentCount=0;a.codecSetterArgumentCount=isComplexStruct?0:1;
            a.minValue=min;a.maxValue=max;a.defaultValue=def;
        }
        NSString *resolutionMode=[cfg[@"resolutionMode"] isKindOfClass:NSString.class]?cfg[@"resolutionMode"]:@"";
        a.preparedDescriptor=[cfg[@"prepared"] boolValue] ||
                             [resolutionMode isEqual:@"prepared-rva"] ||
                             [resolutionMode isEqual:@"static-prepatch-v1"];
        a.preparedRVA=[cfg[@"preparedRVA"] unsignedLongLongValue];
        a.preparedUUID=[cfg[@"preparedUUID"] isKindOfClass:NSString.class]?cfg[@"preparedUUID"]:@"";
        a.preparedStaticKnown=[cfg[@"preparedStaticKnown"] boolValue];
        a.preparedIsStatic=[cfg[@"preparedIsStatic"] boolValue];
        a.preparedCodecGetterRVA=[cfg[@"preparedCodecGetterRVA"] unsignedLongLongValue];
        a.preparedCodecSetterRVA=[cfg[@"preparedCodecSetterRVA"] unsignedLongLongValue];
        a.staticPrepatch=[cfg[@"staticPrepatch"] boolValue]||[resolutionMode isEqual:@"static-prepatch-v1"];
        a.staticHookSlotRVA=[cfg[@"staticHookSlotRVA"] unsignedLongLongValue];
        a.staticTrampolineRVA=[cfg[@"staticTrampolineRVA"] unsignedLongLongValue];
        a.staticCodeCaveRVA=[cfg[@"staticCodeCaveRVA"] unsignedLongLongValue];
        a.staticDisplacedInstruction=[cfg[@"staticDisplacedInstruction"] unsignedIntValue];
        a.fallbackRVA=[cfg[@"fallbackRVA"] unsignedLongLongValue];
        a.fallbackUUID=[cfg[@"fallbackUUID"] isKindOfClass:NSString.class]?cfg[@"fallbackUUID"]:@"";
        NSString *key=[NSString stringWithFormat:@"%u|%@",a.actionID,a.canonicalIdentity];
        if([dedupe containsObject:key])continue;
        [dedupe addObject:key];[out addObject:a];
    }
}

@interface ZNNativeHookRuntime ()
@property(nonatomic,copy,readwrite) NSArray<ZNNativeHookAction *> *generatedActions;
@property(nonatomic,assign) uint32_t generatedImageCount;
@property(nonatomic,assign) uint64_t generatedImageFingerprint;
@property(nonatomic,assign) BOOL generatedScanned;
@property(nonatomic,copy) NSDictionary<NSString *, id> *liveCandidate;
@property(nonatomic,copy) NSString *liveLifecycle;
@property(nonatomic,copy) NSString *liveTemplate;
@property(nonatomic,copy) NSString *liveError;
@end

@implementation ZNNativeHookRuntime

+ (instancetype)sharedRuntime {
    static ZNNativeHookRuntime *runtime;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ runtime=[ZNNativeHookRuntime new]; });
    return runtime;
}

- (instancetype)init {
    self=[super init];
    if(!self)return nil;
    _generatedActions=@[];
    _generatedImageCount=0;
    _generatedImageFingerprint=0;
    _generatedScanned=NO;
    _liveCandidate=@{};
    _liveLifecycle=@"";
    _liveTemplate=@"";
    _liveError=@"";
    ZNRegisterBuiltInComplexStructCodecs();
    return self;
}

- (void)refreshGeneratedActions {
    uint32_t count=_dyld_image_count();
    if(self.generatedScanned&&self.generatedImageCount==count)return;
    uint64_t fingerprint=ZNNativeImageFingerprint(count);
    NSMutableArray<ZNNativeHookAction *> *found=[NSMutableArray array];
    NSMutableSet *dedupe=[NSMutableSet set];
    for(uint32_t i=0;i<count;i++)ZNNativeParseGeneratedImage(i,found,dedupe);
    self.generatedActions=[found copy];
    self.generatedImageCount=count;
    self.generatedImageFingerprint=fingerprint;
    self.generatedScanned=YES;
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[native-hook-runtime] refresh -> %lu generated actions",(unsigned long)found.count]];
}

- (NSArray<NSNumber *> *)supportedInt32ArgumentIndicesForCandidate:(NSDictionary<NSString *,id> *)candidate
                                                            reason:(NSString **)reason {
    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    NSUInteger argc=[candidate[@"argumentCount"] unsignedIntegerValue];
    if(![abi[@"available"] boolValue]||params.count!=argc){
        if(reason)*reason=ZNNativeString(abi[@"reason"]).length?ZNNativeString(abi[@"reason"]):@"参数 ABI 不完整";
        return @[];
    }
    NSMutableArray *indices=[NSMutableArray array];
    for(NSUInteger i=0;i<params.count;i++){
        NSDictionary *p=params[i];
        if((ZNIL2CPPABIValueKind)[p[@"kind"] integerValue]==ZNIL2CPPABIValueKindSigned32)[indices addObject:@(i)];
    }
    if(!indices.count&&reason)*reason=@"当前 V1 只支持 int32/signed32 参数倍率";
    return indices;
}


- (NSArray<NSNumber *> *)supportedStructFieldArgumentIndicesForCandidate:(NSDictionary<NSString *,id> *)candidate
                                                                  reason:(NSString **)reason {
    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    NSUInteger argc=[candidate[@"argumentCount"] unsignedIntegerValue];
    if(![abi[@"available"] boolValue]||params.count!=argc){
        if(reason)*reason=ZNNativeString(abi[@"reason"]).length?ZNNativeString(abi[@"reason"]):@"参数 ABI 不完整";
        return @[];
    }
    if([abi[@"generic"] boolValue]||[abi[@"inflated"] boolValue]){
        if(reason)*reason=@"StructFieldTransform V1 暂不支持 generic/inflated 方法";
        return @[];
    }
    BOOL isStatic=!([abi[@"instanceKnown"] boolValue]&&[abi[@"instance"] boolValue]);
    NSMutableArray<NSNumber *> *indices=[NSMutableArray array];
    for(NSUInteger i=0;i<params.count;i++){
        NSDictionary *p=params[i];
        ZNIL2CPPABIValueKind kind=(ZNIL2CPPABIValueKind)[p[@"kind"] integerValue];
        BOOL candidateKind=(kind==ZNIL2CPPABIValueKindComplexValueType)||[p[@"byRef"] boolValue];
        uint32_t reg=0;
        if(candidateKind&&ZNNativeHookArgRegisterIndex(isStatic,i,argc,&reg)&&reg<8)[indices addObject:@(i)];
    }
    if(!indices.count&&reason)*reason=@"没有可用于 StructFieldTransform V1 的 complex/by-ref 参数";
    return indices;
}


- (BOOL)supportsReturnBoolOverrideForCandidate:(NSDictionary<NSString *,id> *)candidate
                                         reason:(NSString **)reason {
    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    NSDictionary *ret=[abi[@"return"] isKindOfClass:NSDictionary.class]?abi[@"return"]:@{};
    NSUInteger argc=[candidate[@"argumentCount"] unsignedIntegerValue];
    if(![abi[@"available"] boolValue]||params.count!=argc){
        if(reason)*reason=ZNNativeString(abi[@"reason"]).length?ZNNativeString(abi[@"reason"]):@"参数 ABI 不完整";
        return NO;
    }
    if([abi[@"generic"] boolValue]||[abi[@"inflated"] boolValue]){
        if(reason)*reason=@"ReturnBoolOverride V1 不支持 generic/inflated 方法";
        return NO;
    }
    if((ZNIL2CPPABIValueKind)[ret[@"kind"] integerValue]!=ZNIL2CPPABIValueKindBool){
        if(reason)*reason=@"ReturnBoolOverride V1 仅支持 bool 返回值";
        return NO;
    }
    NSUInteger gprCount=([abi[@"instance"] boolValue]?1u:0u)+argc;
    if(gprCount>7u){
        if(reason)*reason=@"ReturnBoolOverride V1 参数过多，需保留 hidden MethodInfo GPR";
        return NO;
    }
    for(NSDictionary *p in params){
        ZNIL2CPPABIValueKind kind=(ZNIL2CPPABIValueKind)[p[@"kind"] integerValue];
        BOOL gpr=(kind==ZNIL2CPPABIValueKindBool||kind==ZNIL2CPPABIValueKindSigned32||
                  kind==ZNIL2CPPABIValueKindUnsigned32||kind==ZNIL2CPPABIValueKindSigned64||
                  kind==ZNIL2CPPABIValueKindUnsigned64||kind==ZNIL2CPPABIValueKindPointer||
                  kind==ZNIL2CPPABIValueKindObjectReference);
        if(!gpr||[p[@"byRef"] boolValue]){
            if(reason)*reason=@"ReturnBoolOverride V1 仅支持 ARM64 GPR-safe 参数";
            return NO;
        }
    }
    return YES;
}

- (NSArray<NSNumber *> *)supportedManagedBoolCallbackArgumentIndicesForCandidate:(NSDictionary<NSString *,id> *)candidate
                                                                          reason:(NSString **)reason {
    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    NSDictionary *ret=[abi[@"return"] isKindOfClass:NSDictionary.class]?abi[@"return"]:@{};
    NSUInteger argc=[candidate[@"argumentCount"] unsignedIntegerValue];
    if(![abi[@"available"] boolValue]||params.count!=argc){
        if(reason)*reason=ZNNativeString(abi[@"reason"]).length?ZNNativeString(abi[@"reason"]):@"参数 ABI 不完整";
        return @[];
    }
    if((ZNIL2CPPABIValueKind)[ret[@"kind"] integerValue]!=ZNIL2CPPABIValueKindVoid){
        if(reason)*reason=@"ManagedCallbackShortCircuit V1 仅支持 void 目标方法";
        return @[];
    }
    if([abi[@"generic"] boolValue]||[abi[@"inflated"] boolValue]){
        if(reason)*reason=@"ManagedCallbackShortCircuit V1 不支持 generic/inflated 方法";
        return @[];
    }
    NSUInteger gprCount=([abi[@"instance"] boolValue]?1u:0u)+argc;
    if(gprCount>7u){
        if(reason)*reason=@"ManagedCallbackShortCircuit V1 参数过多，无法安全 passthrough original";
        return @[];
    }
    for(NSDictionary *p in params){
        ZNIL2CPPABIValueKind kind=(ZNIL2CPPABIValueKind)[p[@"kind"] integerValue];
        BOOL gpr=(kind==ZNIL2CPPABIValueKindBool||kind==ZNIL2CPPABIValueKindSigned32||
                  kind==ZNIL2CPPABIValueKindUnsigned32||kind==ZNIL2CPPABIValueKindSigned64||
                  kind==ZNIL2CPPABIValueKindUnsigned64||kind==ZNIL2CPPABIValueKindPointer||
                  kind==ZNIL2CPPABIValueKindObjectReference);
        if(!gpr){
            if(reason)*reason=@"ManagedCallbackShortCircuit permanent passthrough 仅支持 ARM64 GPR-safe 参数";
            return @[];
        }
    }
    NSMutableArray<NSNumber *> *indices=[NSMutableArray array];
    for(NSUInteger i=0;i<params.count;i++){
        NSDictionary *p=params[i];
        NSString *type=ZNNativeString(p[@"name"]).lowercaseString;
        BOOL actionBool=[type containsString:@"system.action"]&&[type containsString:@"system.boolean"];
        if((ZNIL2CPPABIValueKind)[p[@"kind"] integerValue]==ZNIL2CPPABIValueKindObjectReference&&actionBool)
            [indices addObject:@(i)];
    }
    if(!indices.count&&reason)*reason=@"未找到 System.Action<bool> 托管回调参数";
    return indices;
}


- (BOOL)installResolvedTarget:(uintptr_t)target
                    isStatic:(BOOL)isStatic
               argumentIndex:(NSUInteger)argumentIndex
               argumentCount:(NSUInteger)argumentCount
                  multiplier:(NSInteger)multiplier
                    actionID:(uint32_t)actionID
                       error:(NSString **)error {
    if(multiplier<1||multiplier>1000){if(error)*error=@"测试倍率必须在 1~1000";return NO;}
    uint32_t reg=0;
    if(!ZNNativeHookArgRegisterIndex(isStatic,argumentIndex,argumentCount,&reg)){
        if(error)*error=@"ArgScaleInt32 V2 仅支持映射到 ARM64 x0~x7 的参数";
        return NO;
    }

    ZNNativeSlot *existing=ZNNativeSlotForTarget(target);
    if(existing){
        uint32_t owner=existing->actionID.load(std::memory_order_acquire);
        if(owner&&actionID==0){
            if(error)*error=@"目标已由 Permanent Hook Scheduler 管理；临时测试不可覆盖";
            return NO;
        }
        if(owner&&actionID&&owner!=actionID){
            if(error)*error=@"目标已由其他 Permanent Hook Action 占用";
            return NO;
        }
        if(existing->registerIndex.load(std::memory_order_relaxed)!=reg){
            if(error)*error=@"同一 target 已安装不同参数位置的测试 Hook，请先恢复原方法";
            return NO;
        }
        existing->multiplier.store((int32_t)multiplier,std::memory_order_release);
        existing->enabled.store(multiplier!=1?1u:0u,std::memory_order_release);
        if(actionID){
            existing->actionID.store(actionID,std::memory_order_release);
            if(!ZNNativeHookRegistryBind(actionID,ZNNativeHookSlotKindArgScale,target,existing->original.load(std::memory_order_acquire),existing)){
                if(error)*error=@"Permanent Hook registry 已满";
                return NO;
            }
        }
        return YES;
    }

    ZNNativeSlot *slot=ZNNativeFreeSlot();
    if(!slot){if(error)*error=@"Native Hook slot 已满";return NO;}
    slot->multiplier.store((int32_t)multiplier,std::memory_order_relaxed);
    slot->enabled.store(multiplier!=1?1u:0u,std::memory_order_relaxed);
    slot->hits.store(0,std::memory_order_relaxed);
    slot->lastBefore.store(0,std::memory_order_relaxed);
    slot->lastAfter.store(0,std::memory_order_relaxed);
    slot->registerIndex.store(reg,std::memory_order_relaxed);
    slot->actionID.store(actionID,std::memory_order_relaxed);
    slot->original.store(0,std::memory_order_relaxed);
    slot->target.store(target,std::memory_order_release);

    NSUInteger slotIndex=(NSUInteger)(slot-gZNNativeSlots);
    void *original=NULL;
    NSString *hookError=nil;
    if(slotIndex>=kZNNativeMaxSlots ||
       ![[ZNNativeHookBackend sharedBackend] installReplacementAtAddress:target
                                                              replacement:gZNArgScaleBridgeReplacements[slotIndex]
                                                                 original:&original
                                                                    error:&hookError]){
        slot->target.store(0,std::memory_order_release);
        if(error)*error=hookError?:@"ArgScaleInt32 V2 DobbyHook 安装失败";
        return NO;
    }
    slot->original.store((uintptr_t)original,std::memory_order_release);
    if(actionID&&!ZNNativeHookRegistryBind(actionID,ZNNativeHookSlotKindArgScale,target,(uintptr_t)original,slot)){
        if(error)*error=@"Permanent Hook registry 已满";
        return NO;
    }
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[native-hook-v2] installed target=0x%llX reg=x%u multiplier=%ld action=%u original=0x%llX",
                                           (unsigned long long)target,reg,(long)multiplier,actionID,
                                           (unsigned long long)(uintptr_t)original]];
    return YES;
}


- (BOOL)installTemporaryArgScaleInt32ForCandidate:(NSDictionary<NSString *,id> *)candidate
                                     argumentIndex:(NSUInteger)argumentIndex
                                        multiplier:(NSInteger)multiplier
                                             error:(NSString **)error {
    NSArray *supported=[self supportedInt32ArgumentIndicesForCandidate:candidate reason:error];
    if(![supported containsObject:@(argumentIndex)])return NO;
    if(!ZNManagedPrepareInvokeBridge(error))return NO;
    NSString *assembly=ZNNativeString(candidate[@"assembly"]);if(!assembly.length)assembly=@"Assembly-CSharp.dll";
    NSString *ns=ZNNativeString(candidate[@"namespace"]);
    NSString *cls=ZNNativeString(candidate[@"class"]);
    NSString *method=ZNNativeString(candidate[@"method"]);
    NSUInteger argc=[candidate[@"argumentCount"] unsignedIntegerValue];
    NSDictionary *resolved=ZNNativeResolveDescriptor(assembly,ns,cls,method,argc,candidate,error);
    if(!resolved)return NO;
    BOOL ok=[self installResolvedTarget:[resolved[@"methodPointer"] unsignedLongLongValue]
                                      isStatic:[resolved[@"static"] boolValue]
                                 argumentIndex:argumentIndex
                                 argumentCount:argc
                                    multiplier:multiplier
                                      actionID:0
                                         error:error];
    NSMutableDictionary *live=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
    live[@"methodPointer"]=resolved[@"methodPointer"]?:@0;
    self.liveCandidate=[live copy];
    self.liveTemplate=@"ArgScaleInt32 V2 · ARM64 Register Bridge";
    self.liveLifecycle=ok?@"installed":@"failed";
    self.liveError=ok?@"":((error&&*error)?*error:@"Native Hook 安装失败");
    return ok;
}



- (BOOL)installTemporaryComplexStructTransformForCandidate:(NSDictionary<NSString *,id> *)candidate
                                                     argumentIndex:(NSUInteger)argumentIndex
                                                      codecAssembly:(NSString *)codecAssembly
                                                     codecNamespace:(NSString *)codecNamespace
                                                         codecClass:(NSString *)codecClass
                                                      getterMethod:(NSString *)getterMethod
                                                      setterMethod:(NSString *)setterMethod
                                                        multiplier:(NSInteger)multiplier
                                                             error:(NSString **)error {
    (void)codecAssembly;(void)codecNamespace;(void)codecClass;(void)getterMethod;(void)setterMethod;
    NSDictionary *abi=ZNIL2CPPDescribeMethodABI(candidate);
    NSArray *params=[abi[@"parameters"] isKindOfClass:NSArray.class]?abi[@"parameters"]:@[];
    if(argumentIndex>=params.count){if(error)*error=@"Complex Struct 参数索引无效";return NO;}
    NSString *managedType=[params[argumentIndex][@"name"] isKindOfClass:NSString.class]?params[argumentIndex][@"name"]:@"";
    NSString *codecKey=ZNComplexStructCodecKeyForManagedType(managedType);
    if(!codecKey.length){
        if(error)*error=[NSString stringWithFormat:@"Complex Struct 未注册匹配 Codec：%@",managedType.length?managedType:@"?"];
        return NO;
    }
    return [self installTemporaryStructFieldTransformForCandidate:candidate
                                                    argumentIndex:argumentIndex
                                                     argumentMode:@"indirect-pointer"
                                                      fieldOffset:0
                                                       fieldCodec:codecKey
                                                    codecAssembly:@""
                                                   codecNamespace:@""
                                                       codecClass:ZNComplexStructNormalizedManagedType(managedType)
                                                      getterMethod:@""
                                                      setterMethod:@""
                                                       multiplier:multiplier
                                                            error:error];
}

- (BOOL)installTemporaryStructFieldTransformForCandidate:(NSDictionary<NSString *,id> *)candidate
                                             argumentIndex:(NSUInteger)argumentIndex
                                              argumentMode:(NSString *)argumentMode
                                               fieldOffset:(uint64_t)fieldOffset
                                                fieldCodec:(NSString *)fieldCodec
                                             codecAssembly:(NSString *)codecAssembly
                                            codecNamespace:(NSString *)codecNamespace
                                                codecClass:(NSString *)codecClass
                                               getterMethod:(NSString *)getterMethod
                                               setterMethod:(NSString *)setterMethod
                                                multiplier:(NSInteger)multiplier
                                                     error:(NSString **)error {
    if(multiplier<1||multiplier>1000){if(error)*error=@"StructFieldTransform 倍率必须在 1~1000";return NO;}
    if(![argumentMode isEqualToString:@"indirect-pointer"]){if(error)*error=@"StructFieldTransform V1 仅支持 indirect-pointer";return NO;}
    BOOL legacy=[fieldCodec isEqualToString:@"secure-long-accessor"];
    BOOL whole=!legacy&&[[ZNComplexStructCodecRegistry sharedRegistry] supportsCodecKey:fieldCodec];
    if(!legacy&&!whole){if(error)*error=[NSString stringWithFormat:@"Struct codec 未注册：%@",fieldCodec?:@""];return NO;}
    if((legacy&&fieldOffset>0x100000ULL)||(whole&&fieldOffset!=0)){if(error)*error=@"Struct codec offset 与模式不匹配";return NO;}

    NSString *assembly=ZNNativeString(candidate[@"assembly"]);if(!assembly.length)assembly=@"Assembly-CSharp.dll";
    NSString *ns=ZNNativeString(candidate[@"namespace"]);
    NSString *cls=ZNNativeString(candidate[@"class"]);
    NSString *method=ZNNativeString(candidate[@"method"]);
    NSUInteger argc=[candidate[@"argumentCount"] unsignedIntegerValue];
    NSDictionary *resolved=ZNNativeResolveDescriptor(assembly,ns,cls,method,argc,candidate,error);
    if(!resolved)return NO;

    uint32_t reg=0;
    if(!ZNNativeHookArgRegisterIndex([resolved[@"static"] boolValue],argumentIndex,argc,&reg)){
        if(error)*error=@"StructFieldTransform 参数无法映射到 ARM64 x0~x7";
        return NO;
    }
    NSDictionary *codec=nil;
    if(whole){
        codec=[[ZNComplexStructCodecResolver sharedResolver] resolveManagedType:codecClass error:error];
        if(!codec)return NO;
        if(![codec[@"codecKey"] isEqualToString:fieldCodec]){
            if(error)*error=[NSString stringWithFormat:@"Codec 类型不匹配：type=%@ resolved=%@ expected=%@",
                             codecClass?:@"?",codec[@"codecKey"]?:@"?",fieldCodec?:@"?"];
            return NO;
        }
    }else{
        codec=ZNNativeResolveSecureLongCodec(codecAssembly,codecNamespace,codecClass,getterMethod,setterMethod,error);
        if(!codec)return NO;
    }

    uintptr_t target=[resolved[@"methodPointer"] unsignedLongLongValue];
    if(ZNNativeSlotForTarget(target)||ZNManagedCallbackSlotForTarget(target)||ZNReturnBoolSlotForTarget(target)){
        if(error)*error=@"同一 target 已安装其他 Native Hook，请先恢复原方法";
        return NO;
    }
    ZNStructFieldSlot *existing=ZNStructFieldSlotForTarget(target);
    if(existing){
        if(existing->actionID.load(std::memory_order_acquire)){
            if(error)*error=@"目标已由 Permanent Hook Scheduler 管理；临时 StructField 测试不可覆盖";
            return NO;
        }
        if(existing->argumentRegister.load(std::memory_order_relaxed)!=reg||
           existing->fieldOffset.load(std::memory_order_relaxed)!=fieldOffset){
            if(error)*error=@"同一 target 已安装不同 StructFieldTransform 配置，请先恢复原方法";
            return NO;
        }
        existing->multiplier.store((int32_t)multiplier,std::memory_order_release);
        existing->enabled.store(multiplier!=1?1u:0u,std::memory_order_release);
        return YES;
    }

    ZNStructFieldSlot *slot=ZNStructFieldFreeSlot();
    if(!slot){if(error)*error=@"StructFieldTransform Hook slot 已满";return NO;}
    NSUInteger slotIndex=(NSUInteger)(slot-gZNStructFieldSlots);
    slot->getter.store([codec[whole?@"function0":@"getter"] unsignedLongLongValue],std::memory_order_relaxed);
    slot->setter.store([codec[whole?@"function1":@"setter"] unsignedLongLongValue],std::memory_order_relaxed);
    slot->function2.store([codec[@"function2"] unsignedLongLongValue],std::memory_order_relaxed);
    slot->function3.store([codec[@"function3"] unsignedLongLongValue],std::memory_order_relaxed);
    slot->methodInfo0.store([codec[@"methodInfo0"] unsignedLongLongValue],std::memory_order_relaxed);
    slot->methodInfo1.store([codec[@"methodInfo1"] unsignedLongLongValue],std::memory_order_relaxed);
    slot->methodInfo2.store([codec[@"methodInfo2"] unsignedLongLongValue],std::memory_order_relaxed);
    slot->methodInfo3.store([codec[@"methodInfo3"] unsignedLongLongValue],std::memory_order_relaxed);
    slot->codecVariant.store([codec[@"variant"] unsignedIntValue],std::memory_order_relaxed);
    slot->multiplier.store((int32_t)multiplier,std::memory_order_relaxed);
    slot->enabled.store(multiplier!=1?1u:0u,std::memory_order_relaxed);
    slot->hits.store(0,std::memory_order_relaxed);
    slot->failures.store(0,std::memory_order_relaxed);
    slot->lastBefore.store(0,std::memory_order_relaxed);
    slot->lastAfter.store(0,std::memory_order_relaxed);
    slot->lastBase.store(0,std::memory_order_relaxed);
    slot->lastField.store(0,std::memory_order_relaxed);
    slot->argumentRegister.store(reg,std::memory_order_relaxed);
    slot->fieldOffset.store(fieldOffset,std::memory_order_relaxed);
    uintptr_t transform=0;
    if(whole){
        NSValue *tv=[[ZNComplexStructCodecRegistry sharedRegistry] transformValueForCodecKey:fieldCodec];
        transform=(uintptr_t)tv.pointerValue;
        if(!transform){if(error)*error=@"Complex Struct codec 未注册";slot->target.store(0,std::memory_order_release);return NO;}
    }
    slot->codecTransform.store(transform,std::memory_order_relaxed);
    slot->actionID.store(0,std::memory_order_relaxed);
    slot->original.store(0,std::memory_order_relaxed);
    slot->target.store(target,std::memory_order_release);

    void *original=NULL;NSString *hookError=nil;
    if(slotIndex>=kZNStructFieldMaxSlots||
       ![[ZNNativeHookBackend sharedBackend] installReplacementAtAddress:target
                                                              replacement:gZNStructFieldBridgeReplacements[slotIndex]
                                                                 original:&original
                                                                    error:&hookError]){
        slot->target.store(0,std::memory_order_release);
        if(error)*error=hookError?:@"StructFieldTransform DobbyHook 安装失败";
        return NO;
    }
    slot->original.store((uintptr_t)original,std::memory_order_release);

    NSMutableDictionary *live=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
    live[@"methodPointer"]=@(target);
    self.liveCandidate=[live copy];
    self.liveTemplate=whole?[NSString stringWithFormat:@"ComplexStructTransform V1 · %@",codec[@"displayName"]?:fieldCodec]:@"StructFieldTransform V1 · SecureLong Accessor";
    self.liveLifecycle=@"installed";
    self.liveError=@"";
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[%@] installed target=0x%llX reg=x%u multiplier=%ld codec=%@ type=%@",
                                       whole?@"complex-struct-hook":@"struct-field-hook",
                                       (unsigned long long)target,reg,(long)multiplier,
                                       whole?(codec[@"codecKey"]?:fieldCodec):fieldCodec,
                                       whole?(codec[@"managedType"]?:codecClass):codecClass]];
    return YES;
}

- (BOOL)installTemporaryReturnBoolOverrideForCandidate:(NSDictionary<NSString *,id> *)candidate
                                                  value:(BOOL)value
                                                  error:(NSString **)error {
    NSString *reason=nil;
    if(![self supportsReturnBoolOverrideForCandidate:candidate reason:&reason]){
        if(error)*error=reason?:@"ReturnBoolOverride ABI 不支持";
        return NO;
    }
    NSString *assembly=ZNNativeString(candidate[@"assembly"]);if(!assembly.length)assembly=@"Assembly-CSharp.dll";
    NSString *ns=ZNNativeString(candidate[@"namespace"]);
    NSString *cls=ZNNativeString(candidate[@"class"]);
    NSString *method=ZNNativeString(candidate[@"method"]);
    NSUInteger argc=[candidate[@"argumentCount"] unsignedIntegerValue];
    NSDictionary *resolved=ZNNativeResolveDescriptor(assembly,ns,cls,method,argc,candidate,error);
    if(!resolved)return NO;
    uintptr_t target=[resolved[@"methodPointer"] unsignedLongLongValue];
    if(ZNNativeSlotForTarget(target)||ZNManagedCallbackSlotForTarget(target)){
        if(error)*error=@"同一 target 已安装其他 Native Hook，请先恢复原方法";
        return NO;
    }
    ZNReturnBoolSlot *existing=ZNReturnBoolSlotForTarget(target);
    if(existing){
        if(existing->actionID.load(std::memory_order_acquire)){
            if(error)*error=@"目标已由 Permanent Hook Scheduler 管理；临时 ReturnBool 测试不可覆盖";
            return NO;
        }
        existing->forcedValue.store(value?1u:0u,std::memory_order_release);
        existing->enabled.store(1u,std::memory_order_release);
        NSMutableDictionary *live=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
        live[@"methodPointer"]=@(target);
        self.liveCandidate=[live copy];self.liveTemplate=@"ReturnBoolOverride";self.liveLifecycle=@"installed";self.liveError=@"";
        return YES;
    }
    ZNReturnBoolSlot *slot=ZNReturnBoolFreeSlot();
    if(!slot){if(error)*error=@"ReturnBoolOverride Hook slot 已满";return NO;}
    NSUInteger slotIndex=(NSUInteger)(slot-gZNReturnBoolSlots);
    slot->forcedValue.store(value?1u:0u,std::memory_order_relaxed);
    slot->enabled.store(1u,std::memory_order_relaxed);
    slot->hits.store(0,std::memory_order_relaxed);
    slot->lastOriginal.store(UINT32_MAX,std::memory_order_relaxed);
    slot->lastOverride.store(value?1u:0u,std::memory_order_relaxed);
    slot->actionID.store(0,std::memory_order_relaxed);
    slot->original.store(0,std::memory_order_relaxed);
    slot->target.store(target,std::memory_order_release);

    void *original=NULL;NSString *hookError=nil;
    if(slotIndex>=kZNReturnBoolMaxSlots||
       ![[ZNNativeHookBackend sharedBackend] installReplacementAtAddress:target
                                                              replacement:gZNReturnBoolReplacements[slotIndex]
                                                                 original:&original
                                                                    error:&hookError]){
        slot->target.store(0,std::memory_order_release);
        NSString *message=hookError?:@"ReturnBoolOverride DobbyHook 安装失败";
        if(error)*error=message;
        NSMutableDictionary *live=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
        live[@"methodPointer"]=@(target);
        self.liveCandidate=[live copy];self.liveTemplate=@"ReturnBoolOverride";self.liveLifecycle=@"failed";self.liveError=message;
        return NO;
    }
    slot->original.store((uintptr_t)original,std::memory_order_release);
    NSMutableDictionary *live=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
    live[@"methodPointer"]=@(target);
    self.liveCandidate=[live copy];self.liveTemplate=@"ReturnBoolOverride";self.liveLifecycle=@"installed";self.liveError=@"";
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[return-bool-hook] installed target=0x%llX force=%@ original=0x%llX",
                                       (unsigned long long)target,value?@"true":@"false",(unsigned long long)(uintptr_t)original]];
    return YES;
}

- (BOOL)installTemporaryManagedCallbackShortCircuitForCandidate:(NSDictionary<NSString *,id> *)candidate
                                                   argumentIndex:(NSUInteger)argumentIndex
                                                   callbackValue:(BOOL)callbackValue
                                                           error:(NSString **)error {
    NSArray<NSNumber *> *supported=[self supportedManagedBoolCallbackArgumentIndicesForCandidate:candidate reason:error];
    if(![supported containsObject:@(argumentIndex)])return NO;
    NSString *assembly=ZNNativeString(candidate[@"assembly"]);if(!assembly.length)assembly=@"Assembly-CSharp.dll";
    NSString *ns=ZNNativeString(candidate[@"namespace"]);
    NSString *cls=ZNNativeString(candidate[@"class"]);
    NSString *method=ZNNativeString(candidate[@"method"]);
    NSUInteger argc=[candidate[@"argumentCount"] unsignedIntegerValue];
    NSDictionary *resolved=ZNNativeResolveDescriptor(assembly,ns,cls,method,argc,candidate,error);
    if(!resolved)return NO;
    uintptr_t target=[resolved[@"methodPointer"] unsignedLongLongValue];
    if(ZNNativeSlotForTarget(target)||ZNReturnBoolSlotForTarget(target)){
        if(error)*error=@"同一 target 已安装其他 Native Hook，请先恢复原方法";
        return NO;
    }
    uint32_t reg=0;
    if(!ZNNativeHookArgRegisterIndex([resolved[@"static"] boolValue],argumentIndex,argc,&reg)){
        if(error)*error=@"Managed callback 参数无法映射到 ARM64 x0~x7";
        return NO;
    }
    ZNManagedCallbackSlot *existing=ZNManagedCallbackSlotForTarget(target);
    if(existing){
        if(existing->actionID.load(std::memory_order_acquire)){
            if(error)*error=@"目标已由 Permanent Hook Scheduler 管理；临时 Callback 测试不可覆盖";
            return NO;
        }
        if(existing->callbackRegister.load(std::memory_order_relaxed)!=reg){
            if(error)*error=@"同一 target 已安装不同 callback 参数的 Hook，请先恢复原方法";
            return NO;
        }
        existing->callbackValue.store(callbackValue?1u:0u,std::memory_order_release);
        existing->enabled.store(1u,std::memory_order_release);
        NSMutableDictionary *live=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
        live[@"methodPointer"]=resolved[@"methodPointer"]?:@0;
        self.liveCandidate=[live copy];
        self.liveTemplate=@"ManagedCallbackShortCircuit";
        self.liveLifecycle=@"installed";
        self.liveError=@"";
        return YES;
    }
    ZNManagedCallbackSlot *slot=ZNManagedCallbackFreeSlot();
    if(!slot){if(error)*error=@"ManagedCallback Hook slot 已满";return NO;}
    NSUInteger slotIndex=(NSUInteger)(slot-gZNManagedCallbackSlots);
    slot->callbackRegister.store(reg,std::memory_order_relaxed);
    slot->callbackValue.store(callbackValue?1u:0u,std::memory_order_relaxed);
    slot->enabled.store(1u,std::memory_order_relaxed);
    slot->hits.store(0,std::memory_order_relaxed);
    slot->callbackSuccess.store(0,std::memory_order_relaxed);
    slot->callbackFailure.store(0,std::memory_order_relaxed);
    slot->lastReceiver.store(0,std::memory_order_relaxed);
    slot->lastCallback.store(0,std::memory_order_relaxed);
    slot->isStatic.store([resolved[@"static"] boolValue]?1u:0u,std::memory_order_relaxed);
    slot->actionID.store(0,std::memory_order_relaxed);
    slot->original.store(0,std::memory_order_relaxed);
    slot->target.store(target,std::memory_order_release);

    void *original=NULL;
    NSString *hookError=nil;
    if(slotIndex>=kZNManagedCallbackMaxSlots||
       ![[ZNNativeHookBackend sharedBackend] installReplacementAtAddress:target
                                                              replacement:gZNManagedCallbackReplacements[slotIndex]
                                                                 original:&original
                                                                    error:&hookError]){
        slot->target.store(0,std::memory_order_release);
        NSString *message=hookError?:@"Dobby replacement 安装失败";
        if(error)*error=message;
        NSMutableDictionary *live=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
        live[@"methodPointer"]=@(target);
        self.liveCandidate=[live copy];
        self.liveTemplate=@"ManagedCallbackShortCircuit";
        self.liveLifecycle=@"failed";
        self.liveError=message;
        return NO;
    }
    slot->original.store((uintptr_t)original,std::memory_order_release);
    NSMutableDictionary *live=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
    live[@"methodPointer"]=@(target);
    self.liveCandidate=[live copy];
    self.liveTemplate=@"ManagedCallbackShortCircuit";
    self.liveLifecycle=@"installed";
    self.liveError=@"";
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[managed-callback-hook] installed target=0x%llX callbackReg=x%u value=%@ original=0x%llX",
                                       (unsigned long long)target,reg,callbackValue?@"true":@"false",
                                       (unsigned long long)(uintptr_t)original]];
    return YES;
}

- (BOOL)removeTemporaryHookForCandidate:(NSDictionary<NSString *,id> *)candidate error:(NSString **)error {
    NSString *assembly=ZNNativeString(candidate[@"assembly"]);if(!assembly.length)assembly=@"Assembly-CSharp.dll";
    NSString *ns=ZNNativeString(candidate[@"namespace"]);
    NSString *cls=ZNNativeString(candidate[@"class"]);
    NSString *method=ZNNativeString(candidate[@"method"]);
    NSUInteger argc=[candidate[@"argumentCount"] unsignedIntegerValue];
    NSDictionary *resolved=ZNNativeResolveDescriptor(assembly,ns,cls,method,argc,candidate,error);
    if(!resolved)return NO;
    uintptr_t target=[resolved[@"methodPointer"] unsignedLongLongValue];
    ZNNativeSlot *slot=ZNNativeSlotForTarget(target);
    ZNManagedCallbackSlot *callbackSlot=ZNManagedCallbackSlotForTarget(target);
    ZNReturnBoolSlot *returnBoolSlot=ZNReturnBoolSlotForTarget(target);
    ZNStructFieldSlot *fieldSlot=ZNStructFieldSlotForTarget(target);
    uint32_t permanentOwner=0;
    if(slot)permanentOwner=slot->actionID.load(std::memory_order_acquire);
    if(!permanentOwner&&callbackSlot)permanentOwner=callbackSlot->actionID.load(std::memory_order_acquire);
    if(!permanentOwner&&returnBoolSlot)permanentOwner=returnBoolSlot->actionID.load(std::memory_order_acquire);
    if(!permanentOwner&&fieldSlot)permanentOwner=fieldSlot->actionID.load(std::memory_order_acquire);
    if(permanentOwner){
        if(error)*error=[NSString stringWithFormat:@"目标由 Permanent Hook Action %u 管理；不能从临时测试路径卸载",permanentOwner];
        return NO;
    }
    if(!slot&&!callbackSlot&&!returnBoolSlot&&!fieldSlot){
        NSMutableDictionary *live=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
        live[@"methodPointer"]=@(target);
        self.liveCandidate=[live copy];
        self.liveLifecycle=@"restored";
        self.liveError=@"";
        return YES;
    }
    NSString *destroyError=nil;
    if(![[ZNNativeHookBackend sharedBackend] destroyHookAtAddress:target error:&destroyError]){
        if(error)*error=destroyError;return NO;
    }
    if(slot){slot->target.store(0,std::memory_order_release);slot->original.store(0,std::memory_order_relaxed);slot->actionID.store(0,std::memory_order_relaxed);}
    if(callbackSlot){
        callbackSlot->target.store(0,std::memory_order_release);
        callbackSlot->original.store(0,std::memory_order_relaxed);
        callbackSlot->actionID.store(0,std::memory_order_relaxed);
    }
    if(returnBoolSlot){
        returnBoolSlot->target.store(0,std::memory_order_release);
        returnBoolSlot->original.store(0,std::memory_order_relaxed);
        returnBoolSlot->actionID.store(0,std::memory_order_relaxed);
    }
    if(fieldSlot){
        fieldSlot->target.store(0,std::memory_order_release);
        fieldSlot->original.store(0,std::memory_order_relaxed);
        fieldSlot->actionID.store(0,std::memory_order_relaxed);
    }
    NSMutableDictionary *live=[candidate mutableCopy]?:[NSMutableDictionary dictionary];
    live[@"methodPointer"]=@(target);
    self.liveCandidate=[live copy];
    self.liveLifecycle=@"restored";
    self.liveError=@"";
    [[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[native-hook] restored target=0x%llX",(unsigned long long)target]];
    return YES;
}

- (NSString *)diagnosticsForCandidate:(NSDictionary<NSString *,id> *)candidate {
    uintptr_t target=[candidate[@"methodPointer"] unsignedLongLongValue];
    ZNNativeSlot *slot=ZNNativeSlotForTarget(target);
    if(slot){
        return [NSString stringWithFormat:@"Hook 状态：已安装\nTarget：0x%llX\nHits：%llu\n最近参数：%d → %d\n倍率：x%d",
                (unsigned long long)target,
                (unsigned long long)slot->hits.load(std::memory_order_relaxed),
                slot->lastBefore.load(std::memory_order_relaxed),
                slot->lastAfter.load(std::memory_order_relaxed),
                slot->multiplier.load(std::memory_order_relaxed)];
    }
    ZNStructFieldSlot *fieldSlot=ZNStructFieldSlotForTarget(target);
    if(fieldSlot){
        return [NSString stringWithFormat:@"Hook 状态：已安装 ✅\nTarget：0x%llX\nHits：%llu\nFailures：%llu\nBase：0x%llX\nField：0x%llX (+0x%llX)\nValue：%lld → %lld\n倍率：x%d",
                (unsigned long long)target,
                (unsigned long long)fieldSlot->hits.load(std::memory_order_relaxed),
                (unsigned long long)fieldSlot->failures.load(std::memory_order_relaxed),
                (unsigned long long)fieldSlot->lastBase.load(std::memory_order_relaxed),
                (unsigned long long)fieldSlot->lastField.load(std::memory_order_relaxed),
                (unsigned long long)fieldSlot->fieldOffset.load(std::memory_order_relaxed),
                (long long)fieldSlot->lastBefore.load(std::memory_order_relaxed),
                (long long)fieldSlot->lastAfter.load(std::memory_order_relaxed),
                fieldSlot->multiplier.load(std::memory_order_relaxed)];
    }
    ZNReturnBoolSlot *returnBoolSlot=ZNReturnBoolSlotForTarget(target);
    if(returnBoolSlot){
        return [NSString stringWithFormat:@"Hook 状态：已安装 ✅\nTarget：0x%llX\nHits：%llu\nOriginal Return：%@\nOverride Return：%@",
                (unsigned long long)target,
                (unsigned long long)returnBoolSlot->hits.load(std::memory_order_relaxed),
                returnBoolSlot->lastOriginal.load(std::memory_order_relaxed)==UINT32_MAX?@"Skipped":
                    (returnBoolSlot->lastOriginal.load(std::memory_order_relaxed)?@"true":@"false"),
                returnBoolSlot->lastOverride.load(std::memory_order_relaxed)?@"true":@"false"];
    }
    ZNManagedCallbackSlot *callbackSlot=ZNManagedCallbackSlotForTarget(target);
    if(callbackSlot){
        uintptr_t receiver=callbackSlot->lastReceiver.load(std::memory_order_relaxed);
        uintptr_t callback=callbackSlot->lastCallback.load(std::memory_order_relaxed);
        return [NSString stringWithFormat:@"Hook 状态：已安装 ✅\nTarget：0x%llX\nHits：%llu\nCallback Success：%llu\nCallback Failed：%llu\n最近 receiver：%@\n最近 callback：%@\nInvoke：%@\nOriginal：Skipped",
                (unsigned long long)target,
                (unsigned long long)callbackSlot->hits.load(std::memory_order_relaxed),
                (unsigned long long)callbackSlot->callbackSuccess.load(std::memory_order_relaxed),
                (unsigned long long)callbackSlot->callbackFailure.load(std::memory_order_relaxed),
                receiver?[NSString stringWithFormat:@"0x%llX",(unsigned long long)receiver]:@"—",
                callback?[NSString stringWithFormat:@"0x%llX",(unsigned long long)callback]:@"—",
                callbackSlot->callbackValue.load(std::memory_order_relaxed)?@"true":@"false"];
    }
    return @"Hook 状态：未安装";
}


- (BOOL)hasLiveTestStatus {
    NSString *life=self.liveLifecycle?:@"";
    return [life isEqualToString:@"installed"]||[life isEqualToString:@"failed"];
}

- (void)clearLiveTestStatus {
    self.liveCandidate=@{};
    self.liveLifecycle=@"";
    self.liveTemplate=@"";
    self.liveError=@"";
}

- (NSString *)liveTestStatus {
    NSString *life=self.liveLifecycle?:@"";
    NSDictionary *candidate=self.liveCandidate?:@{};
    NSString *cls=ZNNativeString(candidate[@"class"]);
    NSString *method=ZNNativeString(candidate[@"method"]);
    NSUInteger argc=[candidate[@"argumentCount"] unsignedIntegerValue];
    NSString *identity=(cls.length||method.length)?[NSString stringWithFormat:@"%@::%@/%lu",cls,method,(unsigned long)argc]:@"Native Hook";
    uintptr_t target=[candidate[@"methodPointer"] unsignedLongLongValue];

    if([life isEqualToString:@"failed"]){
        return [NSString stringWithFormat:@"Hook：安装失败 ❌ · %@\n模板：%@ · Target：%@\n%@",
                identity,self.liveTemplate.length?self.liveTemplate:@"—",
                target?[NSString stringWithFormat:@"0x%llX",(unsigned long long)target]:@"—",
                self.liveError.length?self.liveError:@"未知错误"];
    }
    if([life isEqualToString:@"restored"])return @""; // page status owns restored state; later test/capture may replace it
    if([life isEqualToString:@"installed"]){
        NSString *diag=[self diagnosticsForCandidate:candidate];
        return [NSString stringWithFormat:@"%@\n模板：%@\n%@",
                identity,self.liveTemplate.length?self.liveTemplate:@"Native Hook",diag.length?diag:@"Hook 状态：已安装 · 等待命中"];
    }
    return @"";
}

- (BOOL)zn_installPreparedArgScaleAction:(ZNNativeHookAction *)action
                                          target:(uintptr_t)target
                                           value:(NSInteger)value
                                           error:(NSString **)error {
    if(value<1||value>1000){if(error)*error=@"ArgScaleInt32 倍率必须在 1~1000";return NO;}
    uint32_t reg=0;
    if(!ZNNativeHookArgRegisterIndex(action.preparedIsStatic,
                                     action.argumentIndex,
                                     action.argumentCount,&reg)){
        if(error)*error=@"Prepared ArgScale 参数无法映射到 ARM64 x0~x7";
        return NO;
    }
    if(ZNManagedCallbackSlotForTarget(target)||ZNReturnBoolSlotForTarget(target)||ZNStructFieldSlotForTarget(target)){
        if(error)*error=@"同一 target 已安装其他 Native Hook";
        return NO;
    }

    ZNNativeSlot *existing=ZNNativeSlotForTarget(target);
    if(existing){
        uint32_t owner=existing->actionID.load(std::memory_order_acquire);
        if(owner&&owner!=action.actionID){if(error)*error=@"target 已由其他 ArgScale Action 占用";return NO;}
        if(existing->registerIndex.load(std::memory_order_relaxed)!=reg){
            if(error)*error=@"Prepared ArgScale register 与已安装 Hook 不一致";return NO;
        }
        existing->actionID.store(action.actionID,std::memory_order_release);
        existing->multiplier.store((int32_t)value,std::memory_order_release);
        existing->enabled.store(value!=1?1u:0u,std::memory_order_release);
        if(!ZNNativeHookRegistryBind(action.actionID,ZNNativeHookSlotKindArgScale,target,
                                     existing->original.load(std::memory_order_acquire),existing)){
            if(error)*error=@"Permanent Hook registry 已满";return NO;
        }
        return YES;
    }

    ZNNativeSlot *slot=ZNNativeFreeSlot();
    if(!slot){if(error)*error=@"Native Hook slot 已满";return NO;}
    NSUInteger slotIndex=(NSUInteger)(slot-gZNNativeSlots);
    slot->multiplier.store((int32_t)value,std::memory_order_relaxed);
    slot->enabled.store(value!=1?1u:0u,std::memory_order_relaxed);
    slot->hits.store(0,std::memory_order_relaxed);
    slot->lastBefore.store(0,std::memory_order_relaxed);
    slot->lastAfter.store(0,std::memory_order_relaxed);
    slot->registerIndex.store(reg,std::memory_order_relaxed);
    slot->actionID.store(action.actionID,std::memory_order_relaxed);
    slot->original.store(0,std::memory_order_relaxed);
    slot->target.store(target,std::memory_order_release);

    uintptr_t original=0;NSString *hookError=nil;
    if(slotIndex>=kZNNativeMaxSlots||
       !ZNNativeStaticPrepatchBind(action,target,gZNArgScaleBridgeReplacements[slotIndex],&original,&hookError)){
        slot->target.store(0,std::memory_order_release);
        slot->actionID.store(0,std::memory_order_relaxed);
        if(error)*error=hookError?:@"Prepared ArgScale static bind 失败";
        return NO;
    }
    slot->original.store(original,std::memory_order_release);
    if(!ZNNativeHookRegistryBind(action.actionID,ZNNativeHookSlotKindArgScale,target,original,slot)){
        if(error)*error=@"Permanent Hook registry 已满";return NO;
    }
    return YES;
}

- (BOOL)zn_installPreparedReturnBoolAction:(ZNNativeHookAction *)action
                                            target:(uintptr_t)target
                                             value:(NSInteger)value
                                             error:(NSString **)error {
    if(ZNNativeSlotForTarget(target)||ZNManagedCallbackSlotForTarget(target)||ZNStructFieldSlotForTarget(target)){
        if(error)*error=@"同一 target 已安装其他 Native Hook";
        return NO;
    }
    ZNReturnBoolSlot *existing=ZNReturnBoolSlotForTarget(target);
    if(existing){
        uint32_t owner=existing->actionID.load(std::memory_order_acquire);
        if(owner&&owner!=action.actionID){if(error)*error=@"target 已由其他 ReturnBool Action 占用";return NO;}
        existing->actionID.store(action.actionID,std::memory_order_release);
        existing->forcedValue.store(action.returnBoolValue?1u:0u,std::memory_order_release);
        existing->enabled.store(value!=0?1u:0u,std::memory_order_release);
        if(!ZNNativeHookRegistryBind(action.actionID,ZNNativeHookSlotKindReturnBool,target,
                                     existing->original.load(std::memory_order_acquire),existing)){
            if(error)*error=@"Permanent Hook registry 已满";return NO;
        }
        return YES;
    }

    ZNReturnBoolSlot *slot=ZNReturnBoolFreeSlot();
    if(!slot){if(error)*error=@"ReturnBoolOverride Hook slot 已满";return NO;}
    NSUInteger slotIndex=(NSUInteger)(slot-gZNReturnBoolSlots);
    slot->forcedValue.store(action.returnBoolValue?1u:0u,std::memory_order_relaxed);
    slot->enabled.store(value!=0?1u:0u,std::memory_order_relaxed);
    slot->hits.store(0,std::memory_order_relaxed);
    slot->lastOriginal.store(UINT32_MAX,std::memory_order_relaxed);
    slot->lastOverride.store(action.returnBoolValue?1u:0u,std::memory_order_relaxed);
    slot->actionID.store(action.actionID,std::memory_order_relaxed);
    slot->original.store(0,std::memory_order_relaxed);
    slot->target.store(target,std::memory_order_release);

    uintptr_t original=0;NSString *hookError=nil;
    if(slotIndex>=kZNReturnBoolMaxSlots||
       !ZNNativeStaticPrepatchBind(action,target,gZNReturnBoolReplacements[slotIndex],&original,&hookError)){
        slot->target.store(0,std::memory_order_release);
        slot->actionID.store(0,std::memory_order_relaxed);
        if(error)*error=hookError?:@"Prepared ReturnBool static bind 失败";
        return NO;
    }
    slot->original.store(original,std::memory_order_release);
    if(!ZNNativeHookRegistryBind(action.actionID,ZNNativeHookSlotKindReturnBool,target,
                                 original,slot)){
        if(error)*error=@"Permanent Hook registry 已满";return NO;
    }
    return YES;
}

- (BOOL)zn_installPreparedManagedCallbackAction:(ZNNativeHookAction *)action
                                           target:(uintptr_t)target
                                            value:(NSInteger)value
                                            error:(NSString **)error {
    uint32_t reg=0;
    if(!ZNNativeHookArgRegisterIndex(action.preparedIsStatic,
                                     action.callbackArgumentIndex,
                                     action.argumentCount,&reg)){
        if(error)*error=@"Prepared ManagedCallback 参数无法映射到 ARM64 x0~x7";
        return NO;
    }
    if(value!=0 && !ZNManagedPrepareInvokeBridge(error))return NO;
    if(ZNNativeSlotForTarget(target)||ZNReturnBoolSlotForTarget(target)||ZNStructFieldSlotForTarget(target)){
        if(error)*error=@"同一 target 已安装其他 Native Hook";
        return NO;
    }

    ZNManagedCallbackSlot *existing=ZNManagedCallbackSlotForTarget(target);
    if(existing){
        uint32_t owner=existing->actionID.load(std::memory_order_acquire);
        if(owner&&owner!=action.actionID){if(error)*error=@"target 已由其他 ManagedCallback Action 占用";return NO;}
        if(existing->callbackRegister.load(std::memory_order_relaxed)!=reg){
            if(error)*error=@"Prepared ManagedCallback register 与已安装 Hook 不一致";return NO;
        }
        existing->actionID.store(action.actionID,std::memory_order_release);
        existing->callbackValue.store(action.callbackValue?1u:0u,std::memory_order_release);
        existing->enabled.store(value!=0?1u:0u,std::memory_order_release);
        if(!ZNNativeHookRegistryBind(action.actionID,ZNNativeHookSlotKindManagedCallback,target,
                                     existing->original.load(std::memory_order_acquire),existing)){
            if(error)*error=@"Permanent Hook registry 已满";return NO;
        }
        return YES;
    }

    ZNManagedCallbackSlot *slot=ZNManagedCallbackFreeSlot();
    if(!slot){if(error)*error=@"ManagedCallback Hook slot 已满";return NO;}
    NSUInteger slotIndex=(NSUInteger)(slot-gZNManagedCallbackSlots);
    slot->callbackRegister.store(reg,std::memory_order_relaxed);
    slot->callbackValue.store(action.callbackValue?1u:0u,std::memory_order_relaxed);
    slot->enabled.store(value!=0?1u:0u,std::memory_order_relaxed);
    slot->hits.store(0,std::memory_order_relaxed);
    slot->callbackSuccess.store(0,std::memory_order_relaxed);
    slot->callbackFailure.store(0,std::memory_order_relaxed);
    slot->lastReceiver.store(0,std::memory_order_relaxed);
    slot->lastCallback.store(0,std::memory_order_relaxed);
    slot->isStatic.store(action.preparedIsStatic?1u:0u,std::memory_order_relaxed);
    slot->actionID.store(action.actionID,std::memory_order_relaxed);
    slot->original.store(0,std::memory_order_relaxed);
    slot->target.store(target,std::memory_order_release);

    uintptr_t original=0;NSString *hookError=nil;
    if(slotIndex>=kZNManagedCallbackMaxSlots||
       !ZNNativeStaticPrepatchBind(action,target,gZNManagedCallbackReplacements[slotIndex],&original,&hookError)){
        slot->target.store(0,std::memory_order_release);
        slot->actionID.store(0,std::memory_order_relaxed);
        if(error)*error=hookError?:@"Prepared ManagedCallback static bind 失败";
        return NO;
    }
    slot->original.store(original,std::memory_order_release);
    if(!ZNNativeHookRegistryBind(action.actionID,ZNNativeHookSlotKindManagedCallback,target,
                                 original,slot)){
        if(error)*error=@"Permanent Hook registry 已满";return NO;
    }
    return YES;
}

- (BOOL)zn_installPreparedStructFieldAction:(ZNNativeHookAction *)action
                                        base:(uintptr_t)base
                                      target:(uintptr_t)target
                                       value:(NSInteger)value
                                       error:(NSString **)error {
    BOOL whole=action.templateKind==ZNNativeHookTemplateComplexStructTransform;
    uintptr_t fn0=0,fn1=0,fn2=0,fn3=0;
    uintptr_t mi0=0,mi1=0,mi2=0,mi3=0;
    uint32_t codecVariant=0;
    uintptr_t transform=0;

    if(whole){
        NSDictionary *codec=[[ZNComplexStructCodecResolver sharedResolver] resolveManagedType:action.codecClassName error:error];
        if(!codec)return NO;
        if(![codec[@"codecKey"] isEqualToString:action.fieldCodec]){
            if(error)*error=[NSString stringWithFormat:@"Prepared Complex Struct Codec 类型不匹配：%@ / %@",
                             action.codecClassName?:@"?",action.fieldCodec?:@"?"];
            return NO;
        }
        fn0=[codec[@"function0"] unsignedLongLongValue];
        fn1=[codec[@"function1"] unsignedLongLongValue];
        fn2=[codec[@"function2"] unsignedLongLongValue];
        fn3=[codec[@"function3"] unsignedLongLongValue];
        mi0=[codec[@"methodInfo0"] unsignedLongLongValue];
        mi1=[codec[@"methodInfo1"] unsignedLongLongValue];
        mi2=[codec[@"methodInfo2"] unsignedLongLongValue];
        mi3=[codec[@"methodInfo3"] unsignedLongLongValue];
        codecVariant=[codec[@"variant"] unsignedIntValue];
        NSValue *tv=[[ZNComplexStructCodecRegistry sharedRegistry] transformValueForCodecKey:action.fieldCodec];
        transform=(uintptr_t)tv.pointerValue;
        if(!transform){if(error)*error=@"Prepared Complex Struct codec 未注册";return NO;}
    }else{
        if(!action.preparedCodecGetterRVA||!action.preparedCodecSetterRVA){
            if(error)*error=@"StructField Prepared Descriptor 缺少 codec RVA";
            return NO;
        }
        if(action.preparedCodecGetterRVA>UINTPTR_MAX-base||
           action.preparedCodecSetterRVA>UINTPTR_MAX-base){
            if(error)*error=@"StructField codec RVA 地址溢出";
            return NO;
        }
        fn0=base+(uintptr_t)action.preparedCodecGetterRVA;
        fn1=base+(uintptr_t)action.preparedCodecSetterRVA;
    }

    uint32_t reg=0;
    if(!ZNNativeHookArgRegisterIndex(action.preparedIsStatic,
                                     action.fieldArgumentIndex,
                                     action.argumentCount,&reg)){
        if(error)*error=@"Prepared StructField 参数无法映射到 ARM64 x0~x7";
        return NO;
    }
    if(ZNNativeSlotForTarget(target)||ZNManagedCallbackSlotForTarget(target)||ZNReturnBoolSlotForTarget(target)){
        if(error)*error=@"同一 target 已安装其他 Native Hook";
        return NO;
    }

    ZNStructFieldSlot *existing=ZNStructFieldSlotForTarget(target);
    if(existing){
        uint32_t owner=existing->actionID.load(std::memory_order_acquire);
        if(owner&&owner!=action.actionID){if(error)*error=@"target 已由其他 StructField Action 占用";return NO;}
        if(existing->argumentRegister.load(std::memory_order_relaxed)!=reg||
           existing->fieldOffset.load(std::memory_order_relaxed)!=action.fieldOffset){
            if(error)*error=@"Prepared StructField 配置与已安装 Hook 不一致";return NO;
        }
        existing->getter.store(fn0,std::memory_order_release);
        existing->setter.store(fn1,std::memory_order_release);
        existing->function2.store(fn2,std::memory_order_release);
        existing->function3.store(fn3,std::memory_order_release);
        existing->methodInfo0.store(mi0,std::memory_order_release);
        existing->methodInfo1.store(mi1,std::memory_order_release);
        existing->methodInfo2.store(mi2,std::memory_order_release);
        existing->methodInfo3.store(mi3,std::memory_order_release);
        existing->codecVariant.store(codecVariant,std::memory_order_release);
        existing->codecTransform.store(transform,std::memory_order_release);
        existing->multiplier.store((int32_t)value,std::memory_order_release);
        existing->enabled.store(value!=1?1u:0u,std::memory_order_release);
        existing->actionID.store(action.actionID,std::memory_order_release);
        if(!ZNNativeHookRegistryBind(action.actionID,ZNNativeHookSlotKindStructField,target,
                                     existing->original.load(std::memory_order_acquire),existing)){
            if(error)*error=@"Permanent Hook registry 已满";return NO;
        }
        return YES;
    }

    ZNStructFieldSlot *slot=ZNStructFieldFreeSlot();
    if(!slot){if(error)*error=@"StructFieldTransform Hook slot 已满";return NO;}
    NSUInteger slotIndex=(NSUInteger)(slot-gZNStructFieldSlots);
    slot->getter.store(fn0,std::memory_order_relaxed);
    slot->setter.store(fn1,std::memory_order_relaxed);
    slot->function2.store(fn2,std::memory_order_relaxed);
    slot->function3.store(fn3,std::memory_order_relaxed);
    slot->methodInfo0.store(mi0,std::memory_order_relaxed);
    slot->methodInfo1.store(mi1,std::memory_order_relaxed);
    slot->methodInfo2.store(mi2,std::memory_order_relaxed);
    slot->methodInfo3.store(mi3,std::memory_order_relaxed);
    slot->codecVariant.store(codecVariant,std::memory_order_relaxed);
    slot->multiplier.store((int32_t)value,std::memory_order_relaxed);
    slot->enabled.store(value!=1?1u:0u,std::memory_order_relaxed);
    slot->hits.store(0,std::memory_order_relaxed);
    slot->failures.store(0,std::memory_order_relaxed);
    slot->lastBefore.store(0,std::memory_order_relaxed);
    slot->lastAfter.store(0,std::memory_order_relaxed);
    slot->lastBase.store(0,std::memory_order_relaxed);
    slot->lastField.store(0,std::memory_order_relaxed);
    slot->argumentRegister.store(reg,std::memory_order_relaxed);
    slot->fieldOffset.store(action.fieldOffset,std::memory_order_relaxed);
    slot->codecTransform.store(transform,std::memory_order_relaxed);
    slot->actionID.store(action.actionID,std::memory_order_relaxed);
    slot->original.store(0,std::memory_order_relaxed);
    slot->target.store(target,std::memory_order_release);

    uintptr_t original=0;NSString *hookError=nil;
    if(slotIndex>=kZNStructFieldMaxSlots||
       !ZNNativeStaticPrepatchBind(action,target,gZNStructFieldBridgeReplacements[slotIndex],&original,&hookError)){
        slot->target.store(0,std::memory_order_release);
        slot->actionID.store(0,std::memory_order_relaxed);
        if(error)*error=hookError?:@"Prepared StructField static bind 失败";
        return NO;
    }
    slot->original.store(original,std::memory_order_release);
    if(!ZNNativeHookRegistryBind(action.actionID,ZNNativeHookSlotKindStructField,target,
                                 original,slot)){
        if(error)*error=@"Permanent Hook registry 已满";return NO;
    }
    return YES;
}

- (BOOL)installAction:(ZNNativeHookAction *)action value:(NSInteger)value error:(NSString **)error {
    if(!action){if(error)*error=@"Native Hook Action 为空";return NO;}
    value=MIN(MAX(value,action.minValue),action.maxValue);

    uintptr_t base=0,target=0;
    if(!ZNNativePreparedTargetForAction(action,&base,&target,error))return NO;

    if(action.templateKind==ZNNativeHookTemplateReturnBoolOverride)
        return [self zn_installPreparedReturnBoolAction:action target:target value:value error:error];

    if(action.templateKind==ZNNativeHookTemplateManagedCallbackShortCircuit)
        return [self zn_installPreparedManagedCallbackAction:action target:target value:value error:error];

    if(action.templateKind==ZNNativeHookTemplateStructFieldTransform ||
       action.templateKind==ZNNativeHookTemplateComplexStructTransform)
        return [self zn_installPreparedStructFieldAction:action base:base target:target value:value error:error];

    if(action.templateKind==ZNNativeHookTemplateArgScaleInt32)
        return [self zn_installPreparedArgScaleAction:action target:target value:value error:error];

    if(error)*error=@"Native Hook Action 模板不受支持";
    return NO;
}

// Permanent lifecycle: normal feature changes mutate local slot state only.
// If the scheduler has not bound the action yet, installAction performs the
// one-time M6.10 writable-slot bind. It never patches executable memory.
- (BOOL)setValue:(NSInteger)value forAction:(ZNNativeHookAction *)action error:(NSString **)error {
    if(!action){if(error)*error=@"Native Hook Action 为空";return NO;}
    value=MIN(MAX(value,action.minValue),action.maxValue);

    ZNNativeHookRegistryEntry *entry=ZNNativeHookRegistryFind(action.actionID);
    if(!entry)return [self installAction:action value:value error:error];

    void *raw=(void *)entry->slot.load(std::memory_order_acquire);
    ZNNativeHookSlotKind kind=(ZNNativeHookSlotKind)entry->kind.load(std::memory_order_relaxed);
    if(!raw){if(error)*error=@"Permanent Hook registry slot 为空";return NO;}

    switch(kind){
        case ZNNativeHookSlotKindReturnBool: {
            ZNReturnBoolSlot *slot=(ZNReturnBoolSlot *)raw;
            slot->forcedValue.store(action.returnBoolValue?1u:0u,std::memory_order_release);
            slot->enabled.store(value!=0?1u:0u,std::memory_order_release);
            return YES;
        }
        case ZNNativeHookSlotKindManagedCallback: {
            if(value!=0 && !ZNManagedPrepareInvokeBridge(error))return NO;
            ZNManagedCallbackSlot *slot=(ZNManagedCallbackSlot *)raw;
            slot->callbackValue.store(action.callbackValue?1u:0u,std::memory_order_release);
            slot->enabled.store(value!=0?1u:0u,std::memory_order_release);
            return YES;
        }
        case ZNNativeHookSlotKindStructField: {
            ZNStructFieldSlot *slot=(ZNStructFieldSlot *)raw;
            slot->multiplier.store((int32_t)value,std::memory_order_release);
            slot->enabled.store(value!=1?1u:0u,std::memory_order_release);
            return YES;
        }
        case ZNNativeHookSlotKindArgScale: {
            ZNNativeSlot *slot=(ZNNativeSlot *)raw;
            slot->multiplier.store((int32_t)value,std::memory_order_release);
            slot->enabled.store(value!=1?1u:0u,std::memory_order_release);
            return YES;
        }
        default:
            if(error)*error=@"Permanent Hook registry kind 无效";
            return NO;
    }
}

- (BOOL)removeAction:(ZNNativeHookAction *)action error:(NSString **)error {
    if(!action||!action.actionID)return YES;
    ZNNativeHookRegistryEntry *entry=ZNNativeHookRegistryFind(action.actionID);
    if(!entry)return YES;

    uintptr_t target=entry->target.load(std::memory_order_acquire);
    void *raw=(void *)entry->slot.load(std::memory_order_acquire);
    ZNNativeHookSlotKind kind=(ZNNativeHookSlotKind)entry->kind.load(std::memory_order_relaxed);
    if(!target||!raw){
        ZNNativeHookRegistryUnbind(action.actionID);
        return YES;
    }

    if(action.staticPrepatch){
        if(!ZNNativeStaticPrepatchClear(action,target,error))return NO;
    }else{
        // Legacy/temporary runtime hooks still use Dobby teardown. Newly
        // generated M6.10 formal hooks never enter this branch.
        if(![[ZNNativeHookBackend sharedBackend] destroyHookAtAddress:target error:error])return NO;
    }

    switch(kind){
        case ZNNativeHookSlotKindArgScale: {
            ZNNativeSlot *slot=(ZNNativeSlot *)raw;
            slot->enabled.store(0,std::memory_order_relaxed);
            slot->original.store(0,std::memory_order_relaxed);
            slot->actionID.store(0,std::memory_order_relaxed);
            slot->target.store(0,std::memory_order_release);
            break;
        }
        case ZNNativeHookSlotKindManagedCallback: {
            ZNManagedCallbackSlot *slot=(ZNManagedCallbackSlot *)raw;
            slot->enabled.store(0,std::memory_order_relaxed);
            slot->original.store(0,std::memory_order_relaxed);
            slot->actionID.store(0,std::memory_order_relaxed);
            slot->target.store(0,std::memory_order_release);
            break;
        }
        case ZNNativeHookSlotKindReturnBool: {
            ZNReturnBoolSlot *slot=(ZNReturnBoolSlot *)raw;
            slot->enabled.store(0,std::memory_order_relaxed);
            slot->original.store(0,std::memory_order_relaxed);
            slot->actionID.store(0,std::memory_order_relaxed);
            slot->target.store(0,std::memory_order_release);
            break;
        }
        case ZNNativeHookSlotKindStructField: {
            ZNStructFieldSlot *slot=(ZNStructFieldSlot *)raw;
            slot->enabled.store(0,std::memory_order_relaxed);
            slot->original.store(0,std::memory_order_relaxed);
            slot->codecTransform.store(0,std::memory_order_relaxed);
            slot->actionID.store(0,std::memory_order_relaxed);
            slot->target.store(0,std::memory_order_release);
            break;
        }
        default:
            break;
    }

    uintptr_t original=entry->original.load(std::memory_order_relaxed);
    ZNNativeHookRegistryUnbind(action.actionID);
    [[ZNRuntimeLogger sharedLogger] log:
     [NSString stringWithFormat:@"[native-hook-registry] teardown action=%u target=0x%llX original=0x%llX kind=%u",
      action.actionID,(unsigned long long)target,(unsigned long long)original,(unsigned)kind]];
    return YES;
}

@end
