#import "ZNIL2CPPABIMetadata.h"

#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <math.h>

namespace {
using MethodGetReturnTypeFn = const void *(*)(const void *);
using MethodGetParamFn = const void *(*)(const void *, uint32_t);
using MethodGetParamCountFn = uint32_t (*)(const void *);
using MethodGetParamNameFn = const char *(*)(const void *, uint32_t);
using MethodIsGenericFn = bool (*)(const void *);
using MethodIsInflatedFn = bool (*)(const void *);
using MethodIsInstanceFn = bool (*)(const void *);
using TypeGetNameFn = char *(*)(const void *);
using TypeIsByRefFn = bool (*)(const void *);
using TypeIsPointerFn = bool (*)(const void *);
using ClassFromTypeFn = void *(*)(const void *);
using ClassIsValueTypeFn = bool (*)(const void *);
using ClassIsEnumFn = bool (*)(const void *);
using ClassEnumBaseTypeFn = const void *(*)(void *);
using Il2CppFreeFn = void (*)(void *);

struct ZNABIAPI {
    void *handle = nullptr;
    MethodGetReturnTypeFn methodGetReturnType = nullptr;
    MethodGetParamFn methodGetParam = nullptr;
    MethodGetParamCountFn methodGetParamCount = nullptr;
    MethodGetParamNameFn methodGetParamName = nullptr;
    MethodIsGenericFn methodIsGeneric = nullptr;
    MethodIsInflatedFn methodIsInflated = nullptr;
    MethodIsInstanceFn methodIsInstance = nullptr;
    TypeGetNameFn typeGetName = nullptr;
    TypeIsByRefFn typeIsByRef = nullptr;
    TypeIsPointerFn typeIsPointer = nullptr;
    ClassFromTypeFn classFromType = nullptr;
    ClassIsValueTypeFn classIsValueType = nullptr;
    ClassIsEnumFn classIsEnum = nullptr;
    ClassEnumBaseTypeFn classEnumBaseType = nullptr;
    Il2CppFreeFn il2cppFree = nullptr;
};

static void *ZNABISymbol(void *handle, const char *name) {
    void *p = handle ? dlsym(handle, name) : nullptr;
    if (!p) p = dlsym(RTLD_DEFAULT, name);
    return p;
}

static void *ZNABIUnityHandle(void) {
    static void *handle = nullptr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uint32_t count = _dyld_image_count();
        for (uint32_t i = 0; i < count; i++) {
            const char *path = _dyld_get_image_name(i);
            if (!path) continue;
            NSString *p = [NSString stringWithUTF8String:path];
            if (![p.lastPathComponent isEqualToString:@"UnityFramework"]) continue;
            handle = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
            if (!handle) handle = dlopen(path, RTLD_LAZY);
            break;
        }
    });
    return handle;
}

static const ZNABIAPI &ZNABIResolvedAPI(void) {
    static ZNABIAPI api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        api.handle = ZNABIUnityHandle();
#define ZNABI_LOAD(field, type, symbol) api.field = reinterpret_cast<type>(ZNABISymbol(api.handle, symbol))
        ZNABI_LOAD(methodGetReturnType, MethodGetReturnTypeFn, "il2cpp_method_get_return_type");
        ZNABI_LOAD(methodGetParam, MethodGetParamFn, "il2cpp_method_get_param");
        ZNABI_LOAD(methodGetParamCount, MethodGetParamCountFn, "il2cpp_method_get_param_count");
        ZNABI_LOAD(methodGetParamName, MethodGetParamNameFn, "il2cpp_method_get_param_name");
        ZNABI_LOAD(methodIsGeneric, MethodIsGenericFn, "il2cpp_method_is_generic");
        ZNABI_LOAD(methodIsInflated, MethodIsInflatedFn, "il2cpp_method_is_inflated");
        ZNABI_LOAD(methodIsInstance, MethodIsInstanceFn, "il2cpp_method_is_instance");
        ZNABI_LOAD(typeGetName, TypeGetNameFn, "il2cpp_type_get_name");
        ZNABI_LOAD(typeIsByRef, TypeIsByRefFn, "il2cpp_type_is_byref");
        ZNABI_LOAD(typeIsPointer, TypeIsPointerFn, "il2cpp_type_is_pointer_type");
        ZNABI_LOAD(classFromType, ClassFromTypeFn, "il2cpp_class_from_type");
        if (!api.classFromType) {
            ZNABI_LOAD(classFromType, ClassFromTypeFn, "il2cpp_class_from_il2cpp_type");
        }
        ZNABI_LOAD(classIsValueType, ClassIsValueTypeFn, "il2cpp_class_is_valuetype");
        ZNABI_LOAD(classIsEnum, ClassIsEnumFn, "il2cpp_class_is_enum");
        ZNABI_LOAD(classEnumBaseType, ClassEnumBaseTypeFn, "il2cpp_class_enum_basetype");
        ZNABI_LOAD(il2cppFree, Il2CppFreeFn, "il2cpp_free");
#undef ZNABI_LOAD
    });
    return api;
}

static NSString *ZNABITypeName(const ZNABIAPI &api, const void *type) {
    if (!type || !api.typeGetName) return @"?";
    char *raw = api.typeGetName(type);
    if (!raw) return @"?";
    NSString *name = [NSString stringWithUTF8String:raw] ?: @"?";
    if (api.il2cppFree) api.il2cppFree(raw);
    return name;
}

static NSDictionary *ZNABIClassifyRuntimeType(const ZNABIAPI &api, const void *type, NSUInteger depth) {
    if (!type || depth > 2) {
        return @{@"name": @"?", @"kind": @(ZNIL2CPPABIValueKindUnknown), @"byRef": @NO, @"pointer": @NO};
    }
    NSString *name = ZNABITypeName(api, type);
    BOOL byRef = api.typeIsByRef ? api.typeIsByRef(type) : [name hasSuffix:@"&"];
    BOOL pointer = api.typeIsPointer ? api.typeIsPointer(type) : [name hasSuffix:@"*"];
    if (byRef || pointer) {
        return @{@"name": name, @"kind": @(ZNIL2CPPABIValueKindPointer), @"byRef": @(byRef), @"pointer": @(pointer)};
    }

    ZNIL2CPPABIValueKind primitive = ZNIL2CPPABIKindForManagedTypeName(name);
    if (primitive != ZNIL2CPPABIValueKindUnknown) {
        return @{@"name": name, @"kind": @(primitive), @"byRef": @NO, @"pointer": @NO};
    }

    void *klass = api.classFromType ? api.classFromType(type) : nullptr;
    if (!klass || !api.classIsValueType) {
        return @{@"name": name, @"kind": @(ZNIL2CPPABIValueKindUnknown), @"byRef": @NO, @"pointer": @NO};
    }
    BOOL valueType = api.classIsValueType(klass);
    if (!valueType) {
        return @{@"name": name, @"kind": @(ZNIL2CPPABIValueKindObjectReference), @"byRef": @NO, @"pointer": @NO};
    }
    if (api.classIsEnum && api.classEnumBaseType && api.classIsEnum(klass)) {
        const void *base = api.classEnumBaseType(klass);
        NSDictionary *baseInfo = ZNABIClassifyRuntimeType(api, base, depth + 1);
        NSMutableDictionary *result = [baseInfo mutableCopy];
        result[@"name"] = name;
        result[@"enum"] = @YES;
        result[@"enumBase"] = baseInfo[@"name"] ?: @"?";
        return result;
    }
    return @{@"name": name, @"kind": @(ZNIL2CPPABIValueKindComplexValueType), @"byRef": @NO, @"pointer": @NO, @"valueType": @YES};
}

static BOOL ZNABIReturnKindFoundationSafe(ZNIL2CPPABIValueKind kind) {
    switch (kind) {
        case ZNIL2CPPABIValueKindBool:
        case ZNIL2CPPABIValueKindSigned32:
        case ZNIL2CPPABIValueKindUnsigned32:
        case ZNIL2CPPABIValueKindSigned64:
        case ZNIL2CPPABIValueKindUnsigned64:
        case ZNIL2CPPABIValueKindFloat32:
        case ZNIL2CPPABIValueKindFloat64:
        case ZNIL2CPPABIValueKindPointer:
            return YES;
        default:
            return NO;
    }
}

static NSString *ZNABIFoundationReason(NSDictionary *abi) {
    if (![abi[@"available"] boolValue]) return abi[@"reason"] ?: @"IL2CPP ABI API 不完整";
    if (![abi[@"genericStatusKnown"] boolValue]) return @"无法确认 generic/inflated 状态";
    if ([abi[@"generic"] boolValue]) return @"Generic definition 不允许自动 Return Override";
    if ([abi[@"inflated"] boolValue]) return @"Inflated/shared generic 方法暂不允许自动 Return Override";
    NSDictionary *ret = abi[@"return"];
    if ([ret[@"byRef"] boolValue]) return @"ByRef 返回值暂不允许自动 Return Override";
    ZNIL2CPPABIValueKind kind = (ZNIL2CPPABIValueKind)[ret[@"kind"] integerValue];
    if (kind == ZNIL2CPPABIValueKindVoid) return @"void 方法没有返回值可覆盖";
    if (kind == ZNIL2CPPABIValueKindObjectReference) return @"托管对象返回值需要 GC/对象生命周期策略，M3.1 暂不自动覆盖";
    if (kind == ZNIL2CPPABIValueKindComplexValueType) return @"复杂值类型/struct 返回 ABI 暂不自动支持";
    if (!ZNABIReturnKindFoundationSafe(kind)) return @"返回类型 ABI 尚未识别";
    return @"M3.1 ABI foundation ready；等待 M3.2 Hook backend";
}
}

NSString *ZNIL2CPPABIValueKindName(ZNIL2CPPABIValueKind kind) {
    switch (kind) {
        case ZNIL2CPPABIValueKindVoid: return @"void";
        case ZNIL2CPPABIValueKindBool: return @"bool / GPR32";
        case ZNIL2CPPABIValueKindSigned32: return @"signed ≤32 / GPR32";
        case ZNIL2CPPABIValueKindUnsigned32: return @"unsigned ≤32 / GPR32";
        case ZNIL2CPPABIValueKindSigned64: return @"signed64 / GPR64";
        case ZNIL2CPPABIValueKindUnsigned64: return @"unsigned64 / GPR64";
        case ZNIL2CPPABIValueKindFloat32: return @"float / FP32";
        case ZNIL2CPPABIValueKindFloat64: return @"double / FP64";
        case ZNIL2CPPABIValueKindPointer: return @"pointer / GPR64";
        case ZNIL2CPPABIValueKindObjectReference: return @"managed reference / GPR64";
        case ZNIL2CPPABIValueKindComplexValueType: return @"complex value type";
        default: return @"unknown";
    }
}

ZNIL2CPPABIValueKind ZNIL2CPPABIKindForManagedTypeName(NSString *typeName) {
    NSString *n = [[typeName ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if ([n isEqualToString:@"system.void"] || [n isEqualToString:@"void"]) return ZNIL2CPPABIValueKindVoid;
    if ([n isEqualToString:@"system.boolean"] || [n isEqualToString:@"bool"]) return ZNIL2CPPABIValueKindBool;
    if ([n isEqualToString:@"system.sbyte"] || [n isEqualToString:@"system.int16"] || [n isEqualToString:@"system.int32"] || [n isEqualToString:@"sbyte"] || [n isEqualToString:@"short"] || [n isEqualToString:@"int"]) return ZNIL2CPPABIValueKindSigned32;
    if ([n isEqualToString:@"system.byte"] || [n isEqualToString:@"system.uint16"] || [n isEqualToString:@"system.uint32"] || [n isEqualToString:@"system.char"] || [n isEqualToString:@"byte"] || [n isEqualToString:@"ushort"] || [n isEqualToString:@"uint"] || [n isEqualToString:@"char"]) return ZNIL2CPPABIValueKindUnsigned32;
    if ([n isEqualToString:@"system.int64"] || [n isEqualToString:@"long"]) return ZNIL2CPPABIValueKindSigned64;
    if ([n isEqualToString:@"system.uint64"] || [n isEqualToString:@"ulong"]) return ZNIL2CPPABIValueKindUnsigned64;
    if ([n isEqualToString:@"system.single"] || [n isEqualToString:@"float"]) return ZNIL2CPPABIValueKindFloat32;
    if ([n isEqualToString:@"system.double"] || [n isEqualToString:@"double"]) return ZNIL2CPPABIValueKindFloat64;
    if ([n isEqualToString:@"system.intptr"] || [n isEqualToString:@"system.uintptr"] || [n isEqualToString:@"intptr"] || [n isEqualToString:@"uintptr"]) return ZNIL2CPPABIValueKindPointer;
    return ZNIL2CPPABIValueKindUnknown;
}

NSDictionary<NSString *, id> *ZNIL2CPPDescribeMethodABI(NSDictionary<NSString *, id> *candidate) {
    uintptr_t methodInfoAddress = (uintptr_t)[candidate[@"methodInfo"] unsignedLongLongValue];
    uintptr_t methodPointer = (uintptr_t)[candidate[@"methodPointer"] unsignedLongLongValue];
    const ZNABIAPI &api = ZNABIResolvedAPI();
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"methodInfo"] = @(methodInfoAddress);
    result[@"methodPointer"] = @(methodPointer);
    result[@"canonical"] = candidate[@"canonical"] ?: @"";

    BOOL core = methodInfoAddress && api.methodGetReturnType && api.methodGetParam && api.methodGetParamCount && api.typeGetName;
    result[@"available"] = @(core);
    if (!core) {
        result[@"reason"] = methodInfoAddress ? @"IL2CPP signature exports 不完整" : @"MethodInfo 不可用";
        result[@"returnOverrideEligible"] = @NO;
        return result;
    }

    const void *method = reinterpret_cast<const void *>(methodInfoAddress);
    BOOL genericKnown = api.methodIsGeneric && api.methodIsInflated;
    BOOL isGeneric = genericKnown ? api.methodIsGeneric(method) : NO;
    BOOL isInflated = genericKnown ? api.methodIsInflated(method) : NO;
    BOOL instanceKnown = api.methodIsInstance != nullptr;
    BOOL isInstance = instanceKnown ? api.methodIsInstance(method) : NO;
    result[@"genericStatusKnown"] = @(genericKnown);
    result[@"generic"] = @(isGeneric);
    result[@"inflated"] = @(isInflated);
    result[@"instanceKnown"] = @(instanceKnown);
    result[@"instance"] = @(isInstance);

    NSDictionary *ret = ZNABIClassifyRuntimeType(api, api.methodGetReturnType(method), 0);
    result[@"return"] = ret;

    uint32_t count = api.methodGetParamCount(method);
    NSMutableArray *params = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray<NSString *> *signatureParts = [NSMutableArray arrayWithCapacity:count];
    for (uint32_t i = 0; i < count; i++) {
        const void *paramType = api.methodGetParam(method, i);
        NSMutableDictionary *info = [ZNABIClassifyRuntimeType(api, paramType, 0) mutableCopy];
        const char *rawName = api.methodGetParamName ? api.methodGetParamName(method, i) : nullptr;
        NSString *paramName = rawName ? ([NSString stringWithUTF8String:rawName] ?: @"") : @"";
        info[@"index"] = @(i);
        info[@"paramName"] = paramName;
        [params addObject:info];
        NSString *display = info[@"name"] ?: @"?";
        [signatureParts addObject:paramName.length ? [NSString stringWithFormat:@"%@ %@", display, paramName] : display];
    }
    result[@"parameters"] = params;
    result[@"parameterCount"] = @(count);

    NSString *methodName = candidate[@"method"] ?: @"Method";
    NSString *className = candidate[@"class"] ?: @"Class";
    NSString *mode = instanceKnown ? (isInstance ? @"instance" : @"static") : @"instance/static ?";
    NSString *signature = [NSString stringWithFormat:@"%@ %@ %@::%@(%@)", mode, ret[@"name"] ?: @"?", className, methodName, [signatureParts componentsJoinedByString:@", "]];
    result[@"signature"] = signature;
    result[@"nativeHiddenSelf"] = instanceKnown ? @(isInstance) : [NSNull null];
    result[@"nativeMethodInfoArg"] = @"expected-by-generated-IL2CPP-code; backend must validate before install";

    NSString *reason = ZNABIFoundationReason(result);
    BOOL eligible = [reason hasPrefix:@"M3.1 ABI foundation ready"] && methodPointer != 0;
    if (!methodPointer && [reason hasPrefix:@"M3.1 ABI foundation ready"]) reason = @"Method Pointer 不可用";
    result[@"returnOverrideEligible"] = @(eligible);
    result[@"returnOverrideReason"] = reason;
    return result;
}

NSDictionary<NSString *, id> *ZNIL2CPPBuildReturnOverridePlan(NSDictionary<NSString *, id> *candidate, NSNumber *value, NSString **error) {
    NSDictionary *abi = ZNIL2CPPDescribeMethodABI(candidate);
    if (![abi[@"returnOverrideEligible"] boolValue]) {
        if (error) *error = abi[@"returnOverrideReason"] ?: @"当前方法不适合自动 Return Override";
        return nil;
    }
    NSDictionary *ret = abi[@"return"];
    ZNIL2CPPABIValueKind kind = (ZNIL2CPPABIValueKind)[ret[@"kind"] integerValue];
    NSNumber *normalized = value ?: @0;
    switch (kind) {
        case ZNIL2CPPABIValueKindBool:
            normalized = @([value boolValue]);
            break;
        case ZNIL2CPPABIValueKindSigned32: {
            long long v = [value longLongValue];
            if (v < INT32_MIN || v > INT32_MAX) { if (error) *error = @"值超出 int32 范围"; return nil; }
            normalized = @((int32_t)v);
            break;
        }
        case ZNIL2CPPABIValueKindUnsigned32: {
            unsigned long long v = [value unsignedLongLongValue];
            if (v > UINT32_MAX) { if (error) *error = @"值超出 uint32 范围"; return nil; }
            normalized = @((uint32_t)v);
            break;
        }
        case ZNIL2CPPABIValueKindSigned64:
            normalized = @([value longLongValue]);
            break;
        case ZNIL2CPPABIValueKindUnsigned64:
        case ZNIL2CPPABIValueKindPointer:
            normalized = @([value unsignedLongLongValue]);
            break;
        case ZNIL2CPPABIValueKindFloat32: {
            float v = [value floatValue];
            if (!isfinite(v)) { if (error) *error = @"float 值必须是有限数"; return nil; }
            normalized = @(v);
            break;
        }
        case ZNIL2CPPABIValueKindFloat64: {
            double v = [value doubleValue];
            if (!isfinite(v)) { if (error) *error = @"double 值必须是有限数"; return nil; }
            normalized = @(v);
            break;
        }
        default:
            if (error) *error = @"M3.1 不支持该返回 ABI";
            return nil;
    }
    return @{
        @"version": @1,
        @"foundationOnly": @YES,
        @"applied": @NO,
        @"requiresHookBackend": @YES,
        @"canonical": candidate[@"canonical"] ?: @"",
        @"methodInfo": abi[@"methodInfo"] ?: @0,
        @"methodPointer": abi[@"methodPointer"] ?: @0,
        @"signature": abi[@"signature"] ?: @"",
        @"returnType": ret[@"name"] ?: @"?",
        @"returnKind": @(kind),
        @"returnKindName": ZNIL2CPPABIValueKindName(kind),
        @"value": normalized,
        @"backendState": @"pending-m3.2-hook-backend"
    };
}
