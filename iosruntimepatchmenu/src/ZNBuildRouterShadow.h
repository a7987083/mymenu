#pragma once
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, ZNShadowBuildMode) {
    ZNShadowBuildModeEmpty = 0,
    ZNShadowBuildModeRuntimeOnly,
    ZNShadowBuildModeStaticOnly,
    ZNShadowBuildModeMixed,
    ZNShadowBuildModeInvalid,
};

FOUNDATION_EXPORT ZNShadowBuildMode ZNShadowBuildModeForCounts(NSUInteger completeStaticRows,
                                                               NSUInteger partialStaticRows,
                                                               NSUInteger runtimeActionCount,
                                                               NSUInteger nativeHookCount);
FOUNDATION_EXPORT NSString *ZNShadowBuildModeName(ZNShadowBuildMode mode);
