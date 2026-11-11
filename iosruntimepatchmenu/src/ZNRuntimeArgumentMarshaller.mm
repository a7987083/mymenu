#import "ZNRuntimeArgumentMarshaller.h"
#import <dlfcn.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <float.h>
#import <string.h>
#import <errno.h>
#import <ctype.h>
#import <stdlib.h>
#import <stdint.h>

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


typedef void *(*ZNMARClassGetFieldsFn)(void *, void **);
typedef const char *(*ZNMARFieldGetNameFn)(void *);
typedef const void *(*ZNMARFieldGetTypeFn)(void *);
typedef uint32_t (*ZNMARFieldGetFlagsFn)(void *);
typedef void (*ZNMARFieldSetValueFn)(void *, void *, void *);
typedef void *(*ZNMARValueBoxFn)(void *, void *);
typedef bool (*ZNMARClassIsValueTypeFn)(void *);
typedef char *(*ZNMARTypeGetNameFn)(const void *);
typedef void (*ZNMARFreeFn)(void *);

static BOOL ZNMARNumberText(id value, NSString **text) {
    if (![value isKindOfClass:NSString.class] && ![value isKindOfClass:NSNumber.class]) return NO;
    NSString *raw = [value description];
    if (![raw isKindOfClass:NSString.class] || !raw.length) return NO;
    *text = raw;
    return YES;
}

static BOOL ZNMARReadInteger(id value, BOOL signedValue, unsigned bits, uint64_t *result) {
    NSString *text = nil;
    if (!ZNMARNumberText(value, &text) || !bits || bits > 64) return NO;
    const char *p = text.UTF8String;
    if (!p || !*p || isspace((unsigned char)*p) || (!signedValue && *p == '-')) return NO;
    char *end = NULL; errno = 0;
    if (signedValue) {
        long long v = strtoll(p, &end, 10);
        if (errno || !end || *end || end == p) return NO;
        if (bits < 64) {
            int64_t lo = -(INT64_C(1) << (bits-1)), hi = (INT64_C(1) << (bits-1))-1;
            if (v < lo || v > hi) return NO;
        }
        *result = (uint64_t)v;
    } else {
        unsigned long long v = strtoull(p, &end, 10);
        if (errno || !end || *end || end == p) return NO;
        if (bits < 64 && v > ((UINT64_C(1)<<bits)-1)) return NO;
        *result = (uint64_t)v;
    }
    return YES;
}

static BOOL ZNMARFieldPrimitiveBytes(id value, int elementType,
                                     uint8_t bytes[8], size_t *length) {
    uint64_t n = 0;
    unsigned bits = 0;
    BOOL signedValue = NO;
    switch (elementType) {
        case 0x02: { // BOOLEAN: never accept arbitrary nonzero values.
            NSString *t = nil; if (!ZNMARNumberText(value,&t)) return NO;
            NSString *lower=t.lowercaseString;
            if (![lower isEqualToString:@"true"] && ![lower isEqualToString:@"false"] &&
                ![lower isEqualToString:@"1"] && ![lower isEqualToString:@"0"]) return NO;
            bytes[0] = ([lower isEqualToString:@"true"] || [lower isEqualToString:@"1"]) ? 1 : 0;
            *length=1; return YES;
        }
        case 0x04: signedValue=YES; bits=8; break;
        case 0x05: bits=8; break;
        case 0x03: case 0x07: bits=16; break;
        case 0x06: signedValue=YES; bits=16; break;
        case 0x08: signedValue=YES; bits=32; break;
        case 0x09: bits=32; break;
        case 0x0a: signedValue=YES; bits=64; break;
        case 0x0b: bits=64; break;
        case 0x0c: case 0x0d: {
            NSString *t=nil; if (!ZNMARNumberText(value,&t)) return NO;
            const char *p=t.UTF8String; if (!p || !*p || isspace((unsigned char)*p)) return NO;
            char *end=NULL; errno=0;
            double v=strtod(p,&end);
            if (errno || !end || *end || end==p || !isfinite(v)) return NO;
            if (elementType==0x0c) {
                if (fabs(v)>FLT_MAX) return NO;
                float f=(float)v; memcpy(bytes,&f,sizeof(f)); *length=sizeof(f);
            } else { memcpy(bytes,&v,sizeof(v)); *length=sizeof(v); }
            return YES;
        }
        default: return NO; // No nested structs, managed refs, pointers or enums.
    }
    if (!ZNMARReadInteger(value,signedValue,bits,&n)) return NO;
    *length=bits/8; memcpy(bytes,&n,*length);
    return YES;
}

// Delegate validated field writes to libil2cpp instead of guessing boxed
// field offsets, alignment or managed reference barriers.
static NSData *ZNMARMetadataJSONValueType(NSString *input, void *klass,
                                          NSUInteger size, NSString *imagePath,
                                          NSString **error) {
    NSData *json=[input dataUsingEncoding:NSUTF8StringEncoding];
    id parsed=json?[NSJSONSerialization JSONObjectWithData:json options:0 error:nil]:nil;
    if (![parsed isKindOfClass:NSDictionary.class]) {
        if(error)*error=@"FAILED_STRUCT_JSON：需要 JSON 对象，例如 {\"field\":1}";
        return nil;
    }
    NSDictionary *fieldsInput=(NSDictionary *)parsed;
    if (!fieldsInput.count || fieldsInput.count>64) {
        if(error)*error=@"FAILED_STRUCT_JSON：字段数量必须为 1~64";
        return nil;
    }
    ZNMARClassGetFieldsFn getFields=(ZNMARClassGetFieldsFn)ZNMARSymbol(imagePath,"il2cpp_class_get_fields");
    ZNMARFieldGetNameFn getName=(ZNMARFieldGetNameFn)ZNMARSymbol(imagePath,"il2cpp_field_get_name");
    ZNMARFieldGetTypeFn getType=(ZNMARFieldGetTypeFn)ZNMARSymbol(imagePath,"il2cpp_field_get_type");
    ZNMARFieldGetFlagsFn getFlags=(ZNMARFieldGetFlagsFn)ZNMARSymbol(imagePath,"il2cpp_field_get_flags");
    ZNMARTypeGetTypeFn typeCode=(ZNMARTypeGetTypeFn)ZNMARSymbol(imagePath,"il2cpp_type_get_type");
    ZNMARFieldSetValueFn setValue=(ZNMARFieldSetValueFn)ZNMARSymbol(imagePath,"il2cpp_field_set_value");
    ZNMARValueBoxFn box=(ZNMARValueBoxFn)ZNMARSymbol(imagePath,"il2cpp_value_box");
    ZNMARObjectUnboxFn unbox=(ZNMARObjectUnboxFn)ZNMARSymbol(imagePath,"il2cpp_object_unbox");
    if (!getFields||!getName||!getType||!getFlags||!typeCode||!setValue||!box||!unbox) {
        if(error)*error=@"FAILED_STRUCT_JSON_API：目标 Unity 缺少字段写入/装箱 API";
        return nil;
    }
    // Refuse partial/unknown fields. No field names or offsets are guessed.
    NSMutableArray<NSValue *> *instances=[NSMutableArray array];
    NSMutableSet<NSString *> *required=[NSMutableSet set];
    void *iter=NULL,*field=NULL;
    while ((field=getFields(klass,&iter))) {
        uint32_t flags=getFlags(field);
        if (flags & (0x10u | 0x40u)) continue; // static/literal
        if (flags & 0x20u) {
            if(error)*error=@"FAILED_STRUCT_READONLY：包含 initonly 实例字段，禁止通用字段写入";
            return nil;
        }
        const char *raw=getName(field);
        NSString *name=raw?[NSString stringWithUTF8String:raw]:nil;
        if (!name.length || [required containsObject:name] || required.count>=64) {
            if(error)*error=@"FAILED_STRUCT_FIELDS：实例字段信息不完整或重复";
            return nil;
        }
        [required addObject:name];
        [instances addObject:[NSValue valueWithPointer:field]];
    }
    NSSet *provided=[NSSet setWithArray:fieldsInput.allKeys];
    if (!required.count || ![provided isEqualToSet:required]) {
        NSMutableSet *missing=[required mutableCopy];[missing minusSet:provided];
        NSMutableSet *extra=[provided mutableCopy];[extra minusSet:required];
        if(error)*error=[NSString stringWithFormat:
            @"FAILED_STRUCT_FIELDS：必须完整提供所有实例字段；缺少=%@，未知=%@；字段=%@",
            missing.allObjects,extra.allObjects,required.allObjects];
        return nil;
    }
    // Validate ALL fields before allocating or mutating any managed object.
    NSMutableArray<NSData *> *encoded=[NSMutableArray arrayWithCapacity:instances.count];
    for (NSValue *item in instances) {
        void *f=item.pointerValue;
        NSString *name=[NSString stringWithUTF8String:getName(f)];
        const void *type=getType(f);
        uint8_t bytes[8]={0};size_t length=0;
        if (!type || !ZNMARFieldPrimitiveBytes(fieldsInput[name],typeCode(type),bytes,&length)) {
            if(error)*error=[NSString stringWithFormat:
                @"FAILED_STRUCT_FIELD_TYPE：字段 %@ 必须是受支持的基础数值类型且输入有效（不接受对象/嵌套 struct）",name];
            return nil;
        }
        [encoded addObject:[NSData dataWithBytes:bytes length:length]];
    }
    NSMutableData *zero=[NSMutableData dataWithLength:size];
    void *boxed=box(klass,zero.mutableBytes);
    if (!boxed) {if(error)*error=@"FAILED_STRUCT_BOX：IL2CPP value_box 失败";return nil;}
    for(NSUInteger i=0;i<instances.count;i++) {
        // libil2cpp handles the correct boxed value-type field offsets.
        setValue(boxed,instances[i].pointerValue,(void *)encoded[i].bytes);
    }
    void *raw=unbox(boxed);
    if (!raw) {if(error)*error=@"FAILED_STRUCT_UNBOX：IL2CPP object_unbox 失败";return nil;}
    return [NSData dataWithBytes:raw length:size];
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
    if ([[self normalized:text].lowercaseString isEqualToString:@"fields"]) {
        ZNMARClassGetFieldsFn fields=(ZNMARClassGetFieldsFn)ZNMARSymbol(imagePath,"il2cpp_class_get_fields");
        ZNMARFieldGetNameFn name=(ZNMARFieldGetNameFn)ZNMARSymbol(imagePath,"il2cpp_field_get_name");
        ZNMARFieldGetFlagsFn flags=(ZNMARFieldGetFlagsFn)ZNMARSymbol(imagePath,"il2cpp_field_get_flags");
        if (!fields || !name || !flags) {
            if (error) *error=@"FAILED_STRUCT_FIELDS_API：字段元数据 API 不可用";
            return nil;
        }
        NSMutableArray<NSString *> *items=[NSMutableArray array];
        void *it=NULL,*field=NULL;
        while((field=fields(klass,&it))) {
            if (flags(field)&(0x10u|0x40u)) continue;
            const char *raw=name(field);
            if (!raw || items.count>=64) {
                if(error)*error=@"FAILED_STRUCT_FIELDS：字段元数据不完整或数量超限";
                return nil;
            }
            NSString *value=[NSString stringWithUTF8String:raw];
            if (!value.length) {if(error)*error=@"FAILED_STRUCT_FIELDS：字段名无效";return nil;}
            [items addObject:value];
        }
        if (error) *error=[NSString stringWithFormat:@"BYREF_FIELDS %@ (%d bytes)：%@；输入完整 JSON 对象",
                            key,byteSize,[items componentsJoinedByString:@", "]];
        return nil;
    }
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
    } else if ([[self normalized:text] hasPrefix:@"{"]) {
        payload = ZNMARMetadataJSONValueType(text ?: @"",klass,(NSUInteger)byteSize,imagePath,&localError);
    } else {
        payload = [self encodeUsingImplicitConversion:text ?: @""
                                               klass:klass
                                                size:(NSUInteger)byteSize
                                           imagePath:imagePath
                                               error:&localError];
        if (!payload && !localError) {
            localError = @"FAILED_CODEC_REQUIRED：此值类型不支持单个数值输入。请先输入 fields 查看真实字段，再提供完整 JSON 对象；或使用已验证的 Codec / hex:";
        }
    }
    if (!payload || payload.length != (NSUInteger)byteSize) {
        if (error) *error = localError ?: [NSString stringWithFormat:@"FAILED_STRUCT_SIZE：%@ Codec 输出与 IL2CPP 布局不匹配", key];
        return nil;
    }
    return [payload mutableCopy];
}


// Only for an explicit out value-type slot; never use a guessed struct size.
+ (nullable NSMutableData *)zeroInitializedByRefValueTypeForMethod:(uintptr_t)methodInfo
                                                            index:(NSUInteger)index
                                                        imagePath:(NSString *)imagePath
                                                            error:(NSString **)error {
    if (!methodInfo || index > UINT32_MAX) {
        if (error) *error = @"FAILED_BYREF_ABI：MethodInfo/参数序号无效";
        return nil;
    }
    ZNMARMethodParamFn getParam = (ZNMARMethodParamFn)ZNMARSymbol(imagePath, "il2cpp_method_get_param");
    ZNMARClassFromTypeFn fromType = (ZNMARClassFromTypeFn)ZNMARSymbol(imagePath, "il2cpp_class_from_type");
    if (!fromType) fromType = (ZNMARClassFromTypeFn)ZNMARSymbol(imagePath, "il2cpp_class_from_il2cpp_type");
    ZNMARClassValueSizeFn valueSize = (ZNMARClassValueSizeFn)ZNMARSymbol(imagePath, "il2cpp_class_value_size");
    typedef bool (*ClassIsValueTypeFn)(void *);
    ClassIsValueTypeFn isValue = (ClassIsValueTypeFn)ZNMARSymbol(imagePath, "il2cpp_class_is_valuetype");
    if (!getParam || !fromType || !valueSize || !isValue) {
        if (error) *error = @"FAILED_BYREF_ABI：缺少 IL2CPP 元数据 API";
        return nil;
    }
    const void *type = getParam((const void *)methodInfo, (uint32_t)index);
    void *klass = type ? fromType(type) : NULL;
    if (!klass || !isValue(klass)) {
        if (error) *error = @"FAILED_BYREF_ABI：目标不是可验证的值类型";
        return nil;
    }
    uint32_t alignment = 0;
    int32_t size = valueSize(klass, &alignment);
    if (size <= 0 || size > 4096 || !alignment || alignment > 16) {
        if (error) *error = [NSString stringWithFormat:@"FAILED_BYREF_LAYOUT：size=%d align=%u",size,alignment];
        return nil;
    }
    if (error) *error = nil;
    return [NSMutableData dataWithLength:(NSUInteger)size];
}

@end
