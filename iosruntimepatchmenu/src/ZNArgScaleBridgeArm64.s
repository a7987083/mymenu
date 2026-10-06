.text
.align 2

// Generic ArgScaleInt32 bridge.
// Preserve all AAPCS64 argument/result-carrier registers that may be live at
// function entry: x0-x8, q0-q7 and caller LR. The C++ helper mutates only
// one saved GPR. We then restore the untouched call state and tail-branch to
// Dobby's relocated original trampoline, so no native C prototype is guessed.
//
// frame layout (208 bytes, 16-byte aligned):
//   +0   x0,x1
//   +16  x2,x3
//   +32  x4,x5
//   +48  x6,x7
//   +64  x8,x30
//   +80  q0,q1
//   +112 q2,q3
//   +144 q4,q5
//   +176 q6,q7

.macro ZN_ARGSCALE_BRIDGE slot
.globl _ZNArgScaleBridgeSlot\slot
.private_extern _ZNArgScaleBridgeSlot\slot
_ZNArgScaleBridgeSlot\slot:
    sub sp, sp, #208
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x30, [sp, #64]
    stp q0, q1, [sp, #80]
    stp q2, q3, [sp, #112]
    stp q4, q5, [sp, #144]
    stp q6, q7, [sp, #176]

    mov x0, #\slot
    mov x1, sp
    bl _ZNArgScaleBridgeMutate

    mov x0, #\slot
    bl _ZNArgScaleBridgeOriginal
    mov x16, x0

    ldp q6, q7, [sp, #176]
    ldp q4, q5, [sp, #144]
    ldp q2, q3, [sp, #112]
    ldp q0, q1, [sp, #80]
    ldp x8, x30, [sp, #64]
    ldp x6, x7, [sp, #48]
    ldp x4, x5, [sp, #32]
    ldp x2, x3, [sp, #16]
    ldp x0, x1, [sp, #0]
    add sp, sp, #208
    br x16
.endm

ZN_ARGSCALE_BRIDGE 0
ZN_ARGSCALE_BRIDGE 1
ZN_ARGSCALE_BRIDGE 2
ZN_ARGSCALE_BRIDGE 3
ZN_ARGSCALE_BRIDGE 4
ZN_ARGSCALE_BRIDGE 5
ZN_ARGSCALE_BRIDGE 6
ZN_ARGSCALE_BRIDGE 7
ZN_ARGSCALE_BRIDGE 8
ZN_ARGSCALE_BRIDGE 9
ZN_ARGSCALE_BRIDGE 10
ZN_ARGSCALE_BRIDGE 11
ZN_ARGSCALE_BRIDGE 12
ZN_ARGSCALE_BRIDGE 13
ZN_ARGSCALE_BRIDGE 14
ZN_ARGSCALE_BRIDGE 15
