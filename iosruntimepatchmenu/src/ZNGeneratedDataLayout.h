#pragma once

#include <stdint.h>
#include "ZNStaticPatchFormat.h"

// M6.8.4 Generated Data Layout V1.
//
// __ZNDATA/__zndata:
//   ZN44StaticHeader
//   ZN44StaticEntry[staticCount]
//   align(8)
//   ZN44FeatureDescriptionHeader
//   ZN44FeatureDescriptionEntry[staticCount]
//   align(8)
//   ZNRuntimeActionHeader + entries + string pool
//   later postprocess-owned extensions (for example RW value cells)
//
// There is intentionally no legacy fallback. Older generated binaries without
// ZN44_STATIC_HEADER_FLAG_GENERATED_LAYOUT_V1 are not part of this contract.

static inline uint64_t ZNGeneratedDataAlign8(uint64_t value) {
    return (value + 7ULL) & ~7ULL;
}

static inline int ZNGeneratedDataLayoutV1LocateRuntimeAction(
    const uint8_t *section,
    uint64_t sectionSize,
    uint64_t *outOffset)
{
    if (!section || sectionSize < sizeof(ZN44StaticHeader)) return 0;

    const ZN44StaticHeader *header=(const ZN44StaticHeader *)section;
    if (header->magic0!=ZN44_STATIC_MAGIC0 ||
        header->magic1!=ZN44_STATIC_MAGIC1 ||
        header->version!=ZN44_STATIC_VERSION_V3 ||
        header->entrySize!=sizeof(ZN44StaticEntry) ||
        header->count>ZN44_STATIC_MAX_ENTRIES ||
        (header->flags & ZN44_STATIC_HEADER_FLAG_GENERATED_LAYOUT_V1)==0)
        return 0;

    uint64_t entriesBytes=(uint64_t)header->count*header->entrySize;
    if (entriesBytes > UINT64_MAX-sizeof(ZN44StaticHeader)) return 0;
    uint64_t descOffset=ZNGeneratedDataAlign8(sizeof(ZN44StaticHeader)+entriesBytes);
    if (descOffset>sectionSize ||
        sectionSize-descOffset<sizeof(ZN44FeatureDescriptionHeader))
        return 0;

    const ZN44FeatureDescriptionHeader *desc=
        (const ZN44FeatureDescriptionHeader *)(section+descOffset);
    if (desc->magic0!=ZN44_FEATURE_DESC_MAGIC0 ||
        desc->magic1!=ZN44_FEATURE_DESC_MAGIC1 ||
        desc->count!=header->count ||
        desc->entrySize!=sizeof(ZN44FeatureDescriptionEntry))
        return 0;

    uint64_t descEntriesBytes=(uint64_t)desc->count*desc->entrySize;
    if (descEntriesBytes > UINT64_MAX-sizeof(*desc)) return 0;
    uint64_t actionOffset=ZNGeneratedDataAlign8(
        descOffset+sizeof(*desc)+descEntriesBytes);
    if (actionOffset>sectionSize) return 0;

    if (outOffset) *outOffset=actionOffset;
    return 1;
}
