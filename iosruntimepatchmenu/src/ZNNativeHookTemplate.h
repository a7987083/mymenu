#pragma once

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <limits.h>

typedef NS_ENUM(uint32_t, ZNNativeHookTemplateKind) {
    ZNNativeHookTemplateInvalid = 0,
    ZNNativeHookTemplateArgScaleInt32 = 1,
    ZNNativeHookTemplateManagedCallbackShortCircuit = 2,
    ZNNativeHookTemplateReturnBoolOverride = 3,
    ZNNativeHookTemplateStructFieldTransform = 4, // legacy offset-based codec
    ZNNativeHookTemplateComplexStructTransform = 5, // whole struct decode/transform/encode
};

static inline NSString *ZNNativeHookTemplateKey(ZNNativeHookTemplateKind kind) {
    switch (kind) {
        case ZNNativeHookTemplateArgScaleInt32: return @"arg-scale-int32";
        case ZNNativeHookTemplateManagedCallbackShortCircuit: return @"managed-callback-short-circuit";
        case ZNNativeHookTemplateReturnBoolOverride: return @"return-bool-override";
        case ZNNativeHookTemplateStructFieldTransform: return @"struct-field-transform";
        case ZNNativeHookTemplateComplexStructTransform: return @"complex-struct-transform";
        default: return @"invalid";
    }
}

static inline BOOL ZNNativeHookArgRegisterIndex(BOOL isStatic,
                                                NSUInteger argumentIndex,
                                                NSUInteger argumentCount,
                                                uint32_t *outRegisterIndex) {
    if (argumentIndex >= argumentCount) return NO;
    NSUInteger reg = (isStatic ? 0u : 1u) + argumentIndex;
    if (reg >= 8u) return NO;
    if (outRegisterIndex) *outRegisterIndex = (uint32_t)reg;
    return YES;
}

static inline int32_t ZNNativeHookScaleInt32(int32_t value, int32_t multiplier) {
    int64_t scaled = (int64_t)value * (int64_t)multiplier;
    if (scaled > INT32_MAX) return INT32_MAX;
    if (scaled < INT32_MIN) return INT32_MIN;
    return (int32_t)scaled;
}


static inline int64_t ZNNativeHookScaleInt64(int64_t value, int32_t multiplier) {
    __int128 scaled = (__int128)value * (__int128)multiplier;
    if (scaled > INT64_MAX) return INT64_MAX;
    if (scaled < INT64_MIN) return INT64_MIN;
    return (int64_t)scaled;
}
