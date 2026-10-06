#import "ZNIL2CPPInvokeEngine.h"
#import "ZNRuntimeActionModel.h"
#import "ZNIL2CPPResolver.h"
#import "ZNIL2CPPABIMetadata.h"
#import "ZNRuntimeArgumentMarshaller.h"
#import "ZNIL2CPPInstanceResolver.h"
#import "ZNIL2CPPInstanceSelectionV2.h"
#import "ZNIL2CPPRuntimeCommon.h"
#import "ZNPatchCore.h"
#import <errno.h>
#import <limits.h>
#import <ctype.h>

static const uint32_t kZNMethodAttributeStatic = 0x0010u;
static thread_local uintptr_t gZNExplicitReceiverOverride = 0;

typedef void *(*ZNRuntimeInvokeFn)(const void *method, void *object, void **params, void **exception);
typedef uint32_t (*ZNMethodGetFlagsFn)(const void *method, uint32_t *iflags);
typedef void *(*ZNStringNewFn)(const char *utf8);

static NSString *ZNInvokeTrim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL ZNInvokeCStringFinished(char *end) {
    if (!end) return NO;
    while (*end && isspace((unsigned char)*end)) end++;
    return *end == '\0';
}

static BOOL ZNInvokeParseSigned(NSString *text, int64_t *outValue) {
    NSString *trimmed = ZNInvokeTrim(text);
    if (!trimmed.length) return NO;
    const char *raw = trimmed.UTF8String;
    if (!raw) return NO;
    errno = 0;
    char *end = NULL;
    long long value = strtoll(raw, &end, 0);
    if (errno || end == raw || !ZNInvokeCStringFinished(end)) return NO;
    if (outValue) *outValue = (int64_t)value;
    return YES;
}

static BOOL ZNInvokeParseUnsigned(NSString *text, uint64_t *outValue) {
    NSString *trimmed = ZNInvokeTrim(text);
    if (!trimmed.length || [trimmed hasPrefix:@"-"]) return NO;
    const char *raw = trimmed.UTF8String;
    if (!raw) return NO;
    errno = 0;
    char *end = NULL;
    unsigned long long value = strtoull(raw, &end, 0);
    if (errno || end == raw || !ZNInvokeCStringFinished(end)) return NO;
    if (outValue) *outValue = (uint64_t)value;
    return YES;
}

static BOOL ZNInvokeParseDouble(NSString *text, double *outValue) {
    NSString *trimmed = ZNInvokeTrim(text);
    if (!trimmed.length) return NO;
    const char *raw = trimmed.UTF8String;
    if (!raw) return NO;
    errno = 0;
    char *end = NULL;
    double value = strtod(raw, &end);
    if (errno || end == raw || !ZNInvokeCStringFinished(end)) return NO;
    if (outValue) *outValue = value;
    return YES;
}

static BOOL ZNInvokeParseBool(NSString *text, uint8_t *outValue) {
    NSString *value = ZNInvokeTrim(text).lowercaseString;
    if ([value isEqualToString:@"1"] || [value isEqualToString:@"true"] ||
        [value isEqualToString:@"yes"] || [value isEqualToString:@"on"]) {
        if (outValue) *outValue = 1;
        return YES;
    }
    if ([value isEqualToString:@"0"] || [value isEqualToString:@"false"] ||
        [value isEqualToString:@"no"] || [value isEqualToString:@"off"]) {
        if (outValue) *outValue = 0;
        return YES;
    }
    return NO;
}

static BOOL ZNInvokeIsStringType(NSString *typeName) {
    NSString *n = ZNInvokeTrim(typeName).lowercaseString;
    return [n isEqualToString:@"system.string"] || [n isEqualToString:@"string"];
}

static NSString *ZNInvokeParameterReason(NSDictionary *param) {
    if ([param[@"byRef"] boolValue]) return @"ref/out 参数暂不支持";
    if ([param[@"pointer"] boolValue]) return @"pointer 参数暂不支持";
    NSString *typeName = param[@"name"] ?: @"?";
    if (ZNInvokeIsStringType(typeName)) return nil;
    ZNIL2CPPABIValueKind kind = (ZNIL2CPPABIValueKind)[param[@"kind"] integerValue];
    switch (kind) {
        case ZNIL2CPPABIValueKindBool:
        case ZNIL2CPPABIValueKindSigned32:
        case ZNIL2CPPABIValueKindUnsigned32:
        case ZNIL2CPPABIValueKindSigned64:
        case ZNIL2CPPABIValueKindUnsigned64:
        case ZNIL2CPPABIValueKindFloat32:
        case ZNIL2CPPABIValueKindFloat64:
            return nil;
        case ZNIL2CPPABIValueKindObjectReference:
            return [NSString stringWithFormat:@"对象参数 %@ 暂不支持（System.String 除外）", typeName];
        case ZNIL2CPPABIValueKindComplexValueType:
            return nil; // validated by the shared value-type marshaller below
        default:
            return [NSString stringWithFormat:@"参数类型 %@ 尚未识别", typeName];
    }
}

@implementation ZNIL2CPPInvokeEngine

+ (instancetype)sharedEngine {
    static ZNIL2CPPInvokeEngine *engine;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ engine = [ZNIL2CPPInvokeEngine new]; });
    return engine;
}

- (NSDictionary<NSString *,id> *)capabilities {
    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    ZNRuntimeInvokeFn runtimeInvoke = (ZNRuntimeInvokeFn)ZNIL2CPPResolveSymbol(resolver.unityPath, "il2cpp_runtime_invoke");
    ZNMethodGetFlagsFn methodGetFlags = (ZNMethodGetFlagsFn)ZNIL2CPPResolveSymbol(resolver.unityPath, "il2cpp_method_get_flags");
    ZNStringNewFn stringNew = (ZNStringNewFn)ZNIL2CPPResolveSymbol(resolver.unityPath, "il2cpp_string_new");
    NSDictionary *instanceCap = [[ZNIL2CPPInstanceResolver sharedResolver] capabilities];
    BOOL base = resolver.isAvailable && runtimeInvoke != NULL && methodGetFlags != NULL;
    return @{
        @"resolver": @(resolver.isAvailable),
        @"runtimeInvoke": @(runtimeInvoke != NULL),
        @"methodGetFlags": @(methodGetFlags != NULL),
        @"stringNew": @(stringNew != NULL),
        @"instanceResolver": @([instanceCap[@"available"] boolValue]),
        @"zeroArgStatic": @(base),
        @"typedArg1Static": @(base),
        @"zeroArgInstance": @(base && [instanceCap[@"available"] boolValue]),
        @"typedArg1Instance": @(base && [instanceCap[@"available"] boolValue]),
    };
}

- (NSDictionary<NSString *,id> *)executeAction:(ZNRuntimeMethodAction *)action error:(NSString **)error {
    if (!action) {
        if (error) *error = @"Runtime Method Call action 为空";
        return nil;
    }
    return [self executeAssembly:action.assembly
                       namespace:action.namespaceName
                       className:action.className
                          method:action.methodName
                   argumentCount:action.argumentCount
                  argumentValues:action.argumentValues ?: @[]
                           error:error];
}

- (NSDictionary<NSString *,id> *)executeAction:(ZNRuntimeMethodAction *)action
                                       receiver:(uintptr_t)receiver
                                          error:(NSString **)error {
    if (!receiver) return [self executeAction:action error:error];
    uintptr_t previous = gZNExplicitReceiverOverride;
    gZNExplicitReceiverOverride = receiver;
    @try {
        return [self executeAction:action error:error];
    } @finally {
        gZNExplicitReceiverOverride = previous;
    }
}

- (NSDictionary<NSString *,id> *)executeAssembly:(NSString *)assembly
                                       namespace:(NSString *)namespaceName
                                       className:(NSString *)className
                                          method:(NSString *)methodName
                                   argumentCount:(NSUInteger)argumentCount
                                           error:(NSString **)error {
    return [self executeAssembly:assembly
                       namespace:namespaceName
                       className:className
                          method:methodName
                   argumentCount:argumentCount
                  argumentValues:@[]
                           error:error];
}

- (NSDictionary<NSString *,id> *)executeAssembly:(NSString *)assembly
                                       namespace:(NSString *)namespaceName
                                       className:(NSString *)className
                                          method:(NSString *)methodName
                                   argumentCount:(NSUInteger)argumentCount
                                  argumentValues:(NSArray<NSString *> *)argumentValues
                                           error:(NSString **)error {
    if (argumentCount > 1) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_UNSUPPORTED_ARGUMENT：M4.3 V1 支持 /0 与 /1；当前=%lu", (unsigned long)argumentCount];
        return nil;
    }
    if (argumentCount == 1 && argumentValues.count != 1) {
        if (error) *error = @"FAILED_ARGUMENT_VALUE：/1 方法需要 1 个输入值";
        return nil;
    }

    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    if (!resolver.isAvailable) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_RESOLVE：%@", resolver.lastError ?: @"IL2CPP Resolver unavailable"];
        return nil;
    }

    NSDictionary *resolved = [resolver resolveMethodAssembly:assembly
                                                   namespace:namespaceName ?: @""
                                                   className:className
                                                      method:methodName
                                               argumentCount:(NSInteger)argumentCount];
    uintptr_t methodInfo = [resolved[@"methodInfo"] unsignedLongLongValue];
    if (!resolved || !methodInfo) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_RESOLVE：%@!%@.%@::%@/%lu",
                             assembly ?: @"",
                             namespaceName ?: @"",
                             className ?: @"",
                             methodName ?: @"",
                             (unsigned long)argumentCount];
        return nil;
    }

    ZNRuntimeInvokeFn runtimeInvoke = (ZNRuntimeInvokeFn)ZNIL2CPPResolveSymbol(resolver.unityPath, "il2cpp_runtime_invoke");
    if (!runtimeInvoke) {
        if (error) *error = @"FAILED_INVOKE_UNAVAILABLE：il2cpp_runtime_invoke 未导出";
        return nil;
    }

    ZNMethodGetFlagsFn methodGetFlags = (ZNMethodGetFlagsFn)ZNIL2CPPResolveSymbol(resolver.unityPath, "il2cpp_method_get_flags");
    if (!methodGetFlags) {
        if (error) *error = @"FAILED_STATIC_STATE_UNAVAILABLE：无法确认方法 static/instance 属性";
        return nil;
    }

    uint32_t implFlags = 0;
    uint32_t methodFlags = methodGetFlags((const void *)methodInfo, &implFlags);
    BOOL isStatic = (methodFlags & kZNMethodAttributeStatic) != 0;
    void *targetObject = NULL;
    NSString *instanceDiagnostics = @"";
    if (!isStatic) {
        if (gZNExplicitReceiverOverride) {
            NSString *validationError = nil;
            BOOL valid = [[ZNIL2CPPInstanceResolver sharedResolver]
                znm44_validateInstanceAddress:gZNExplicitReceiverOverride
                                     assembly:assembly
                                    namespace:namespaceName ?: @""
                                    className:className
                                        error:&validationError];
            if (!valid) {
                if (error) *error = validationError ?: @"FAILED_EXPLICIT_RECEIVER：receiver 验证失败";
                return nil;
            }
            targetObject = (void *)gZNExplicitReceiverOverride;
            instanceDiagnostics = [NSString stringWithFormat:@"explicit-receiver 0x%llX",
                                   (unsigned long long)gZNExplicitReceiverOverride];
        } else {
            NSString *instanceError = nil;
            targetObject = [[ZNIL2CPPInstanceResolver sharedResolver] resolveUniqueInstanceForAssembly:assembly
                                                                                            namespace:namespaceName ?: @""
                                                                                            className:className
                                                                                          diagnostics:&instanceDiagnostics
                                                                                                error:&instanceError];
            if (!targetObject) {
                if (error) *error = instanceError ?: @"FAILED_INSTANCE_REQUIRED：无法解析对象实例";
                return nil;
            }
        }
    }

    void *params[1] = { NULL };
    void **paramsPtr = NULL;
    NSString *parameterType = @"";

    uint8_t boolValue = 0;
    int32_t signed32Value = 0;
    uint32_t unsigned32Value = 0;
    int64_t signed64Value = 0;
    uint64_t unsigned64Value = 0;
    float float32Value = 0;
    double float64Value = 0;
    void *managedString = NULL;
    NSMutableData *encodedValueType = nil; // holds unboxed value until runtime_invoke returns

    if (argumentCount == 1) {
        NSMutableDictionary *candidate = [NSMutableDictionary dictionaryWithDictionary:resolved ?: @{}];
        candidate[@"methodInfo"] = @(methodInfo);
        candidate[@"assembly"] = assembly ?: @"";
        candidate[@"namespace"] = namespaceName ?: @"";
        candidate[@"class"] = className ?: @"";
        candidate[@"method"] = methodName ?: @"";
        candidate[@"argumentCount"] = @1;
        candidate[@"canonical"] = [NSString stringWithFormat:@"%@!%@.%@::%@/1",
                                    assembly ?: @"",
                                    namespaceName ?: @"",
                                    className ?: @"",
                                    methodName ?: @""];
        NSDictionary *abi = ZNIL2CPPDescribeMethodABI(candidate);
        if (![abi[@"available"] boolValue] || [abi[@"parameterCount"] unsignedIntegerValue] != 1) {
            if (error) *error = [NSString stringWithFormat:@"FAILED_ARGUMENT_ABI：%@", abi[@"reason"] ?: @"无法读取 /1 参数类型"];
            return nil;
        }
        if ([abi[@"genericStatusKnown"] boolValue] && [abi[@"generic"] boolValue]) {
            if (error) *error = @"FAILED_ARGUMENT_ABI：generic definition 暂不执行 typed argument";
            return nil;
        }
        NSArray *parameters = abi[@"parameters"];
        NSDictionary *param = parameters.count ? parameters[0] : nil;
        if (!param) {
            if (error) *error = @"FAILED_ARGUMENT_ABI：参数元数据为空";
            return nil;
        }
        NSString *reason = ZNInvokeParameterReason(param);
        if (reason.length) {
            if (error) *error = [@"FAILED_UNSUPPORTED_ARGUMENT_TYPE：" stringByAppendingString:reason];
            return nil;
        }

        NSString *text = argumentValues.firstObject ?: @"";
        parameterType = param[@"name"] ?: @"?";
        ZNIL2CPPABIValueKind kind = (ZNIL2CPPABIValueKind)[param[@"kind"] integerValue];
        if (ZNInvokeIsStringType(parameterType)) {
            ZNStringNewFn stringNew = (ZNStringNewFn)ZNIL2CPPResolveSymbol(resolver.unityPath, "il2cpp_string_new");
            if (!stringNew) {
                if (error) *error = @"FAILED_STRING_API：il2cpp_string_new 未导出";
                return nil;
            }
            managedString = stringNew((text ?: @"").UTF8String ?: "");
            if (!managedString) {
                if (error) *error = @"FAILED_ARGUMENT_VALUE：System.String 创建失败";
                return nil;
            }
            params[0] = managedString;
        } else {
            switch (kind) {
                case ZNIL2CPPABIValueKindBool: {
                    if (!ZNInvokeParseBool(text, &boolValue)) {
                        if (error) *error = @"FAILED_ARGUMENT_VALUE：bool 请输入 0/1 或 true/false";
                        return nil;
                    }
                    params[0] = &boolValue;
                    break;
                }
                case ZNIL2CPPABIValueKindSigned32: {
                    int64_t value = 0;
                    if (!ZNInvokeParseSigned(text, &value) || value < INT32_MIN || value > INT32_MAX) {
                        if (error) *error = @"FAILED_ARGUMENT_VALUE：整数超出 signed32 范围";
                        return nil;
                    }
                    signed32Value = (int32_t)value;
                    params[0] = &signed32Value;
                    break;
                }
                case ZNIL2CPPABIValueKindUnsigned32: {
                    uint64_t value = 0;
                    if (!ZNInvokeParseUnsigned(text, &value) || value > UINT32_MAX) {
                        if (error) *error = @"FAILED_ARGUMENT_VALUE：整数超出 unsigned32 范围";
                        return nil;
                    }
                    unsigned32Value = (uint32_t)value;
                    params[0] = &unsigned32Value;
                    break;
                }
                case ZNIL2CPPABIValueKindSigned64: {
                    if (!ZNInvokeParseSigned(text, &signed64Value)) {
                        if (error) *error = @"FAILED_ARGUMENT_VALUE：请输入 signed64 整数";
                        return nil;
                    }
                    params[0] = &signed64Value;
                    break;
                }
                case ZNIL2CPPABIValueKindUnsigned64: {
                    if (!ZNInvokeParseUnsigned(text, &unsigned64Value)) {
                        if (error) *error = @"FAILED_ARGUMENT_VALUE：请输入 unsigned64 整数";
                        return nil;
                    }
                    params[0] = &unsigned64Value;
                    break;
                }
                case ZNIL2CPPABIValueKindFloat32: {
                    double value = 0;
                    if (!ZNInvokeParseDouble(text, &value)) {
                        if (error) *error = @"FAILED_ARGUMENT_VALUE：请输入 float 数值";
                        return nil;
                    }
                    float32Value = (float)value;
                    params[0] = &float32Value;
                    break;
                }
                case ZNIL2CPPABIValueKindFloat64: {
                    if (!ZNInvokeParseDouble(text, &float64Value)) {
                        if (error) *error = @"FAILED_ARGUMENT_VALUE：请输入 double 数值";
                        return nil;
                    }
                    params[0] = &float64Value;
                    break;
                }
                case ZNIL2CPPABIValueKindComplexValueType: {
                    NSString *codecError = nil;
                    encodedValueType = [ZNRuntimeArgumentMarshaller encodeValueTypeParameterForMethod:methodInfo
                                                                                               index:0
                                                                                                type:parameterType
                                                                                               input:text
                                                                                           imagePath:resolver.unityPath
                                                                                               error:&codecError];
                    if (!encodedValueType) {
                        if (error) *error = [NSString stringWithFormat:@"FAILED_UNSUPPORTED_ARGUMENT_TYPE：参数1 %@：%@",
                                            parameterType ?: @"?", codecError ?: @"无匹配 Codec"];
                        return nil;
                    }
                    params[0] = encodedValueType.mutableBytes;
                    break;
                }
                default:
                    if (error) *error = [NSString stringWithFormat:@"FAILED_UNSUPPORTED_ARGUMENT_TYPE：%@", parameterType ?: @"?"];
                    return nil;
            }
        }
        paramsPtr = params;
    }

    void *exception = NULL;
    void *result = runtimeInvoke((const void *)methodInfo, targetObject, paramsPtr, &exception);
    if (exception) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_EXCEPTION：IL2CPP exception=0x%llX",
                             (unsigned long long)(uintptr_t)exception];
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[runtime-method-call] exception methodInfo=0x%llX object=0x%llX exception=0x%llX",
                                             (unsigned long long)methodInfo,
                                             (unsigned long long)(uintptr_t)targetObject,
                                             (unsigned long long)(uintptr_t)exception]];
        return nil;
    }

    NSDictionary *output = @{
        @"status": @"SUCCESS",
        @"methodInfo": @(methodInfo),
        @"methodPointer": resolved[@"methodPointer"] ?: @0,
        @"pointerSource": resolved[@"pointerSource"] ?: @"unavailable",
        @"methodFlags": @(methodFlags),
        @"implFlags": @(implFlags),
        @"static": @(isStatic),
        @"instance": @((uintptr_t)targetObject),
        @"instanceDiagnostics": instanceDiagnostics ?: @"",
        @"argumentCount": @(argumentCount),
        @"argumentValues": argumentValues ?: @[],
        @"parameterType": parameterType ?: @"",
        @"result": @((uintptr_t)result),
    };
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[runtime-method-call] SUCCESS %@!%@.%@::%@/%lu args=%@ static=%@ object=0x%llX methodInfo=0x%llX",
                                         assembly ?: @"",
                                         namespaceName ?: @"",
                                         className ?: @"",
                                         methodName ?: @"",
                                         (unsigned long)argumentCount,
                                         argumentValues ?: @[],
                                         isStatic ? @"YES" : @"NO",
                                         (unsigned long long)(uintptr_t)targetObject,
                                         (unsigned long long)methodInfo]];
    return output;
}

@end
