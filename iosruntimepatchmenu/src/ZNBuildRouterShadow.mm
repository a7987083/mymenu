#import "ZNBuildRouterShadow.h"

ZNShadowBuildMode ZNShadowBuildModeForCounts(NSUInteger completeStaticRows,
                                              NSUInteger partialStaticRows,
                                              NSUInteger runtimeActionCount,
                                              NSUInteger nativeHookCount) {
    BOOL hasRuntimeOwned = runtimeActionCount > 0 || nativeHookCount > 0;
    BOOL hasStatic = completeStaticRows > 0;

    if (hasRuntimeOwned && !hasStatic) {
        // Keep current runtime-only semantics: incomplete Static drafts are ignored.
        return ZNShadowBuildModeRuntimeOnly;
    }
    if (hasRuntimeOwned && hasStatic) return ZNShadowBuildModeMixed;
    if (hasStatic && partialStaticRows == 0) return ZNShadowBuildModeStaticOnly;
    if (hasStatic || partialStaticRows > 0) return ZNShadowBuildModeInvalid;
    return ZNShadowBuildModeEmpty;
}

NSString *ZNShadowBuildModeName(ZNShadowBuildMode mode) {
    switch (mode) {
        case ZNShadowBuildModeRuntimeOnly: return @"runtime-only";
        case ZNShadowBuildModeStaticOnly: return @"static-only";
        case ZNShadowBuildModeMixed: return @"mixed";
        case ZNShadowBuildModeInvalid: return @"invalid";
        case ZNShadowBuildModeEmpty:
        default: return @"empty";
    }
}
