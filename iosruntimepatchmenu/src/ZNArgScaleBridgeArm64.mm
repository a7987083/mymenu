#import <Foundation/Foundation.h>
#import <stdint.h>

extern "C" void ZNArgScaleBridgeMutate(uint32_t index, uint64_t *savedGPRs);
extern "C" uintptr_t ZNArgScaleBridgeOriginal(uint32_t index);

#if defined(__arm64__) || defined(__aarch64__)

#define ZN_ARGSCALE_NAKED_BODY(SLOT) \
    __asm__ volatile( \
        "sub sp, sp, #208\n" \
        "stp x0, x1, [sp, #0]\n" \
        "stp x2, x3, [sp, #16]\n" \
        "stp x4, x5, [sp, #32]\n" \
        "stp x6, x7, [sp, #48]\n" \
        "stp x8, x30, [sp, #64]\n" \
        "stp q0, q1, [sp, #80]\n" \
        "stp q2, q3, [sp, #112]\n" \
        "stp q4, q5, [sp, #144]\n" \
        "stp q6, q7, [sp, #176]\n" \
        "mov x0, #" #SLOT "\n" \
        "mov x1, sp\n" \
        "bl _ZNArgScaleBridgeMutate\n" \
        "mov x0, #" #SLOT "\n" \
        "bl _ZNArgScaleBridgeOriginal\n" \
        "mov x16, x0\n" \
        "ldp q6, q7, [sp, #176]\n" \
        "ldp q4, q5, [sp, #144]\n" \
        "ldp q2, q3, [sp, #112]\n" \
        "ldp q0, q1, [sp, #80]\n" \
        "ldp x8, x30, [sp, #64]\n" \
        "ldp x6, x7, [sp, #48]\n" \
        "ldp x4, x5, [sp, #32]\n" \
        "ldp x2, x3, [sp, #16]\n" \
        "ldp x0, x1, [sp, #0]\n" \
        "add sp, sp, #208\n" \
        "br x16\n" \
    );

#define ZN_ARGSCALE_BRIDGE_SLOT(N) \
extern "C" __attribute__((naked,visibility("hidden"))) void ZNArgScaleBridgeSlot##N(void) { \
    ZN_ARGSCALE_NAKED_BODY(N) \
}

ZN_ARGSCALE_BRIDGE_SLOT(0)
ZN_ARGSCALE_BRIDGE_SLOT(1)
ZN_ARGSCALE_BRIDGE_SLOT(2)
ZN_ARGSCALE_BRIDGE_SLOT(3)
ZN_ARGSCALE_BRIDGE_SLOT(4)
ZN_ARGSCALE_BRIDGE_SLOT(5)
ZN_ARGSCALE_BRIDGE_SLOT(6)
ZN_ARGSCALE_BRIDGE_SLOT(7)
ZN_ARGSCALE_BRIDGE_SLOT(8)
ZN_ARGSCALE_BRIDGE_SLOT(9)
ZN_ARGSCALE_BRIDGE_SLOT(10)
ZN_ARGSCALE_BRIDGE_SLOT(11)
ZN_ARGSCALE_BRIDGE_SLOT(12)
ZN_ARGSCALE_BRIDGE_SLOT(13)
ZN_ARGSCALE_BRIDGE_SLOT(14)
ZN_ARGSCALE_BRIDGE_SLOT(15)

#endif
