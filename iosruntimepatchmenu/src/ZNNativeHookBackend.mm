#import "ZNNativeHookBackend.h"

@implementation ZNNativeHookBackend

+ (instancetype)sharedBackend {
    static ZNNativeHookBackend *backend;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ backend = [ZNNativeHookBackend new]; });
    return backend;
}

- (BOOL)installInstrumentAtAddress:(uintptr_t)address
                          callback:(ZNM47DobbyInstrumentCallback)callback
                             error:(NSString **)error {
    if (!address || !callback) {
        if (error) *error = @"Native Hook target/callback 为空";
        return NO;
    }
    int rc = DobbyInstrument((void *)address, callback);
    if (rc != 0) {
        if (error) *error = [NSString stringWithFormat:@"DobbyInstrument 失败 rc=%d target=0x%llX",
                             rc, (unsigned long long)address];
        return NO;
    }
    return YES;
}

- (BOOL)installReplacementAtAddress:(uintptr_t)address
                        replacement:(void *)replacement
                           original:(void **)original
                              error:(NSString **)error {
    if (!address || !replacement) {
        if (error) *error = @"Native Hook target/replacement 为空";
        return NO;
    }
    int rc = DobbyHook((void *)address, replacement, original);
    if (rc != 0) {
        if (error) *error = [NSString stringWithFormat:@"DobbyHook 失败 rc=%d target=0x%llX",
                             rc, (unsigned long long)address];
        return NO;
    }
    return YES;
}

- (BOOL)destroyHookAtAddress:(uintptr_t)address error:(NSString **)error {
    if (!address) return YES;
    int rc = DobbyDestroy((void *)address);
    if (rc != 0) {
        if (error) *error = [NSString stringWithFormat:@"DobbyDestroy 失败 rc=%d target=0x%llX",
                             rc, (unsigned long long)address];
        return NO;
    }
    return YES;
}

@end
