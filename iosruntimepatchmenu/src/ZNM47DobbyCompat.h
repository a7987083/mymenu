#pragma once

#include <stdint.h>

// Narrow ABI shim for the two Dobby entry points M4.7 consumes.
// The upstream pinned dobby.h wraps system headers inside extern "C"; modern
// AppleClang modules reject that include pattern in Objective-C++. Keep the
// pinned library and expose only the stable C ABI we actually use here.
//
// DobbyInstrument passes a pointer to its full arm64 DobbyRegisterContext. We
// only read x0, so this prefix intentionally mirrors the layout through the
// general-register block. x0 is at byte offset 24 in the pinned Dobby ABI.
typedef struct {
    uint64_t dummy0;
    uint64_t sp;
    uint64_t dummy1;
    union {
        uint64_t x[29];
        struct {
            uint64_t x0, x1, x2, x3, x4, x5, x6, x7, x8, x9,
                     x10, x11, x12, x13, x14, x15, x16, x17, x18, x19,
                     x20, x21, x22, x23, x24, x25, x26, x27, x28;
        } regs;
    } general;
} ZNM47DobbyRegisterContextPrefix;

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*ZNM47DobbyInstrumentCallback)(void *address,
                                              ZNM47DobbyRegisterContextPrefix *context);
int DobbyInstrument(void *address, ZNM47DobbyInstrumentCallback pre_handler);
int DobbyHook(void *address, void *fake_func, void **out_origin_func);
int DobbyDestroy(void *address);

#ifdef __cplusplus
}
#endif
