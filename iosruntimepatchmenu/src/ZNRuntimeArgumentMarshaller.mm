#import "ZNRuntimeArgumentMarshaller.h"
#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <float.h>
#import <string.h>

typedef const void *(*ZNMARMethodParamFn)(const void *, uint32_t);
typedef void *(*ZNMARClassFromTypeFn)(const void *);
typedef int32_t (*ZNMARClassValueSizeFn)(void *, uint32_t *);
typedef void *(*ZNMARClassGetMethodsFn)(void *, void **);
typedef const char *(*ZNMARMethodGetNameFn)(const void *);
typedef uint32_t (*ZNMARMethodGetParamCountFn)(const void *);
typedef const void *(*ZNMARMethodGetReturnTypeFn)(const void *);
typedef int (*ZNMARTypeGetTypeFn)(const void *);
typedef uint32_t (*ZNMARMethodGetFlagsFn)(const void *, uint32_t *);
typedef void *(*ZNMARRuntimeInvokeFn)(const void *, void *, void **, void **);
typedef void *(*ZNMARObjectUnboxFn)(void *);


static void *ZNMARSymbol(NSString *imagePath, const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    if (symbol || !imagePath.length) return symbol;
#ifdef RTLD_NOLOAD
    void *handle = dlopen(imagePath.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
#else
    void *handle = dlopen(imagePath.fileSystemRepresentation, RTLD_LAZY);
#endif
    return handle ? dlsym(handle, name) : NULL;
}

@implementation ZNRuntimeArgumentMarshaller

+ (NSMutableDictionary<NSString *, ZNRuntimeValueTypeEncoder> *)registry {
    static NSMutableDictionary *encoders;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ encoders = [NSMutableDictionary new]; });
    return encoders;
}

+ (NSString *)normalized:(NSString *)name {
    return [name ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

+ (void)registerValueType:(NSString *)managedType encoder:(ZNRuntimeValueTypeEncoder)encoder {
    NSString *key = [self normalized:managedType];
    if (!key.length || !encoder) return;
    @synchronized(self) {
        [self registry][key] = [encoder copy];
    }
}

/// Call the game's own static op_Implicit(primitive) and unbox its return.
+ (nullable NSData *)encodeUsingImplicitConversion:(NSString *)input
                                              klass:(void *)klass
                                               size:(NSUInteger)size
                                          imagePath:(NSString *)imagePath
                                              error:(NSString **)error {
    ZNMARClassGetMethodsFn getMethods = (ZNMARClassGetMethodsFn)ZNMARSymbol(imagePath, "il2cpp_class_get_methods");
    ZNMARMethodGetNameFn getName = (ZNMARMethodGetNameFn)ZNMARSymbol(imagePath, "il2cpp_method_get_name");
    ZNMARMethodGetParamCountFn getCount = (ZNMARMethodGetParamCountFn)ZNMARSymbol(imagePath, "il2cpp_method_get_param_count");
    ZNMARMethodGetReturnTypeFn getReturn = (ZNMARMethodGetReturnTypeFn)ZNMARSymbol(imagePath, "il2cpp_method_get_return_type");
    ZNMARMethodParamFn getParam = (ZNMARMethodParamFn)ZNMARSymbol(imagePath, "il2cpp_method_get_param");
    ZNMARClassFromTypeFn fromType = (ZNMARClassFromTypeFn)ZNMARSymbol(imagePath, "il2cpp_class_from_type");
    if (!fromType) fromType = (ZNMARClassFromTypeFn)ZNMARSymbol(imagePath, "il2cpp_class_from_il2cpp_type");
    ZNMARTypeGetTypeFn getType = (ZNMARTypeGetTypeFn)ZNMARSymbol(imagePath, "il2cpp_type_get_type");
    ZNMARMethodGetFlagsFn getFlags = (ZNMARMethodGetFlagsFn)ZNMARSymbol(imagePath, "il2cpp_method_get_flags");
    ZNMARRuntimeInvokeFn invoke = (ZNMARRuntimeInvokeFn)ZNMARSymbol(imagePath, "il2cpp_runtime_invoke");
    ZNMARObjectUnboxFn unbox = (ZNMARObjectUnboxFn)ZNMARSymbol(imagePath, "il2cpp_object_unbox");
    if (!getMethods || !getName || !getCount || !getReturn || !getParam ||
        !fromType || !getType || !getFlags || !invoke || !unbox) return nil;

    NSString *trimmed = [self normalized:input];
    if (!trimmed.length) return nil;
    NSScanner *decimal = [NSScanner scannerWithString:trimmed];
    long long signedValue = 0;
    BOOL isInteger = [decimal scanLongLong:&signedValue] && decimal.isAtEnd;
    NSScanner *floating = [NSScanner scannerWithString:trimmed];
    double doubleValue = 0;
    BOOL isFloat = [floating scanDouble:&doubleValue] && floating.isAtEnd && isfinite(doubleValue);
    if (!isInteger && !isFloat) return nil;

    // Prefer exact 32-bit conversion for ordinary integer strings, then int64,
    // then floating-point. Reject ambiguity within the same preferred kind.
    struct Candidate { const void *method; int score; int type; };
    Candidate best = {NULL, -1, 0};
    BOOL ambiguous = NO;
    void *iterator = NULL;
    const void *method = NULL;
    while ((method = getMethods(klass, &iterator))) {
        const char *name = getName(method);
        if (!name || strcmp(name, "op_Implicit") != 0 || getCount(method) != 1) continue;
        uint32_t implFlags = 0;
        if (!(getFlags(method, &implFlags) & 0x0010u)) continue; // static
        const void *returnType = getReturn(method);
        if (!returnType || fromType(returnType) != klass) continue;
        const void *argumentType = getParam(method, 0);
        if (!argumentType) continue;
        int type = getType(argumentType);
        int score = -1;
        // ECMA-335 ELEMENT_TYPE_I4 / I8 / R4 / R8.
        if (type == 0x08 && isInteger && signedValue >= INT32_MIN && signedValue <= INT32_MAX) score = 50;
        else if (type == 0x0a && isInteger) score = 40;
        else if (type == 0x0c && isFloat && fabs(doubleValue) <= FLT_MAX) score = 30;
        else if (type == 0x0d && isFloat) score = 20;
        if (score > best.score) { best = {method, score, type}; ambiguous = NO; }
        else if (score >= 0 && score == best.score) ambiguous = YES;
    }
    if (!best.method) return nil;
    if (ambiguous) {
        if (error) *error = @"FAILED_CODEC_AMBIGUOUS：存在多个同优先级隐式转换方法";
        return nil;
    }

    int32_t value32 = (int32_t)signedValue;
    int64_t value64 = (int64_t)signedValue;
    float valueFloat = (float)doubleValue;
    double valueDouble = doubleValue;
    void *parameter = best.type == 0x08 ? (void *)&value32 :
                      best.type == 0x0a ? (void *)&value64 :
                      best.type == 0x0c ? (void *)&valueFloat : (void *)&valueDouble;
    void *parameters[1] = {parameter};
    void *exception = NULL;
    void *boxed = invoke(best.method, NULL, parameters, &exception);
    if (exception || !boxed) {
        if (error) *error = @"FAILED_CODEC_CONVERSION：目标游戏 op_Implicit 抛出异常或返回空值";
        return nil;
    }
    void *unboxed = unbox(boxed);
    if (!unboxed) {
        if (error) *error = @"FAILED_CODEC_UNBOX：隐式转换结果无法拆箱";
        return nil;
    }
    return [NSData dataWithBytes:unboxed length:size];
}

+ (nullable NSData *)decodeHex:(NSString *)input size:(NSUInteger)size error:(NSString **)error {
    NSString *value = [self normalized:input];
    if (![value.lowercaseString hasPrefix:@"hex:"]) {
        if (error) *error = @"FAILED_CODEC_REQUIRED：请注册该类型的 Codec；或输入 hex: 后接准确的 value-type 字节";
        return nil;
    }
    NSString *hex = [[value substringFromIndex:4] stringByReplacingOccurrencesOfString:@" " withString:@""];
    if (hex.length != size * 2) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_STRUCT_SIZE：期望 %lu 字节，实际 hex 长度为 %lu",
                            (unsigned long)size, (unsigned long)hex.length / 2];
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    uint8_t *out = (uint8_t *)data.mutableBytes;
    for (NSUInteger i = 0; i < size; ++i) {
        NSString *pair = [hex substringWithRange:NSMakeRange(i * 2, 2)];
        unsigned value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        if (![scanner scanHexInt:&value] || !scanner.isAtEnd) {
            if (error) *error = [NSString stringWithFormat:@"FAILED_STRUCT_HEX：第 %lu 字节不是十六进制", (unsigned long)i];
            return nil;
        }
        out[i] = (uint8_t)value;
    }
    return data;
}

+ (nullable NSMutableData *)encodeValueTypeParameterForMethod:(uintptr_t)methodInfo
                                                        index:(NSUInteger)index
                                                         type:(NSString *)managedType
                                                        input:(NSString *)text
                                                    imagePath:(NSString *)imagePath
                                                        error:(NSString **)error {
    if (!methodInfo || index > UINT32_MAX) {
        if (error) *error = @"FAILED_STRUCT_ABI：缺少 MethodInfo 或参数序号无效";
        return nil;
    }
    ZNMARMethodParamFn getParam = (ZNMARMethodParamFn)ZNMARSymbol(imagePath, "il2cpp_method_get_param");
    ZNMARClassFromTypeFn fromType = (ZNMARClassFromTypeFn)ZNMARSymbol(imagePath, "il2cpp_class_from_type");
    if (!fromType) fromType = (ZNMARClassFromTypeFn)ZNMARSymbol(imagePath, "il2cpp_class_from_il2cpp_type");
    ZNMARClassValueSizeFn valueSize = (ZNMARClassValueSizeFn)ZNMARSymbol(imagePath, "il2cpp_class_value_size");
    if (!getParam || !fromType || !valueSize) {
        if (error) *error = @"FAILED_STRUCT_ABI：IL2CPP value-type metadata API 未导出";
        return nil;
    }
    const void *paramType = getParam((const void *)methodInfo, (uint32_t)index);
    void *klass = paramType ? fromType(paramType) : NULL;
    if (!klass) {
        if (error) *error = @"FAILED_STRUCT_ABI：无法获取参数类型 Class";
        return nil;
    }
    uint32_t alignment = 0;
    int32_t byteSize = valueSize(klass, &alignment);
    // Bounded allocation and conservative alignment guard.
    if (byteSize <= 0 || byteSize > 4096 || alignment == 0 || alignment > 16) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_STRUCT_LAYOUT：无效 size=%d align=%u", byteSize, alignment];
        return nil;
    }
    NSString *key = [self normalized:managedType];
    ZNRuntimeValueTypeEncoder encoder = nil;
    @synchronized(self) {
        encoder = [[self registry][key] copy];
    }
    NSString *localError = nil;
    NSData *payload = nil;
    if (encoder) {
        payload = encoder(text ?: @"", (NSUInteger)byteSize, &localError);
    } else if ([[self normalized:text].lowercaseString hasPrefix:@"hex:"]) {
        payload = [self decodeHex:text ?: @"" size:(NSUInteger)byteSize error:&localError];
    } else {
        payload = [self encodeUsingImplicitConversion:text ?: @""
                                               klass:klass
                                                size:(NSUInteger)byteSize
                                           imagePath:imagePath
                                               error:&localError];
        if (!payload && !localError) {
            localError = @"FAILED_CODEC_REQUIRED：未找到兼容的 static op_Implicit(primitive)；需要为该类型注册 Codec";
        }
    }
    if (!payload || payload.length != (NSUInteger)byteSize) {
        if (error) *error = localError ?: [NSString stringWithFormat:@"FAILED_STRUCT_SIZE：%@ Codec 输出与 IL2CPP 布局不匹配", key];
        return nil;
    }
    return [payload mutableCopy];
}

@end
