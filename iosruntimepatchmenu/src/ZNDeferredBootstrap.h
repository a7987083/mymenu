#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Cold means only the launcher exists. Loading/Ready are entered exclusively
// by the first launcher tap; feature/runtime modules must not initialize before it.
FOUNDATION_EXPORT BOOL ZNDeferredBootstrapIsActivated(void)
    __attribute__((visibility("hidden")));
FOUNDATION_EXPORT BOOL ZNDeferredBootstrapIsReady(void)
    __attribute__((visibility("hidden")));

#ifdef __cplusplus
}
#endif
