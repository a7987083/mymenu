#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <errno.h>
#import <limits.h>
#import <ctype.h>

#import "ZNIL2CPPABIMetadata.h"
#import "ZNRuntimeArgumentMarshaller.h"
#import "ZNIL2CPPInstanceResolver.h"
#import "ZNIL2CPPInstanceSelectionV2.h"
#import "ZNIL2CPPInvokeEngine.h"
#import "ZNIL2CPPMethodSignature.h"
#import "ZNIL2CPPResolver.h"
#import "ZNRuntimeActionFormat.h"
#import "ZNRuntimeActionModel.h"
#import "ZNPatchCore.h"

static const uint32_t kZNM47MethodAttributeStatic = 0x0010u;
typedef void *(*ZNM47RuntimeInvokeFn)(const void *, void *, void **, void **);
typedef uint32_t (*ZNM47MethodGetFlagsFn)(const void *, uint32_t *);
typedef void *(*ZNM47StringNewFn)(const char *);

static void *ZNM47Symbol(NSString *path, const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p || !path.length) return p;
#ifdef RTLD_NOLOAD
    void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
#else
    void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY);
#endif
    return h ? dlsym(h, name) : NULL;
}

static NSString *ZNM47Trim(NSString *s) {
    return [s ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL ZNM47Finished(char *end) {
    if (!end) return NO;
    while (*end && isspace((unsigned char)*end)) end++;
    return *end == '\0';
}

static BOOL ZNM47ParseSigned(NSString *text, int64_t *out) {
    NSString *s = ZNM47Trim(text); if (!s.length) return NO;
    const char *raw = s.UTF8String; if (!raw) return NO;
    errno = 0; char *end = NULL; long long v = strtoll(raw, &end, 0);
    if (errno || end == raw || !ZNM47Finished(end)) return NO;
    if (out) *out = (int64_t)v; return YES;
}

static BOOL ZNM47ParseUnsigned(NSString *text, uint64_t *out) {
    NSString *s = ZNM47Trim(text); if (!s.length || [s hasPrefix:@"-"]) return NO;
    const char *raw = s.UTF8String; if (!raw) return NO;
    errno = 0; char *end = NULL; unsigned long long v = strtoull(raw, &end, 0);
    if (errno || end == raw || !ZNM47Finished(end)) return NO;
    if (out) *out = (uint64_t)v; return YES;
}

static BOOL ZNM47ParseDouble(NSString *text, double *out) {
    NSString *s = ZNM47Trim(text); if (!s.length) return NO;
    const char *raw = s.UTF8String; if (!raw) return NO;
    errno = 0; char *end = NULL; double v = strtod(raw, &end);
    if (errno || end == raw || !ZNM47Finished(end)) return NO;
    if (out) *out = v; return YES;
}

static BOOL ZNM47ParseBool(NSString *text, uint8_t *out) {
    NSString *s = ZNM47Trim(text).lowercaseString;
    if ([s isEqualToString:@"1"] || [s isEqualToString:@"true"] || [s isEqualToString:@"yes"] || [s isEqualToString:@"on"]) { if (out) *out = 1; return YES; }
    if ([s isEqualToString:@"0"] || [s isEqualToString:@"false"] || [s isEqualToString:@"no"] || [s isEqualToString:@"off"]) { if (out) *out = 0; return YES; }
    return NO;
}

static BOOL ZNM47IsString(NSString *type) {
    NSString *n = ZNM47Trim(type).lowercaseString;
    return [n isEqualToString:@"system.string"] || [n isEqualToString:@"string"];
}

static NSUInteger ZNM47StructComponents(NSString *type) {
    NSString *n = ZNM47Trim(type).lowercaseString;
    if ([n isEqualToString:@"unityengine.vector2"] || [n isEqualToString:@"vector2"]) return 2;
    if ([n isEqualToString:@"unityengine.vector3"] || [n isEqualToString:@"vector3"]) return 3;
    if ([n isEqualToString:@"unityengine.quaternion"] || [n isEqualToString:@"quaternion"]) return 4;
    if ([n isEqualToString:@"unityengine.color"] || [n isEqualToString:@"color"]) return 4;
    return 0;
}

static BOOL ZNM47ParseComponents(NSString *text, NSUInteger expected, float out[4]) {
    NSMutableCharacterSet *sep = [[NSCharacterSet whitespaceAndNewlineCharacterSet] mutableCopy];
    [sep addCharactersInString:@",，;；"];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *p in [ZNM47Trim(text) componentsSeparatedByCharactersInSet:sep]) if (ZNM47Trim(p).length) [parts addObject:ZNM47Trim(p)];
    if (parts.count != expected) return NO;
    for (NSUInteger i = 0; i < expected; i++) {
        double v = 0; if (!ZNM47ParseDouble(parts[i], &v)) return NO; out[i] = (float)v;
    }
    return YES;
}

static NSDictionary *ZNM47ResolveAction(ZNRuntimeMethodAction *action, NSString **error) {
    if (action.signatureAvailable && action.parameterTypeNames.count == action.argumentCount) {
        return [[ZNIL2CPPFullSignatureResolver sharedResolver] resolveAssembly:action.assembly
                                                                      namespace:action.namespaceName ?: @""
                                                                      className:action.className
                                                                         method:action.methodName
                                                             parameterTypeNames:action.parameterTypeNames
                                                                          error:error];
    }
    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    NSDictionary *resolved = [resolver resolveMethodAssembly:action.assembly
                                                    namespace:action.namespaceName ?: @""
                                                    className:action.className
                                                       method:action.methodName
                                                argumentCount:(NSInteger)action.argumentCount];
    if (!resolved && error) *error = [NSString stringWithFormat:@"FAILED_RESOLVE：%@", action.legacyCanonicalIdentity ?: @""];
    return resolved;
}

static void *ZNM47InstanceForAction(ZNRuntimeMethodAction *action, NSString **diagnostics, NSString **error) {
    ZNIL2CPPInstanceResolver *resolver = [ZNIL2CPPInstanceResolver sharedResolver];
    uintptr_t selected = [resolver znm44_selectedInstanceForAssembly:action.assembly
                                                            namespace:action.namespaceName ?: @""
                                                            className:action.className];
    if (selected) {
        NSString *validation = nil;
        if ([resolver znm44_validateInstanceAddress:selected
                                           assembly:action.assembly
                                          namespace:action.namespaceName ?: @""
                                          className:action.className
                                              error:&validation]) {
            if (diagnostics) *diagnostics = @"selected-session-receiver";
            return (void *)selected;
        }
        [resolver znm44_clearSelectedInstanceForAssembly:action.assembly namespace:action.namespaceName ?: @"" className:action.className];
    }
    return [resolver resolveUniqueInstanceForAssembly:action.assembly
                                             namespace:action.namespaceName ?: @""
                                             className:action.className
                                           diagnostics:diagnostics
                                                 error:error];
}

@interface ZNIL2CPPInvokeEngine (ZNM47MultiArgInvoke)
- (NSDictionary<NSString *,id> *)znm47_executeAction:(ZNRuntimeMethodAction *)action error:(NSString **)error;
- (NSDictionary<NSString *,id> *)znm47_capabilities;
@end

@implementation ZNIL2CPPInvokeEngine (ZNM47MultiArgInvoke)

- (NSDictionary<NSString *,id> *)znm47_executeAction:(ZNRuntimeMethodAction *)action error:(NSString **)error {
    if (!action || action.argumentCount < 2) return [self znm47_executeAction:action error:error];
    if (action.argumentCount > ZN_RUNTIME_ACTION_MAX_ARGUMENTS) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_UNSUPPORTED_ARGUMENT：M4.7 最多 %u 个参数", ZN_RUNTIME_ACTION_MAX_ARGUMENTS];
        return nil;
    }
    if (action.argumentValues.count != action.argumentCount) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_ARGUMENT_VALUE：需要 %lu 个参数值，当前=%lu",
                             (unsigned long)action.argumentCount, (unsigned long)action.argumentValues.count];
        return nil;
    }

    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    if (!resolver.isAvailable) { if (error) *error = resolver.lastError ?: @"FAILED_RESOLVE"; return nil; }

    NSString *resolveError = nil;
    NSDictionary *resolved = ZNM47ResolveAction(action, &resolveError);
    uintptr_t methodInfo = [resolved[@"methodInfo"] unsignedLongLongValue];
    if (!resolved || !methodInfo) { if (error) *error = resolveError ?: @"FAILED_RESOLVE"; return nil; }

    NSMutableDictionary *candidate = [NSMutableDictionary dictionaryWithDictionary:resolved];
    candidate[@"methodInfo"] = @(methodInfo);
    candidate[@"assembly"] = action.assembly ?: @"";
    candidate[@"namespace"] = action.namespaceName ?: @"";
    candidate[@"class"] = action.className ?: @"";
    candidate[@"method"] = action.methodName ?: @"";
    candidate[@"argumentCount"] = @(action.argumentCount);
    NSDictionary *abi = ZNIL2CPPDescribeMethodABI(candidate);
    NSArray<NSDictionary *> *parameters = [abi[@"parameters"] isKindOfClass:NSArray.class] ? abi[@"parameters"] : nil;
    if (![abi[@"available"] boolValue] || parameters.count != action.argumentCount) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_ARGUMENT_ABI：%@", abi[@"reason"] ?: @"参数 ABI 不完整"];
        return nil;
    }
    if ([abi[@"genericStatusKnown"] boolValue] && [abi[@"generic"] boolValue]) {
        if (error) *error = @"FAILED_ARGUMENT_ABI：generic definition 暂不执行多参数调用";
        return nil;
    }

    ZNM47RuntimeInvokeFn runtimeInvoke = (ZNM47RuntimeInvokeFn)ZNM47Symbol(resolver.unityPath, "il2cpp_runtime_invoke");
    ZNM47MethodGetFlagsFn getFlags = (ZNM47MethodGetFlagsFn)ZNM47Symbol(resolver.unityPath, "il2cpp_method_get_flags");
    ZNM47StringNewFn stringNew = (ZNM47StringNewFn)ZNM47Symbol(resolver.unityPath, "il2cpp_string_new");
    if (!runtimeInvoke || !getFlags) { if (error) *error = @"FAILED_INVOKE_UNAVAILABLE：IL2CPP invoke/flags API 不完整"; return nil; }

    uint32_t implFlags = 0;
    BOOL isStatic = (getFlags((const void *)methodInfo, &implFlags) & kZNM47MethodAttributeStatic) != 0;
    void *target = NULL;
    NSString *instanceDiagnostics = @"";
    if (!isStatic) {
        NSString *instanceError = nil;
        target = ZNM47InstanceForAction(action, &instanceDiagnostics, &instanceError);
        if (!target) { if (error) *error = instanceError ?: @"FAILED_INSTANCE_REQUIRED：没有 receiver"; return nil; }
    }

    const NSUInteger n = action.argumentCount;
    void *params[ZN_RUNTIME_ACTION_MAX_ARGUMENTS] = {};
    uint8_t boolValues[ZN_RUNTIME_ACTION_MAX_ARGUMENTS] = {};
    int32_t s32[ZN_RUNTIME_ACTION_MAX_ARGUMENTS] = {};
    uint32_t u32[ZN_RUNTIME_ACTION_MAX_ARGUMENTS] = {};
    int64_t s64[ZN_RUNTIME_ACTION_MAX_ARGUMENTS] = {};
    uint64_t u64[ZN_RUNTIME_ACTION_MAX_ARGUMENTS] = {};
    float f32[ZN_RUNTIME_ACTION_MAX_ARGUMENTS] = {};
    double f64[ZN_RUNTIME_ACTION_MAX_ARGUMENTS] = {};
    float structValues[ZN_RUNTIME_ACTION_MAX_ARGUMENTS][4] = {};
    void *managedStrings[ZN_RUNTIME_ACTION_MAX_ARGUMENTS] = {};
    NSMutableArray<NSMutableData *> *encodedValueTypes = [NSMutableArray array];
    NSMutableArray<NSString *> *types = [NSMutableArray arrayWithCapacity:n];

    for (NSUInteger i = 0; i < n; i++) {
        NSDictionary *param = parameters[i];
        NSString *type = [param[@"name"] isKindOfClass:NSString.class] ? param[@"name"] : @"?";
        NSString *text = action.argumentValues[i] ?: @"";
        [types addObject:type];
        if ([param[@"byRef"] boolValue]) { if (error) *error = [NSString stringWithFormat:@"FAILED_UNSUPPORTED_ARGUMENT_TYPE：参数%lu ref/out 暂不支持", (unsigned long)i + 1]; return nil; }
        if ([param[@"pointer"] boolValue]) { if (error) *error = [NSString stringWithFormat:@"FAILED_UNSUPPORTED_ARGUMENT_TYPE：参数%lu pointer 暂不支持", (unsigned long)i + 1]; return nil; }

        if (ZNM47IsString(type)) {
            if (!stringNew) { if (error) *error = @"FAILED_STRING_API：il2cpp_string_new 未导出"; return nil; }
            managedStrings[i] = stringNew(text.UTF8String ?: "");
            if (!managedStrings[i]) { if (error) *error = [NSString stringWithFormat:@"FAILED_ARGUMENT_VALUE：参数%lu String 创建失败", (unsigned long)i + 1]; return nil; }
            params[i] = managedStrings[i];
            continue;
        }

        ZNIL2CPPABIValueKind kind = (ZNIL2CPPABIValueKind)[param[@"kind"] integerValue];
        switch (kind) {
            case ZNIL2CPPABIValueKindBool:
                if (!ZNM47ParseBool(text, &boolValues[i])) { if (error) *error = [NSString stringWithFormat:@"参数%lu bool 请输入 0/1 或 true/false", (unsigned long)i + 1]; return nil; }
                params[i] = &boolValues[i]; break;
            case ZNIL2CPPABIValueKindSigned32: {
                int64_t v = 0; if (!ZNM47ParseSigned(text, &v) || v < INT32_MIN || v > INT32_MAX) { if (error) *error = [NSString stringWithFormat:@"参数%lu 超出 signed32 范围", (unsigned long)i + 1]; return nil; }
                s32[i] = (int32_t)v; params[i] = &s32[i]; break;
            }
            case ZNIL2CPPABIValueKindUnsigned32: {
                uint64_t v = 0; if (!ZNM47ParseUnsigned(text, &v) || v > UINT32_MAX) { if (error) *error = [NSString stringWithFormat:@"参数%lu 超出 unsigned32 范围", (unsigned long)i + 1]; return nil; }
                u32[i] = (uint32_t)v; params[i] = &u32[i]; break;
            }
            case ZNIL2CPPABIValueKindSigned64:
                if (!ZNM47ParseSigned(text, &s64[i])) { if (error) *error = [NSString stringWithFormat:@"参数%lu 请输入 signed64", (unsigned long)i + 1]; return nil; }
                params[i] = &s64[i]; break;
            case ZNIL2CPPABIValueKindUnsigned64:
                if (!ZNM47ParseUnsigned(text, &u64[i])) { if (error) *error = [NSString stringWithFormat:@"参数%lu 请输入 unsigned64", (unsigned long)i + 1]; return nil; }
                params[i] = &u64[i]; break;
            case ZNIL2CPPABIValueKindFloat32: {
                double v = 0; if (!ZNM47ParseDouble(text, &v)) { if (error) *error = [NSString stringWithFormat:@"参数%lu 请输入 float", (unsigned long)i + 1]; return nil; }
                f32[i] = (float)v; params[i] = &f32[i]; break;
            }
            case ZNIL2CPPABIValueKindFloat64:
                if (!ZNM47ParseDouble(text, &f64[i])) { if (error) *error = [NSString stringWithFormat:@"参数%lu 请输入 double", (unsigned long)i + 1]; return nil; }
                params[i] = &f64[i]; break;
            case ZNIL2CPPABIValueKindComplexValueType: {
                NSUInteger components = ZNM47StructComponents(type);
                if (components && ZNM47ParseComponents(text, components, structValues[i])) {
                    params[i] = structValues[i];
                    break;
                }
                // Unknown value types are delegated to the shared marshaller.
                // No guessing: payload size is verified against IL2CPP class metadata.
                NSString *codecError = nil;
                NSMutableData *payload = [ZNRuntimeArgumentMarshaller encodeValueTypeParameterForMethod:methodInfo
                                                                                                 index:i
                                                                                                  type:type
                                                                                                 input:text
                                                                                             imagePath:resolver.unityPath
                                                                                                 error:&codecError];
                if (!payload) {
                    if (error) *error = [NSString stringWithFormat:@"FAILED_UNSUPPORTED_ARGUMENT_TYPE：参数%lu %@：%@",
                                        (unsigned long)i + 1, type, codecError ?: @"没有匹配的 Codec"];
                    return nil;
                }
                [encodedValueTypes addObject:payload]; // retain through runtime_invoke
                params[i] = payload.mutableBytes;
                break;
            }
            case ZNIL2CPPABIValueKindObjectReference:
                if (error) *error = [NSString stringWithFormat:@"FAILED_UNSUPPORTED_ARGUMENT_TYPE：参数%lu 对象类型 %@ 暂不支持（String 除外）", (unsigned long)i + 1, type];
                return nil;
            default:
                if (error) *error = [NSString stringWithFormat:@"FAILED_UNSUPPORTED_ARGUMENT_TYPE：参数%lu 类型 %@ 未识别", (unsigned long)i + 1, type];
                return nil;
        }
    }

    void *exception = NULL;
    void *returnObject = runtimeInvoke((const void *)methodInfo, target, params, &exception);
    if (exception) { if (error) *error = [NSString stringWithFormat:@"FAILED_MANAGED_EXCEPTION：exception=0x%llX", (unsigned long long)(uintptr_t)exception]; return nil; }

    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m4.7-multiarg] SUCCESS %@ args=%@ types=%@ receiver=%@",
                                         action.canonicalIdentity, action.argumentValues, types,
                                         isStatic ? @"static" : instanceDiagnostics ?: @"instance"]];
    if (error) *error = nil;
    return @{
        @"methodInfo": @(methodInfo),
        @"static": @(isStatic),
        @"instance": @((uintptr_t)target),
        @"returnObject": @((uintptr_t)returnObject),
        @"parameterTypes": types,
        @"argumentValues": action.argumentValues ?: @[],
        @"multiArg": @YES,
    };
}

- (NSDictionary<NSString *,id> *)znm47_capabilities {
    NSMutableDictionary *cap = [[self znm47_capabilities] mutableCopy] ?: [NSMutableDictionary dictionary];
    BOOL base = [cap[@"resolver"] boolValue] && [cap[@"runtimeInvoke"] boolValue] && [cap[@"methodGetFlags"] boolValue];
    cap[@"multiArgStatic"] = @(base);
    cap[@"multiArgInstance"] = @(base && [cap[@"instanceResolver"] boolValue]);
    cap[@"multiArgMax"] = @(ZN_RUNTIME_ACTION_MAX_ARGUMENTS);
    return [cap copy];
}

@end

static void ZNM47Swap(Class cls, SEL a, SEL b) {
    Method ma = class_getInstanceMethod(cls, a), mb = class_getInstanceMethod(cls, b);
    if (ma && mb) method_exchangeImplementations(ma, mb);
}

extern "C" void ZNInstallM47MultiArgInvokeDeferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZNM47Swap(ZNIL2CPPInvokeEngine.class, @selector(executeAction:error:), @selector(znm47_executeAction:error:));
        ZNM47Swap(ZNIL2CPPInvokeEngine.class, @selector(capabilities), @selector(znm47_capabilities));
        [[ZNRuntimeLogger sharedLogger] log:@"[m4.7-multiarg] /2-/8 primitive,string,Vector/Quaternion/Color invoke layer installed"];
    });
}
