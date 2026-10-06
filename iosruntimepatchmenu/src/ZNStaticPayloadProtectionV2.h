#pragma once

#include <stdint.h>
#include <stddef.h>

// Protection V2 is a build-time polymorphic layout layer. It is deliberately
// not presented as cryptography: the CPU must still execute the generated
// instructions. The goal is to prevent a whole ON/OFF variant from being
// stored as one predictable contiguous instruction sequence.
#define ZN60_PAYLOAD_SLOT_SIZE UINT64_C(16)
#define ZN60_PAYLOAD_VARIANT_PAD UINT64_C(64)
#define ZN60_PAYLOAD_THUNK_STRIDE UINT64_C(48)

static inline uint64_t ZN60Mix64(uint64_t x) {
    x ^= x >> 30;
    x *= UINT64_C(0xBF58476D1CE4E5B9);
    x ^= x >> 27;
    x *= UINT64_C(0x94D049BB133111EB);
    x ^= x >> 31;
    return x;
}

static inline uint64_t ZN60DeriveLayoutState(uint64_t nonce,
                                              uint64_t siteRVA,
                                              uint32_t variantOrdinal) {
    uint64_t x = nonce ^ ZN60Mix64(siteRVA + UINT64_C(0x9E3779B97F4A7C15));
    x ^= ZN60Mix64(((uint64_t)variantOrdinal << 32) | (uint64_t)(variantOrdinal ^ 0xA5A55A5Au));
    x = ZN60Mix64(x);
    return x ? x : UINT64_C(0xD1B54A32D192ED03);
}

static inline uint64_t ZN60NextLayoutWord(uint64_t *state) {
    uint64_t x = state ? *state : 0;
    if (!x) x = UINT64_C(0xD1B54A32D192ED03);
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    if (state) *state = x;
    return x * UINT64_C(0x2545F4914F6CDD1D);
}

static inline uint64_t ZN60VariantReservedBytes(uint64_t sourceLength) {
    if (!sourceLength || (sourceLength & UINT64_C(3))) return 0;
    return (sourceLength / UINT64_C(4)) * ZN60_PAYLOAD_SLOT_SIZE;
}

static inline uint64_t ZN60VariantStrideBytes(uint64_t sourceLength) {
    uint64_t payload = ZN60VariantReservedBytes(sourceLength);
    return payload ? payload + ZN60_PAYLOAD_VARIANT_PAD : 0;
}

static inline void ZN60ShuffleU32(uint32_t *values, size_t count, uint64_t state) {
    if (!values || count < 2) return;
    for (size_t i = count - 1; i > 0; --i) {
        uint64_t r = ZN60NextLayoutWord(&state);
        size_t j = (size_t)(r % (uint64_t)(i + 1));
        uint32_t tmp = values[i];
        values[i] = values[j];
        values[j] = tmp;
    }
}

static inline int ZN60IsPermutationU32(const uint32_t *values, size_t count) {
    if (!values && count) return 0;
    for (size_t i = 0; i < count; ++i) {
        if ((size_t)values[i] >= count) return 0;
        for (size_t j = i + 1; j < count; ++j) {
            if (values[i] == values[j]) return 0;
        }
    }
    return 1;
}
