#import <Foundation/Foundation.h>
#import <assert.h>
#import <string.h>
#import "ZNStaticRVAProtection.h"

static ZN44StaticHeader MakeHeader(uint32_t count) {
    ZN44StaticHeader h = {};
    h.magic0 = ZN44_STATIC_MAGIC0;
    h.magic1 = ZN44_STATIC_MAGIC1;
    h.version = ZN44_STATIC_VERSION_V2;
    h.count = count;
    h.entrySize = sizeof(ZN44StaticEntry);
    h.flags = ZN44_STATIC_HEADER_FLAG_FEATURE_METADATA_V1;
    return h;
}

static ZN44StaticEntry MakeEntry(uint32_t patchID,
                                 uint32_t physicalID,
                                 uint32_t canonicalIndex,
                                 uint32_t flags,
                                 uint64_t site,
                                 uint64_t off,
                                 uint64_t on) {
    ZN44StaticEntry e = {};
    e.patchID = patchID;
    e.physicalID = physicalID;
    e.canonicalIndex = canonicalIndex;
    e.flags = flags;
    e.windowLength = 8;
    e.enabledLength = 8;
    e.siteRVA = site;
    e.offRVA = off;
    e.onRVA = on;
    return e;
}

int main(void) {
    @autoreleasepool {
        static_assert(sizeof(ZN44StaticEntry) == 128, "Static Entry ABI changed");

        ZN44StaticHeader header = MakeHeader(3);
        ZN44StaticEntry entries[3] = {
            MakeEntry(1, 1, 0, ZN44_STATIC_ENTRY_FLAG_CANONICAL | ZN44_STATIC_ENTRY_FLAG_SHARED,
                      0x2E25904ULL, 0x4100000ULL, 0x4100100ULL),
            MakeEntry(2, 1, 0, ZN44_STATIC_ENTRY_FLAG_SHARED,
                      0x2E25904ULL, 0x4100000ULL, 0x4100200ULL),
            MakeEntry(3, 2, 2, ZN44_STATIC_ENTRY_FLAG_CANONICAL,
                      0x2DA9DE0ULL, 0x4100300ULL, 0x4100400ULL),
        };
        ZN44StaticEntry original[3] = {};
        memcpy(original, entries, sizeof(entries));

        const uint64_t nonce = 0xA12B34C56D78E90FULL;
        assert(ZN55ProtectHeaderEntries(&header, entries, nonce));
        assert((header.flags & ZN44_STATIC_HEADER_FLAG_RVA_PROTECTION_V1) != 0);
        assert(header.reserved[0] == nonce);
        assert(ZN55ValidateProtectedHeader(&header, entries));

        for (uint32_t i = 0; i < 3; i++) {
            assert(entries[i].siteRVA != original[i].siteRVA);
            assert(entries[i].offRVA != original[i].offRVA);
            assert(entries[i].onRVA != original[i].onRVA);

            ZN55DecodedRVAs decoded = {};
            assert(ZN55DecodeEntryRVAs(&header, &entries[i], i, &decoded));
            assert(decoded.siteRVA == original[i].siteRVA);
            assert(decoded.offRVA == original[i].offRVA);
            assert(decoded.onRVA == original[i].onRVA);
        }

        ZN44StaticHeader legacyHeader = MakeHeader(1);
        ZN44StaticEntry legacyEntry = MakeEntry(7, 1, 0, ZN44_STATIC_ENTRY_FLAG_CANONICAL,
                                                0x123456ULL, 0x200000ULL, 0x200100ULL);
        ZN55DecodedRVAs legacyDecoded = {};
        assert(ZN55DecodeEntryRVAs(&legacyHeader, &legacyEntry, 0, &legacyDecoded));
        assert(legacyDecoded.siteRVA == legacyEntry.siteRVA);
        assert(legacyDecoded.offRVA == legacyEntry.offRVA);
        assert(legacyDecoded.onRVA == legacyEntry.onRVA);

        uint64_t saved = entries[1].onRVA;
        entries[1].onRVA ^= 1ULL;
        assert(!ZN55ValidateProtectedHeader(&header, entries));
        entries[1].onRVA = saved;
        assert(ZN55ValidateProtectedHeader(&header, entries));

        puts("Static RVA Protection V1 tests passed");
    }
    return 0;
}
