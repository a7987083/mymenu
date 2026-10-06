#import "ZNValueTypeModel.h"
#include <math.h>
#include <stdint.h>
#include <float.h>

NSString *ZNValueTypeName(ZNValueType type) {
    switch (type) {
        case ZNValueTypeI32: return @"I32";
        case ZNValueTypeU32: return @"U32";
        case ZNValueTypeI64: return @"I64";
        case ZNValueTypeU64: return @"U64";
        case ZNValueTypeF32: return @"F32";
        case ZNValueTypeF64: return @"F64";
        case ZNValueTypeAuto:
        default: return @"Auto";
    }
}
NSString *ZNValueTypeKey(ZNValueType type) { return ZNValueTypeName(type).lowercaseString; }
ZNValueType ZNValueTypeFromKey(NSString *key) {
    NSString *k = [key.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([k isEqualToString:@"i32"]) return ZNValueTypeI32;
    if ([k isEqualToString:@"u32"]) return ZNValueTypeU32;
    if ([k isEqualToString:@"i64"]) return ZNValueTypeI64;
    if ([k isEqualToString:@"u64"]) return ZNValueTypeU64;
    if ([k isEqualToString:@"f32"]) return ZNValueTypeF32;
    if ([k isEqualToString:@"f64"]) return ZNValueTypeF64;
    return ZNValueTypeAuto;
}
BOOL ZNValueTypeIsInteger(ZNValueType type) { return type >= ZNValueTypeI32 && type <= ZNValueTypeU64; }
BOOL ZNValueTypeIsFloating(ZNValueType type) { return type == ZNValueTypeF32 || type == ZNValueTypeF64; }
ZNValueType ZNValueTypeForManagedTypeName(NSString *managedType) {
    NSString *t = [[managedType ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if ([t isEqualToString:@"system.int32"] || [t isEqualToString:@"int"] || [t isEqualToString:@"int32"]) return ZNValueTypeI32;
    if ([t isEqualToString:@"system.uint32"] || [t isEqualToString:@"uint"] || [t isEqualToString:@"uint32"]) return ZNValueTypeU32;
    if ([t isEqualToString:@"system.int64"] || [t isEqualToString:@"long"] || [t isEqualToString:@"int64"]) return ZNValueTypeI64;
    if ([t isEqualToString:@"system.uint64"] || [t isEqualToString:@"ulong"] || [t isEqualToString:@"uint64"]) return ZNValueTypeU64;
    if ([t isEqualToString:@"system.single"] || [t isEqualToString:@"single"] || [t isEqualToString:@"float"]) return ZNValueTypeF32;
    if ([t isEqualToString:@"system.double"] || [t isEqualToString:@"double"]) return ZNValueTypeF64;
    return ZNValueTypeAuto;
}
NSDictionary<NSString *, NSNumber *> *ZNDefaultRangeForValueType(ZNValueType type, BOOL slider) {
    if (slider) return @{@"default": @1, @"min": @1, @"max": @10, @"step": @1};
    switch (type) {
        case ZNValueTypeI32: return @{@"default": @1, @"min": @(INT32_MIN), @"max": @(INT32_MAX), @"step": @1};
        case ZNValueTypeU32: return @{@"default": @1, @"min": @0, @"max": @((uint64_t)UINT32_MAX), @"step": @1};
        case ZNValueTypeI64: return @{@"default": @1, @"min": @((long long)INT64_MIN), @"max": @((long long)INT64_MAX), @"step": @1};
        case ZNValueTypeU64: return @{@"default": @1, @"min": @0, @"max": @((unsigned long long)UINT64_MAX), @"step": @1};
        case ZNValueTypeF32: return @{@"default": @1, @"min": @(-FLT_MAX), @"max": @(FLT_MAX), @"step": @1};
        case ZNValueTypeF64: return @{@"default": @1, @"min": @(-DBL_MAX), @"max": @(DBL_MAX), @"step": @1};
        case ZNValueTypeAuto:
        default: return @{@"default": @1, @"min": @0, @"max": @(INT32_MAX), @"step": @1};
    }
}
static BOOL ZNParseSigned(NSString *text, long long *value) {
    NSScanner *s = [NSScanner scannerWithString:text ?: @""]; long long v = 0;
    if (![s scanLongLong:&v] || !s.isAtEnd) return NO; if (value) *value = v; return YES;
}
static BOOL ZNParseUnsigned(NSString *text, unsigned long long *value) {
    NSString *trim = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trim hasPrefix:@"-"] || !trim.length) return NO;
    NSScanner *s = [NSScanner scannerWithString:trim]; unsigned long long v = 0;
    if (![s scanUnsignedLongLong:&v] || !s.isAtEnd) return NO; if (value) *value = v; return YES;
}
NSString *ZNCanonicalValueString(NSString *input, ZNValueType type, NSNumber *minValue, NSNumber *maxValue, NSNumber *stepValue, NSString **error) {
    NSString *text = [input ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) { if (error) *error = @"数值为空"; return nil; }
    if (type == ZNValueTypeI32 || type == ZNValueTypeI64) {
        long long v = 0; if (!ZNParseSigned(text, &v)) { if (error) *error = @"不是有效有符号整数"; return nil; }
        long long lo = type == ZNValueTypeI32 ? INT32_MIN : INT64_MIN;
        long long hi = type == ZNValueTypeI32 ? INT32_MAX : INT64_MAX;
        if (minValue) lo = MAX(lo, minValue.longLongValue); if (maxValue) hi = MIN(hi, maxValue.longLongValue);
        if (v < lo || v > hi) { if (error) *error = [NSString stringWithFormat:@"超出 %@ 范围", ZNValueTypeName(type)]; return nil; }
        long long step = MAX(1LL, stepValue.longLongValue); if (step > 1) v = lo + llround((double)(v - lo) / (double)step) * step;
        return [NSString stringWithFormat:@"%lld", v];
    }
    if (type == ZNValueTypeU32 || type == ZNValueTypeU64) {
        unsigned long long v = 0; if (!ZNParseUnsigned(text, &v)) { if (error) *error = @"不是有效无符号整数"; return nil; }
        unsigned long long hi = type == ZNValueTypeU32 ? UINT32_MAX : UINT64_MAX;
        unsigned long long lo = minValue ? minValue.unsignedLongLongValue : 0; if (maxValue) hi = MIN(hi, maxValue.unsignedLongLongValue);
        if (v < lo || v > hi) { if (error) *error = [NSString stringWithFormat:@"超出 %@ 范围", ZNValueTypeName(type)]; return nil; }
        unsigned long long step = MAX(1ULL, stepValue.unsignedLongLongValue); if (step > 1) v = lo + ((v - lo + step / 2) / step) * step;
        return [NSString stringWithFormat:@"%llu", v];
    }
    NSScanner *scanner = [NSScanner scannerWithString:text]; double v = 0.0;
    if (![scanner scanDouble:&v] || !scanner.isAtEnd || !isfinite(v)) { if (error) *error = @"不是有效浮点数"; return nil; }
    double lo = minValue ? minValue.doubleValue : -DBL_MAX, hi = maxValue ? maxValue.doubleValue : DBL_MAX;
    if (v < lo || v > hi) { if (error) *error = [NSString stringWithFormat:@"超出 %@ 范围", ZNValueTypeName(type)]; return nil; }
    double step = stepValue.doubleValue; if (step > 0 && isfinite(step)) v = lo + round((v - lo) / step) * step;
    return type == ZNValueTypeF32 ? [NSString stringWithFormat:@"%.9g", (float)v] : [NSString stringWithFormat:@"%.17g", v];
}
