#pragma once

#import <Foundation/Foundation.h>
#import "ZNStaticPatchFormat.h"

// Static RVA Protection V1.
//
// This is a static-analysis cost layer, not a claim of client-side secrecy.
// The generated Mach-O no longer stores siteRVA/offRVA/onRVA as directly
// readable integers. Runtime decodes them on demand without writing plaintext
// values back into the Static Entry.

typedef struct {
    uint64_t offRVA;
    uint64_t onRVA;
    uint64_t siteRVA;
} ZN55DecodedRVAs;

static inline uint64_t ZN55RotL64(uint64_t x, unsigned r) {
    r &= 63u;
    return r ? ((x << r) | (x >> (64u - r))) : x;
}

static inline uint64_t ZN55RotR64(uint64_t x, unsigned r) {
    r &= 63u;
    return r ? ((x >> r) | (x << (64u - r))) : x;
}

static inline uint64_t ZN55Mix64(uint64_t x) {
    x ^= x >> 30;
    x *= UINT64_C(0xBF58476D1CE4E5B9);
    x ^= x >> 27;
    x *= UINT64_C(0x94D049BB133111EB);
    x ^= x >> 31;
    return x;
}

static inline uint64_t ZN55MarkerForHeader(const ZN44StaticHeader *header) {
    if (!header) return 0;
    return ZN55Mix64(header->reserved[0] ^
                     ((uint64_t)header->count << 32) ^
                     (uint64_t)header->entrySize ^
                     UINT64_C(0xD62A7F4B91E5C803));
}

static inline uint64_t ZN55EntryKey(const ZN44StaticHeader *header,
                                    const ZN44StaticEntry *entry,
                                    uint32_t entryIndex,
                                    uint32_t lane) {
    uint64_t x = header->reserved[0] ^ UINT64_C(0x73A51D9C42E6B80F);
    x ^= ((uint64_t)entryIndex + 1u) * UINT64_C(0x9E3779B97F4A7C15);
    x ^= ((uint64_t)lane + 1u) * UINT64_C(0xD1B54A32D192ED03);
    x ^= ((uint64_t)entry->patchID << 32) | (uint64_t)entry->physicalID;
    x ^= ((uint64_t)entry->canonicalIndex << 32) | (uint64_t)entry->flags;
    x ^= ((uint64_t)entry->windowLength << 32) | (uint64_t)entry->enabledLength;
    return ZN55Mix64(x);
}

static inline uint64_t ZN55EncodeRVAValue(const ZN44StaticHeader *header,
                                          const ZN44StaticEntry *entry,
                                          uint32_t entryIndex,
                                          uint32_t lane,
                                          uint64_t plain) {
    uint64_t key = ZN55EntryKey(header, entry, entryIndex, lane);
    uint64_t add = ZN55Mix64(key ^ UINT64_C(0xA0761D6478BD642F));
    unsigned rotation = 11u + (unsigned)((key >> 59) & 31u);
    uint64_t cross = ZN55Mix64(header->reserved[0] ^
                               ((uint64_t)entry->patchID << 17) ^
                               ((uint64_t)lane << 49));
    return ZN55RotL64(plain ^ key ^ cross, rotation) + add;
}

static inline uint64_t ZN55DecodeRVAValue(const ZN44StaticHeader *header,
                                          const ZN44StaticEntry *entry,
                                          uint32_t entryIndex,
                                          uint32_t lane,
                                          uint64_t encoded) {
    uint64_t key = ZN55EntryKey(header, entry, entryIndex, lane);
    uint64_t add = ZN55Mix64(key ^ UINT64_C(0xA0761D6478BD642F));
    unsigned rotation = 11u + (unsigned)((key >> 59) & 31u);
    uint64_t cross = ZN55Mix64(header->reserved[0] ^
                               ((uint64_t)entry->patchID << 17) ^
                               ((uint64_t)lane << 49));
    return ZN55RotR64(encoded - add, rotation) ^ key ^ cross;
}

static inline BOOL ZN55DecodeEntryRVAs(const ZN44StaticHeader *header,
                                       const ZN44StaticEntry *entry,
                                       uint32_t entryIndex,
                                       ZN55DecodedRVAs *outRVAs) {
    if (!header || !entry || !outRVAs) return NO;
    if (!(header->flags & ZN44_STATIC_HEADER_FLAG_RVA_PROTECTION_V1)) {
        outRVAs->offRVA = entry->offRVA;
        outRVAs->onRVA = entry->onRVA;
        outRVAs->siteRVA = entry->siteRVA;
        return YES;
    }
    if (!header->reserved[0] || header->reserved[2] != ZN55MarkerForHeader(header)) return NO;
    outRVAs->offRVA = ZN55DecodeRVAValue(header, entry, entryIndex, 0u, entry->offRVA);
    outRVAs->onRVA = ZN55DecodeRVAValue(header, entry, entryIndex, 1u, entry->onRVA);
    outRVAs->siteRVA = ZN55DecodeRVAValue(header, entry, entryIndex, 2u, entry->siteRVA);
    return YES;
}

static inline uint64_t ZN55TagStep(uint64_t state, uint64_t value, uint64_t domain) {
    state ^= ZN55Mix64(value ^ domain ^ state);
    state = ZN55RotL64(state, 23u);
    state *= UINT64_C(0x9FB21C651E98DF25);
    return state;
}

static inline BOOL ZN55PlaintextTag(const ZN44StaticHeader *header,
                                    const ZN44StaticEntry *entries,
                                    uint64_t *outTag) {
    if (!header || !entries || !outTag || !header->count) return NO;
    uint64_t state = ZN55Mix64(header->reserved[0] ^ UINT64_C(0xC3A5C85C97CB3127));
    for (uint32_t i = 0; i < header->count; i++) {
        ZN55DecodedRVAs rvas = {};
        if (!ZN55DecodeEntryRVAs(header, &entries[i], i, &rvas)) return NO;
        state = ZN55TagStep(state, rvas.offRVA, UINT64_C(0x01F0F0F0F0F0F0F0) ^ i);
        state = ZN55TagStep(state, rvas.onRVA,  UINT64_C(0x02E1E1E1E1E1E1E1) ^ i);
        state = ZN55TagStep(state, rvas.siteRVA,UINT64_C(0x03D2D2D2D2D2D2D2) ^ i);
        state = ZN55TagStep(state,
                            ((uint64_t)entries[i].patchID << 32) | entries[i].physicalID,
                            UINT64_C(0x04C3C3C3C3C3C3C3) ^ i);
    }
    *outTag = ZN55Mix64(state ^ ((uint64_t)header->count << 32) ^ header->entrySize);
    return YES;
}

static inline BOOL ZN55ValidateProtectedHeader(const ZN44StaticHeader *header,
                                               const ZN44StaticEntry *entries) {
    if (!header || !entries) return NO;
    if (!(header->flags & ZN44_STATIC_HEADER_FLAG_RVA_PROTECTION_V1)) return YES;
    if (!header->reserved[0] || header->reserved[2] != ZN55MarkerForHeader(header)) return NO;
    uint64_t tag = 0;
    if (!ZN55PlaintextTag(header, entries, &tag)) return NO;
    if (tag != header->reserved[1]) return NO;
    uint64_t seal = ZN55Mix64(tag ^ header->reserved[0] ^ header->reserved[2] ^
                              UINT64_C(0x6E624EB7D62A4D31));
    return seal == header->reserved[3];
}

static inline BOOL ZN55ProtectHeaderEntries(ZN44StaticHeader *header,
                                            ZN44StaticEntry *entries,
                                            uint64_t nonce) {
    if (!header || !entries || !header->count) return NO;
    if (header->flags & ZN44_STATIC_HEADER_FLAG_RVA_PROTECTION_V1) {
        return ZN55ValidateProtectedHeader(header, entries);
    }
    if (!nonce) nonce = UINT64_C(0xA5D37C91E26B4F08);

    header->reserved[0] = nonce;
    header->reserved[2] = ZN55MarkerForHeader(header);

    uint64_t tag = 0;
    if (!ZN55PlaintextTag(header, entries, &tag)) return NO;

    for (uint32_t i = 0; i < header->count; i++) {
        uint64_t off = entries[i].offRVA;
        uint64_t on = entries[i].onRVA;
        uint64_t site = entries[i].siteRVA;
        entries[i].offRVA = ZN55EncodeRVAValue(header, &entries[i], i, 0u, off);
        entries[i].onRVA = ZN55EncodeRVAValue(header, &entries[i], i, 1u, on);
        entries[i].siteRVA = ZN55EncodeRVAValue(header, &entries[i], i, 2u, site);
    }

    header->reserved[1] = tag;
    header->reserved[3] = ZN55Mix64(tag ^ header->reserved[0] ^ header->reserved[2] ^
                                    UINT64_C(0x6E624EB7D62A4D31));
    header->flags |= ZN44_STATIC_HEADER_FLAG_RVA_PROTECTION_V1;
    return ZN55ValidateProtectedHeader(header, entries);
}

FOUNDATION_EXPORT BOOL ZN55ProtectStaticRVAsAtPath(NSString *path,
                                                   NSUInteger *protectedEntries,
                                                   NSString **error)
    __attribute__((visibility("hidden")));
