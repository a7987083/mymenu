#import "ZNPatchCore.h"
#import "ZNIL2CPPResolver.h"
#import "ZNActivationTrace.h"
#import <mach-o/dyld.h>
#include <atomic>

static NSString *ZNEnabledKey(NSString *featureID) {
    return [NSString stringWithFormat:@"ZonoePatch.Feature.%@.Enabled", featureID];
}

static NSString *ZNValueKey(NSString *featureID) {
    return [NSString stringWithFormat:@"ZonoePatch.Feature.%@.Value", featureID];
}

NSString *ZNStringForPatchState(ZNPatchState state) {
    switch (state) {
        case ZNPatchStateReady: return @"可用";
        case ZNPatchStateEnabled: return @"已启用";
        case ZNPatchStateDisabled: return @"已关闭";
        case ZNPatchStateUnsupported: return @"不支持";
        case ZNPatchStateFailed: return @"失败";
        case ZNPatchStateWaitingModule: return @"等待模块";
        case ZNPatchStateResolving: return @"解析中";
        case ZNPatchStateTargetMissing: return @"目标不存在";
        case ZNPatchStateByteMismatch: return @"字节不匹配";
        case ZNPatchStateConflict: return @"冲突";
        default: return @"未初始化";
    }
}

NSString *ZNStringForActionType(ZNPatchActionType type) {
    switch (type) {
        case ZNPatchActionTypeBytes: return @"Bytes Patch";
        case ZNPatchActionTypeValue: return @"Value Patch";
        case ZNPatchActionTypeIL2CPPMethod: return @"IL2CPP 方法";
        case ZNPatchActionTypeIL2CPPField: return @"IL2CPP 字段";
        case ZNPatchActionTypeIL2CPPInvoke: return @"IL2CPP 调用";
    }
    return @"未知";
}

NSString *ZNStringForControlType(ZNFeatureControlType type) {
    switch (type) {
        case ZNFeatureControlTypeSlider: return @"滑块";
        case ZNFeatureControlTypeButton: return @"按钮";
        default: return @"开关";
    }
}

@implementation ZNPatchActionDescriptor
- (instancetype)initWithIdentifier:(NSString *)identifier type:(ZNPatchActionType)type {
    self = [super init];
    if (!self) return nil;
    _identifier = [identifier copy];
    _type = type;
    _module = @"";
    _assemblyName = @"";
    _namespaceName = @"";
    _className = @"";
    _memberName = @"";
    _argumentCount = -1;
    _state = ZNPatchStateUninitialized;
    _resolvedAddress = 0;
    _lastError = @"";
    return self;
}
@end

@implementation ZNPatchDescriptor
- (instancetype)initWithIdentifier:(NSString *)identifier
                              name:(NSString *)name
                          category:(NSString *)category
                           backend:(NSString *)backend
                             value:(double)value {
    self = [super init];
    if (!self) return nil;
    _identifier = [identifier copy];
    _name = [name copy];
    _category = [category copy];
    _backend = [backend copy];
    _value = value;
    _enabled = NO;
    _state = ZNPatchStateReady;
    _controlType = ZNFeatureControlTypeSwitch;
    _actions = @[];
    _lastError = @"";
    return self;
}
@end

@implementation ZNRuntimeLogger {
    NSMutableArray<NSString *> *_lines;
}
+ (instancetype)sharedLogger {
    static ZNRuntimeLogger *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [ZNRuntimeLogger new]; });
    return s;
}
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _lines = [NSMutableArray array];
    return self;
}
- (void)log:(NSString *)message {
    if (!message.length) return;
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [fmt stringFromDate:[NSDate date]], message];
    @synchronized (self) {
        [_lines addObject:line];
        if (_lines.count > 200) [_lines removeObjectsInRange:NSMakeRange(0, _lines.count - 200)];
    }
    NSLog(@"[ZonoePatch] %@", message);
}
- (NSArray<NSString *> *)recentLines:(NSUInteger)limit {
    @synchronized (self) {
        if (limit == 0 || _lines.count <= limit) return [_lines copy];
        return [_lines subarrayWithRange:NSMakeRange(_lines.count-limit, limit)];
    }
}
- (void)clear {
    @synchronized (self) { [_lines removeAllObjects]; }
}
@end

// v0.5.6.2 dyld replay suppression + image-burst coalescing.
// _dyld_register_func_for_add_image synchronously replays already-loaded images
// when the callback is registered. Those images are not new work and must not
// fan out into hundreds of main-queue refreshes on first menu activation.
@interface ZNModuleManager ()
@property(nonatomic,assign,readwrite) uint64_t moduleGeneration;
@property(nonatomic,assign) NSUInteger pendingImageCount;
@property(nonatomic,assign) BOOL imageNotificationScheduled;
@property(nonatomic,assign) NSUInteger replaySuppressedCount;
@property(nonatomic,assign) NSUInteger deliveredImageNotificationCount;
@end

static __unsafe_unretained ZNModuleManager *gZNModuleManager = nil;
static std::atomic<bool> gZNModuleRegistrationReplay{false};

static void ZNModuleAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh;
    (void)slide;
    ZNModuleManager *manager = gZNModuleManager;
    if (!manager) return;

    if (gZNModuleRegistrationReplay.load(std::memory_order_acquire)) {
        @synchronized (manager) {
            manager.replaySuppressedCount += 1;
        }
        return;
    }

    __block BOOL shouldSchedule = NO;
    @synchronized (manager) {
        manager.moduleGeneration += 1;
        manager.pendingImageCount += 1;
        if (!manager.imageNotificationScheduled) {
            manager.imageNotificationScheduled = YES;
            shouldSchedule = YES;
        }
    }
    if (!shouldSchedule) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger burst = 0;
        NSUInteger delivered = 0;
        @synchronized (manager) {
            burst = manager.pendingImageCount;
            manager.pendingImageCount = 0;
            manager.imageNotificationScheduled = NO;
            manager.deliveredImageNotificationCount += 1;
            delivered = manager.deliveredImageNotificationCount;
        }

        ZNActivationTraceLog([NSString stringWithFormat:@"[module-manager] image burst coalesced=%lu · notification=%lu",
                              (unsigned long)burst,
                              (unsigned long)delivered]);
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZNModuleManagerImageAdded"
                                                            object:manager
                                                          userInfo:@{@"burstCount": @(burst)}];
    });
}

@implementation ZNModuleManager
+ (instancetype)sharedManager {
    static ZNModuleManager *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [ZNModuleManager new]; });
    return s;
}
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _moduleGeneration = 1;
    _pendingImageCount = 0;
    _imageNotificationScheduled = NO;
    _replaySuppressedCount = 0;
    _deliveredImageNotificationCount = 0;
    gZNModuleManager = self;

    uint32_t imagesBeforeRegistration = _dyld_image_count();
    gZNModuleRegistrationReplay.store(true, std::memory_order_release);
    _dyld_register_func_for_add_image(ZNModuleAdded);
    gZNModuleRegistrationReplay.store(false, std::memory_order_release);

    ZNActivationTraceLog([NSString stringWithFormat:@"[module-manager] dyld callback registered · existing=%u · replay suppressed=%lu",
                          imagesBeforeRegistration,
                          (unsigned long)_replaySuppressedCount]);
    return self;
}
- (NSArray<NSDictionary<NSString *,id> *> *)loadedImages {
    NSMutableArray *items = [NSMutableArray array];
    uint32_t count = _dyld_image_count();
    for (uint32_t i=0; i<count; i++) {
        const char *cname = _dyld_get_image_name(i);
        NSString *path = cname ? [NSString stringWithUTF8String:cname] : @"";
        uintptr_t base = (uintptr_t)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        [items addObject:@{
            @"index": @(i),
            @"name": path.lastPathComponent ?: @"",
            @"path": path ?: @"",
            @"base": @(base),
            @"slide": @((long long)slide),
        }];
    }
    return items;
}
- (NSDictionary<NSString *,id> *)mainExecutable {
    return self.loadedImages.firstObject;
}
- (NSDictionary<NSString *,id> *)unityFramework {
    return [self moduleNamed:@"UnityFramework"];
}
- (NSDictionary<NSString *,id> *)moduleNamed:(NSString *)moduleName {
    if (!moduleName.length) return nil;
    if ([moduleName caseInsensitiveCompare:@"main"] == NSOrderedSame ||
        [moduleName caseInsensitiveCompare:@"main executable"] == NSOrderedSame) {
        return self.mainExecutable;
    }
    NSString *wanted = moduleName.lastPathComponent;
    for (NSDictionary *item in self.loadedImages) {
        NSString *name = item[@"name"] ?: @"";
        NSString *path = item[@"path"] ?: @"";
        if ([name caseInsensitiveCompare:wanted] == NSOrderedSame) return item;
        NSString *frameworkExec = [NSString stringWithFormat:@"%@.framework/%@", wanted, wanted];
        if ([path hasSuffix:frameworkExec]) return item;
    }
    return nil;
}
- (uintptr_t)runtimeAddressForModule:(NSString *)moduleName rva:(uint64_t)rva {
    NSDictionary *module = [self moduleNamed:moduleName];
    if (!module) return 0;
    uintptr_t base = (uintptr_t)[module[@"base"] unsignedLongLongValue];
    if (!base) return 0;
    return base + (uintptr_t)rva;
}
- (NSString *)diagnosticReport {
    NSDictionary *main = self.mainExecutable;
    NSDictionary *unity = self.unityFramework;
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"已加载镜像: %lu\n", (unsigned long)self.loadedImages.count];
    if (main) [s appendFormat:@"主程序: %@ base=0x%llx slide=0x%llx\n", main[@"name"], [main[@"base"] unsignedLongLongValue], [main[@"slide"] unsignedLongLongValue]];
    if (unity) [s appendFormat:@"UnityFramework: 已加载 base=0x%llx slide=0x%llx\n", [unity[@"base"] unsignedLongLongValue], [unity[@"slide"] unsignedLongLongValue]];
    else [s appendString:@"UnityFramework: 未加载\n"];
    [s appendFormat:@"模块代数: %llu\n", self.moduleGeneration];
    [s appendFormat:@"dyld replay suppressed: %lu\n", (unsigned long)self.replaySuppressedCount];
    [s appendFormat:@"image notifications delivered: %lu\n", (unsigned long)self.deliveredImageNotificationCount];
    return s;
}
@end

@implementation ZNPatchManager {
    NSMutableDictionary<NSString *, ZNPatchDescriptor *> *_descriptors;
}
+ (instancetype)sharedManager {
    static ZNPatchManager *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [ZNPatchManager new]; });
    return s;
}
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _descriptors = [NSMutableDictionary dictionary];
    [self registerDescriptor:@"ui_test" name:@"UI 测试开关" category:@"首页" value:0 control:ZNFeatureControlTypeSwitch];
    [self registerDescriptor:@"invincible" name:@"无敌" category:@"玩家" value:0 control:ZNFeatureControlTypeSwitch];
    [self registerDescriptor:@"speed" name:@"移速修改" category:@"移动" value:2.5 control:ZNFeatureControlTypeSlider];
    [self registerDescriptor:@"damage" name:@"伤害倍率" category:@"战斗" value:5.0 control:ZNFeatureControlTypeSlider];
    [self registerDescriptor:@"jump" name:@"跳跃高度" category:@"移动" value:1.5 control:ZNFeatureControlTypeSlider];
    [self registerDescriptor:@"attack_speed" name:@"攻速修改" category:@"战斗" value:1.8 control:ZNFeatureControlTypeSlider];
    [self registerDescriptor:@"other_test" name:@"测试功能" category:@"其他" value:0 control:ZNFeatureControlTypeButton];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(moduleAdded:) name:@"ZNModuleManagerImageAdded" object:nil];
    [ZNModuleManager sharedManager];
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"Patch Core 0.4.0 Foundation 已初始化：%lu 个 Feature", (unsigned long)_descriptors.count]];
    return self;
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}
- (void)registerDescriptor:(NSString *)identifier name:(NSString *)name category:(NSString *)category value:(double)defaultValue control:(ZNFeatureControlType)control {
    ZNPatchDescriptor *d = [[ZNPatchDescriptor alloc] initWithIdentifier:identifier name:name category:category backend:@"Foundation" value:defaultValue];
    d.controlType = control;
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    id ev = [ud objectForKey:ZNEnabledKey(identifier)];
    id vv = [ud objectForKey:ZNValueKey(identifier)];
    d.enabled = ev ? [ud boolForKey:ZNEnabledKey(identifier)] : NO;
    d.value = vv ? [ud doubleForKey:ZNValueKey(identifier)] : defaultValue;
    d.state = d.enabled ? ZNPatchStateEnabled : ZNPatchStateDisabled;
    _descriptors[identifier] = d;
}
- (void)moduleAdded:(NSNotification *)note {
    (void)note;
    [self refreshResolution];
}
- (BOOL)enabledForFeature:(NSString *)identifier {
    ZNPatchDescriptor *d = _descriptors[identifier];
    return d ? d.enabled : [NSUserDefaults.standardUserDefaults boolForKey:ZNEnabledKey(identifier)];
}
- (void)setFeature:(NSString *)identifier enabled:(BOOL)enabled {
    if (!identifier.length) return;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:ZNEnabledKey(identifier)];
    ZNPatchDescriptor *d = _descriptors[identifier];
    if (d) {
        d.enabled = enabled;
        d.state = enabled ? ZNPatchStateEnabled : ZNPatchStateDisabled;
        d.lastError = @"v0.4.0 Foundation 仅保存 Feature 状态，尚未执行真实 Patch";
    }
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"%@ -> %@（Foundation，仅状态）", identifier, enabled?@"开启":@"关闭"]];
}
- (double)valueForFeature:(NSString *)identifier fallback:(double)fallback {
    ZNPatchDescriptor *d = _descriptors[identifier];
    if (d) return d.value;
    id obj = [NSUserDefaults.standardUserDefaults objectForKey:ZNValueKey(identifier)];
    return obj ? [NSUserDefaults.standardUserDefaults doubleForKey:ZNValueKey(identifier)] : fallback;
}
- (void)setFeature:(NSString *)identifier value:(double)value {
    if (!identifier.length) return;
    [NSUserDefaults.standardUserDefaults setDouble:value forKey:ZNValueKey(identifier)];
    ZNPatchDescriptor *d = _descriptors[identifier];
    if (d) {
        d.value = value;
        d.lastError = @"v0.4.0 Foundation 仅保存滑块值，尚未执行真实 Patch";
    }
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"%@ value -> %.3f（Foundation，仅状态）", identifier, value]];
}
- (ZNPatchDescriptor *)descriptorForIdentifier:(NSString *)identifier { return _descriptors[identifier]; }
- (NSArray<ZNPatchDescriptor *> *)allDescriptors {
    return [[_descriptors allValues] sortedArrayUsingComparator:^NSComparisonResult(ZNPatchDescriptor *a, ZNPatchDescriptor *b) {
        return [a.identifier compare:b.identifier];
    }];
}
- (NSUInteger)actionCount {
    NSUInteger total = 0;
    for (ZNPatchDescriptor *d in _descriptors.allValues) total += d.actions.count;
    return total;
}
- (void)resolveAction:(ZNPatchActionDescriptor *)action {
    action.state = ZNPatchStateResolving;
    action.resolvedAddress = 0;
    action.lastError = @"";

    if (action.type == ZNPatchActionTypeBytes || action.type == ZNPatchActionTypeValue) {
        uintptr_t addr = [[ZNModuleManager sharedManager] runtimeAddressForModule:action.module rva:action.rva];
        if (!addr) {
            action.state = ZNPatchStateWaitingModule;
            action.lastError = [NSString stringWithFormat:@"等待模块：%@", action.module.length ? action.module : @"未指定"];
            return;
        }
        action.resolvedAddress = addr;
        action.state = ZNPatchStateReady;
        return;
    }

    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    if (!resolver.isAvailable) {
        action.state = resolver.unityPath.length ? ZNPatchStateUnsupported : ZNPatchStateWaitingModule;
        action.lastError = resolver.lastError ?: @"IL2CPP Resolver 不可用";
        return;
    }

    if (action.type == ZNPatchActionTypeIL2CPPField) {
        NSDictionary *r = [resolver resolveFieldAssembly:action.assemblyName namespace:action.namespaceName className:action.className field:action.memberName];
        if (!r) {
            action.state = ZNPatchStateTargetMissing;
            action.lastError = resolver.lastError ?: @"字段解析失败";
            return;
        }
        action.resolvedAddress = (uintptr_t)[r[@"offset"] unsignedLongLongValue];
        action.state = ZNPatchStateReady;
        return;
    }

    NSDictionary *r = [resolver resolveMethodAssembly:action.assemblyName namespace:action.namespaceName className:action.className method:action.memberName argumentCount:action.argumentCount];
    if (!r) {
        action.state = ZNPatchStateTargetMissing;
        action.lastError = resolver.lastError ?: @"方法解析失败";
        return;
    }
    uintptr_t methodPointer = (uintptr_t)[r[@"methodPointer"] unsignedLongLongValue];
    uintptr_t methodInfo = (uintptr_t)[r[@"methodInfo"] unsignedLongLongValue];
    action.resolvedAddress = methodPointer ? methodPointer : methodInfo;
    action.state = ZNPatchStateReady;
}
- (void)refreshResolution {
    [[ZNIL2CPPResolver sharedResolver] refresh];
    for (ZNPatchDescriptor *d in _descriptors.allValues) {
        for (ZNPatchActionDescriptor *a in d.actions) [self resolveAction:a];
    }
    [[ZNRuntimeLogger sharedLogger] log:@"Feature/Action 目标解析已刷新"];
}
- (NSDictionary<NSString *,NSNumber *> *)stateCounts {
    NSInteger ready=0, enabled=0, disabled=0, unsupported=0, failed=0, waiting=0, resolving=0, missing=0, mismatch=0, conflict=0;
    for (ZNPatchDescriptor *d in _descriptors.allValues) {
        switch (d.state) {
            case ZNPatchStateReady: ready++; break;
            case ZNPatchStateEnabled: enabled++; break;
            case ZNPatchStateDisabled: disabled++; break;
            case ZNPatchStateUnsupported: unsupported++; break;
            case ZNPatchStateFailed: failed++; break;
            case ZNPatchStateWaitingModule: waiting++; break;
            case ZNPatchStateResolving: resolving++; break;
            case ZNPatchStateTargetMissing: missing++; break;
            case ZNPatchStateByteMismatch: mismatch++; break;
            case ZNPatchStateConflict: conflict++; break;
            default: break;
        }
    }
    return @{@"registered":@(_descriptors.count),@"ready":@(ready),@"enabled":@(enabled),@"disabled":@(disabled),@"unsupported":@(unsupported),@"failed":@(failed),@"waiting":@(waiting),@"resolving":@(resolving),@"missing":@(missing),@"mismatch":@(mismatch),@"conflict":@(conflict)};
}
- (BOOL)runSelfTest {
    NSString *key = @"ZonoePatch.SelfTest.Value";
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    id old = [ud objectForKey:key];
    [ud setObject:@"ok" forKey:key];
    BOOL defaultsOK = [[ud stringForKey:key] isEqualToString:@"ok"];
    if (old) [ud setObject:old forKey:key]; else [ud removeObjectForKey:key];

    BOOL descriptorsOK = (_descriptors.count >= 7 && _descriptors[@"speed"] != nil && _descriptors[@"damage"] != nil);
    BOOL modulesOK = ([ZNModuleManager sharedManager].loadedImages.count > 0 && [ZNModuleManager sharedManager].mainExecutable != nil);
    BOOL modelOK = (ZNStringForActionType(ZNPatchActionTypeIL2CPPMethod).length > 0 && ZNStringForControlType(ZNFeatureControlTypeSlider).length > 0);
    [[ZNIL2CPPResolver sharedResolver] refresh];
    BOOL ok = defaultsOK && descriptorsOK && modulesOK && modelOK;
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"Foundation 自检 %@ defaults=%d descriptors=%d modules=%d model=%d", ok?@"PASS":@"FAIL", defaultsOK, descriptorsOK, modulesOK, modelOK]];
    return ok;
}
- (NSString *)diagnosticReport {
    NSDictionary *counts = self.stateCounts;
    NSMutableString *s = [NSMutableString string];
    [s appendString:@"ZonoePatch Runtime Foundation 0.4.0\n"];
    [s appendString:@"环境约束: Stock iOS / 未越狱 / No JIT\n"];
    [s appendFormat:@"Feature: %@  Action: %lu  已启用: %@  已关闭: %@\n", counts[@"registered"], (unsigned long)self.actionCount, counts[@"enabled"], counts[@"disabled"]];
    [s appendFormat:@"等待模块: %@  不支持: %@  失败: %@\n", counts[@"waiting"], counts[@"unsupported"], counts[@"failed"]];
    [s appendString:[[ZNModuleManager sharedManager] diagnosticReport]];
    [s appendString:[[ZNIL2CPPResolver sharedResolver] diagnosticReport]];
    for (ZNPatchDescriptor *d in self.allDescriptors) {
        [s appendFormat:@"%@ [%@] 控件=%@ backend=%@ enabled=%d value=%.3f actions=%lu\n", d.identifier, ZNStringForPatchState(d.state), ZNStringForControlType(d.controlType), d.backend, d.enabled, d.value, (unsigned long)d.actions.count];
        for (ZNPatchActionDescriptor *a in d.actions) {
            [s appendFormat:@"  - %@ %@ [%@] addr=0x%llx %@\n", a.identifier, ZNStringForActionType(a.type), ZNStringForPatchState(a.state), (unsigned long long)a.resolvedAddress, a.lastError ?: @""];
        }
    }
    return s;
}
@end
