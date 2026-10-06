#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include "ZNStaticPayloadProtectionV2.h"

static void require_true(int value, const char *message) {
    if (!value) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

int main(void) {
    require_true(ZN60VariantReservedBytes(0) == 0, "zero length rejected");
    require_true(ZN60VariantReservedBytes(3) == 0, "unaligned length rejected");
    require_true(ZN60VariantReservedBytes(4) == 16, "one instruction gets one slot");
    require_true(ZN60VariantReservedBytes(16) == 64, "four instructions get four slots");
    require_true(ZN60VariantStrideBytes(16) == 128, "variant stride includes randomized pad budget");

    uint32_t a[8];
    uint32_t b[8];
    uint32_t c[8];
    for (uint32_t i = 0; i < 8; ++i) a[i] = b[i] = c[i] = i;

    uint64_t s1 = ZN60DeriveLayoutState(UINT64_C(0x1122334455667788), UINT64_C(0x2E25904), 1);
    uint64_t s2 = ZN60DeriveLayoutState(UINT64_C(0x1122334455667788), UINT64_C(0x2E25904), 1);
    uint64_t s3 = ZN60DeriveLayoutState(UINT64_C(0x8877665544332211), UINT64_C(0x2E25904), 1);
    ZN60ShuffleU32(a, 8, s1);
    ZN60ShuffleU32(b, 8, s2);
    ZN60ShuffleU32(c, 8, s3);

    require_true(ZN60IsPermutationU32(a, 8), "shuffle keeps a permutation");
    require_true(ZN60IsPermutationU32(c, 8), "different nonce keeps a permutation");

    int sameAB = 1;
    int sameAC = 1;
    for (size_t i = 0; i < 8; ++i) {
        if (a[i] != b[i]) sameAB = 0;
        if (a[i] != c[i]) sameAC = 0;
    }
    require_true(sameAB, "same nonce/site/ordinal is deterministic");
    require_true(!sameAC, "different nonce changes layout");

    uint64_t siteA = ZN60DeriveLayoutState(UINT64_C(0xAABBCCDDEEFF0011), UINT64_C(0x2DA9DE0), 2);
    uint64_t siteB = ZN60DeriveLayoutState(UINT64_C(0xAABBCCDDEEFF0011), UINT64_C(0x2DAB154), 2);
    require_true(siteA != siteB, "site RVA contributes to layout state");

    puts("static_payload_protection_v2_test: PASS");
    return 0;
}
