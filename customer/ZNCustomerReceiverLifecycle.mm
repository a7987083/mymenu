#import <Foundation/Foundation.h>
#import "ZNCustomerReceiverLifecycle.h"
#import "../iosruntimepatchmenu/src/ZNIL2CPPResolver.h"
#import "../iosruntimepatchmenu/src/ZNIL2CPPRuntimeCommon.h"
#import <objc/runtime.h>
#import "../iosruntimepatchmenu/src/ZNIL2CPPInstanceResolver.h"
#import "../iosruntimepatchmenu/src/ZNIL2CPPInstanceSelectionV2.h"

// Customer-only receiver lifecycle. Do not link or initialize the Developer UI.
typedef uintptr_t ZNCustomerHandle;
typedef ZNCustomerHandle (*ZNCustomerHandleNew)(void *, bool);
typedef void *(*ZNCustomerHandleGet)(ZNCustomerHandle);
typedef void (*ZNCustomerHandleFree)(ZNCustomerHandle);

static NSString *const ZNCustomerCaptureKey=@"mymenu.customer.receiver.capture";
static NSString *const ZNCustomerRequestKey=@"mymenu.customer.receiver.request";

static NSMutableSet<NSString *> *ZNCustomerManualKeys(void) {
    static NSMutableSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keys=[NSMutableSet set]; });
    return keys;
}

@interface ZNCustomerReceiverChoice ()
@property(nonatomic,readwrite,copy) NSString *displayTitle;
@property(nonatomic,assign) ZNCustomerHandle handle;
@property(nonatomic,assign) ZNCustomerHandleGet getTarget;
@property(nonatomic,assign) ZNCustomerHandleFree freeHandle;
@end
@implementation ZNCustomerReceiverChoice
- (void)dealloc {
    if(_handle && _freeHandle) _freeHandle(_handle);
}
@end

@interface ZNCustomerReceiverRequest ()
@property(nonatomic,readwrite,copy) NSString *assembly;
@property(nonatomic,readwrite,copy) NSString *namespaceName;
@property(nonatomic,readwrite,copy) NSString *className;
@property(nonatomic,readwrite,copy) NSArray<ZNCustomerReceiverChoice *> *choices;
@end

@implementation ZNCustomerReceiverRequest
- (BOOL)prepareChoices:(NSString **)error {
    if(!NSThread.isMainThread) {
        if(error)*error=@"实例选择必须在主线程进行";
        return NO;
    }
    self.choices=@[];
    ZNIL2CPPResolver *metadata=[ZNIL2CPPResolver sharedResolver];
    [metadata refresh];
    NSString *path=metadata.unityPath?:@"";
    ZNCustomerHandleNew create=(ZNCustomerHandleNew)ZNIL2CPPResolveSymbol(path,"il2cpp_gchandle_new");
    ZNCustomerHandleGet get=(ZNCustomerHandleGet)ZNIL2CPPResolveSymbol(path,"il2cpp_gchandle_get_target");
    ZNCustomerHandleFree release=(ZNCustomerHandleFree)ZNIL2CPPResolveSymbol(path,"il2cpp_gchandle_free");
    if(!create||!get||!release) {
        if(error)*error=@"当前游戏缺少 GCHandle API，无法安全保留候选实例";
        return NO;
    }
    ZNIL2CPPInstanceResolver *resolver=[ZNIL2CPPInstanceResolver sharedResolver];
    NSString *scanError=nil;
    NSArray<NSNumber *> *addresses=[resolver candidateAddressesForAssembly:self.assembly
        namespace:self.namespaceName className:self.className limit:128 diagnostics:nil error:&scanError];
    if(!addresses.count||addresses.count>=128) {
        if(error)*error=scanError?:@"候选实例为空或达到枚举上限，请重新执行";
        return NO;
    }
    NSMutableArray<ZNCustomerReceiverChoice *> *choices=[NSMutableArray array];
    for(NSNumber *address in addresses) {
        uintptr_t raw=(uintptr_t)address.unsignedLongLongValue;
        if(!raw||![resolver znm44_validateInstanceAddress:raw assembly:self.assembly
            namespace:self.namespaceName className:self.className error:nil])continue;
        ZNCustomerHandle handle=create((void *)raw,false);
        if(!handle)continue;
        ZNCustomerReceiverChoice *choice=[ZNCustomerReceiverChoice new];
        choice.handle=handle;choice.getTarget=get;choice.freeHandle=release;
        void *target=get(handle);
        if(!target||![resolver znm44_validateInstanceAddress:(uintptr_t)target assembly:self.assembly
            namespace:self.namespaceName className:self.className error:nil])continue;
        choice.displayTitle=[NSString stringWithFormat:@"实例 %lu · 0x%llX",
            (unsigned long)choices.count+1,(unsigned long long)(uintptr_t)target];
        [choices addObject:choice];
    }
    self.choices=[choices copy];
    if(self.choices.count!=addresses.count) {
        self.choices=@[];
        if(error)*error=@"部分候选实例失效或无法创建句柄，请重新执行";
        return NO;
    }
    if(error)*error=nil;
    return YES;
}

- (BOOL)selectChoice:(ZNCustomerReceiverChoice *)choice error:(NSString **)error {
    if(!NSThread.isMainThread||![self.choices containsObject:choice]||!choice.getTarget) {
        if(error)*error=@"无效的实例选择请求";
        return NO;
    }
    ZNIL2CPPInstanceResolver *resolver=[ZNIL2CPPInstanceResolver sharedResolver];
    NSString *scanError=nil;
    NSArray<NSNumber *> *live=[resolver candidateAddressesForAssembly:self.assembly
        namespace:self.namespaceName className:self.className limit:128 diagnostics:nil error:&scanError];
    uintptr_t target=(uintptr_t)choice.getTarget(choice.handle);
    if(!target||live.count>=128||![live containsObject:@(target)]) {
        if(error)*error=scanError?:@"选择的实例已不在当前候选集合，请重新执行";
        return NO;
    }
    if(![resolver znm44_selectInstanceAddress:target assembly:self.assembly
        namespace:self.namespaceName className:self.className error:error])return NO;
    NSString *key=ZNIL2CPPConservativeInstanceKey(self.assembly,self.namespaceName,self.className);
    @synchronized(ZNCustomerManualKeys()){[ZNCustomerManualKeys() addObject:key];}
    // The existing M4.6.2 store now owns its own handle. Temporary handles are
    // released when the alert/request is released, not kept across sessions.
    if(error)*error=nil;
    return YES;
}
@end

void ZNCustomerBeginReceiverSelectionCapture(void) {
    NSMutableDictionary *dict=NSThread.currentThread.threadDictionary;
    [dict removeObjectForKey:ZNCustomerRequestKey];
    dict[ZNCustomerCaptureKey]=@YES;
}
ZNCustomerReceiverRequest *ZNCustomerEndReceiverSelectionCapture(void) {
    NSMutableDictionary *dict=NSThread.currentThread.threadDictionary;
    ZNCustomerReceiverRequest *request=dict[ZNCustomerRequestKey];
    [dict removeObjectForKey:ZNCustomerRequestKey];
    [dict removeObjectForKey:ZNCustomerCaptureKey];
    return request;
}

extern "C" void ZNInstallM462InstanceSafetyDeferred(void);

@interface ZNIL2CPPInstanceResolver (ZNCustomerReceiverLifecycle)
- (uintptr_t)zncustomer_selectedInstanceForAssembly:(NSString *)assembly namespace:(NSString *)namespaceName className:(NSString *)className;
- (void *)zncustomer_resolveInstanceForAssembly:(NSString *)assembly
                                      namespace:(NSString *)namespaceName
                                      className:(NSString *)className
                                    diagnostics:(NSString **)diagnostics
                                          error:(NSString **)error;
@end

@implementation ZNIL2CPPInstanceResolver (ZNCustomerReceiverLifecycle)
- (uintptr_t)zncustomer_selectedInstanceForAssembly:(NSString *)assembly
    namespace:(NSString *)namespaceName className:(NSString *)className {
    uintptr_t target=[self zncustomer_selectedInstanceForAssembly:assembly namespace:namespaceName className:className];
    NSString *key=ZNIL2CPPConservativeInstanceKey(assembly,namespaceName,className);
    BOOL manual=NO;
    @synchronized(ZNCustomerManualKeys()){manual=[ZNCustomerManualKeys() containsObject:key];}
    if(!manual)return target;
    // A strong handle protects memory, but does not prove the object is still
    // a live member of the game's current static object graph.
    NSArray<NSNumber *> *live=target?[self candidateAddressesForAssembly:assembly namespace:namespaceName
        className:className limit:128 diagnostics:nil error:nil]:@[];
    if(target && live.count<128 && [live containsObject:@(target)])return target;
    [self znm44_clearSelectedInstanceForAssembly:assembly namespace:namespaceName className:className];
    @synchronized(ZNCustomerManualKeys()){[ZNCustomerManualKeys() removeObject:key];}
    return 0;
}
- (void *)zncustomer_resolveInstanceForAssembly:(NSString *)assembly
                                      namespace:(NSString *)namespaceName
                                      className:(NSString *)className
                                    diagnostics:(NSString **)diagnostics
                                          error:(NSString **)error {
    // The V2 resolver returns a validated selected session receiver first.
    // A newly discovered unique instance must also be retained: otherwise
    // adding a second same-class object makes the next call ambiguous.
    NSString *resolveError=nil;
    void *receiver=[self zncustomer_resolveInstanceForAssembly:assembly
                                                    namespace:namespaceName
                                                    className:className
                                                  diagnostics:diagnostics
                                                        error:&resolveError];
    if(error)*error=resolveError;
    if (!receiver) {
        NSMutableDictionary *dict=NSThread.currentThread.threadDictionary;
        if(NSThread.isMainThread && [dict[ZNCustomerCaptureKey] boolValue] &&
            [resolveError hasPrefix:@"FAILED_INSTANCE_AMBIGUOUS"]) {
            ZNCustomerReceiverRequest *request=[ZNCustomerReceiverRequest new];
            request.assembly=assembly?:@"";
            request.namespaceName=namespaceName?:@"";
            request.className=className?:@"";
            request.choices=@[];
            dict[ZNCustomerRequestKey]=request;
        }
        return NULL;
    }

    uintptr_t selected=[self znm44_selectedInstanceForAssembly:assembly
                                                     namespace:namespaceName
                                                     className:className];
    if (selected) return receiver;

    NSString *selectionError=nil;
    if ([self znm44_selectInstanceAddress:(uintptr_t)receiver
                                 assembly:assembly
                                namespace:namespaceName
                                className:className
                                    error:&selectionError]) {
        // A GCHandle-backed target can differ from the original object address.
        uintptr_t target=[self znm44_selectedInstanceForAssembly:assembly
                                                       namespace:namespaceName
                                                       className:className];
        if (target) {
            if (diagnostics) *diagnostics=[NSString stringWithFormat:
                @"customer-auto-bound 0x%llX", (unsigned long long)target];
            if (error) *error=nil;
            return (void *)target;
        }
    }
    // Preserve single-instance behavior when the optional binding fails.
    // Never choose an address from an ambiguous multi-instance result.
    if (diagnostics) *diagnostics=[NSString stringWithFormat:
        @"unique-unbound (%@)",selectionError?:@"target unavailable"];
    if (error) *error=nil;
    return receiver;
}
@end

extern "C" void ZNCustomerInstallReceiverLifecycle(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        ZNInstallIL2CPPInstanceSelectionV2Deferred();
        ZNInstallM462InstanceSafetyDeferred();
        Class cls=ZNIL2CPPInstanceResolver.class;
        Method original=class_getInstanceMethod(cls,
            @selector(resolveUniqueInstanceForAssembly:namespace:className:diagnostics:error:));
        Method replacement=class_getInstanceMethod(cls,
            @selector(zncustomer_resolveInstanceForAssembly:namespace:className:diagnostics:error:));
        if(original && replacement) method_exchangeImplementations(original,replacement);
        Method selected=class_getInstanceMethod(cls,@selector(znm44_selectedInstanceForAssembly:namespace:className:));
        Method selectedReplacement=class_getInstanceMethod(cls,@selector(zncustomer_selectedInstanceForAssembly:namespace:className:));
        if(selected && selectedReplacement)method_exchangeImplementations(selected,selectedReplacement);
    });
}
