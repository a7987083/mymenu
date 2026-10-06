#!/usr/bin/env python3
from pathlib import Path

p = Path("iosruntimepatchmenu/src/ZNStaticDispatchRuntime.mm")
s = p.read_text()

if '#import "ZNActivationTrace.h"' not in s:
    s = s.replace('#import "ZNPatchCore.h"\n', '#import "ZNPatchCore.h"\n#import "ZNActivationTrace.h"\n', 1)

prop_anchor = '@property(nonatomic,strong) NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *ownerOrderBySite;\n'
if 'lastRefreshMilliseconds' not in s:
    if prop_anchor not in s:
        raise SystemExit('ownerOrderBySite property anchor missing')
    s = s.replace(prop_anchor, prop_anchor + '@property(nonatomic,assign) double lastRefreshMilliseconds;\n@property(nonatomic,copy) NSString *lastDiscoverySummary;\n', 1)

if 'v0.5.6.1 direct __ZNDATA fast path' not in s:
    start = s.find('- (void)refresh {')
    end = s.find('- (ZNStaticPatchRecord *)zn44_recordForPatchID:', start)
    if start < 0 or end < 0:
        raise SystemExit('refresh replacement anchors missing')

    replacement = r'''// v0.5.6.1 direct __ZNDATA fast path: current Builder V3 owns exactly one
// __ZNDATA/__zndata section. Read that section directly instead of probing
// every 8-byte slot in every writable segment on the main thread. Older
// generated binaries without the owned section retain the legacy compatibility
// scan as a fallback.
- (BOOL)zn44_consumeHeader:(const ZN44StaticHeader *)header
                   address:(uintptr_t)headerAddress
                 regionEnd:(uintptr_t)regionEnd
             runtimeHeader:(uintptr_t)runtimeHeader
                targetName:(NSString *)targetName
                     found:(NSMutableArray<ZNStaticPatchRecord *> *)found
              liveSiteKeys:(NSMutableSet<NSString *> *)liveSiteKeys {
    if (!ZN44HeaderValid(header, headerAddress, regionEnd)) return NO;

    ZN44StaticEntry *entries = (ZN44StaticEntry *)(headerAddress + sizeof(ZN44StaticHeader));
    if (!ZN55ValidateProtectedHeader(header, entries)) {
        ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] integrity FAIL target=%@ header=%p", targetName, (void *)headerAddress]);
        return NO;
    }

    for (uint32_t e = 0; e < header->count; e++) {
        ZN44StaticEntry *entry = &entries[e];
        ZN55DecodedRVAs entryRVAs = {};
        if (!ZN55DecodeEntryRVAs(header, entry, e, &entryRVAs)) continue;

        uint32_t canonicalIndex = ZN44CanonicalIndex(header, entry, e);
        ZN44StaticEntry *dispatchEntry = &entries[canonicalIndex];
        ZN55DecodedRVAs dispatchRVAs = {};
        if (!ZN55DecodeEntryRVAs(header, dispatchEntry, canonicalIndex, &dispatchRVAs)) continue;

        NSString *siteKey = [NSString stringWithFormat:@"%p:%p:%u", (void *)runtimeHeader, (void *)headerAddress, canonicalIndex];
        [liveSiteKeys addObject:siteKey];

        uintptr_t offTarget = runtimeHeader + (uintptr_t)dispatchRVAs.offRVA;
        uintptr_t current = __atomic_load_n((uintptr_t *)&dispatchEntry->selectedTarget, __ATOMIC_ACQUIRE);
        if (!ZN44CurrentTargetValid(header, entries, canonicalIndex, runtimeHeader, current)) {
            __atomic_store_n((uintptr_t *)&dispatchEntry->selectedTarget, offTarget, __ATOMIC_RELEASE);
            current = offTarget;
        }

        NSMutableArray<NSNumber *> *owners = self.ownerOrderBySite[siteKey];
        if (!owners) {
            owners = [NSMutableArray array];
            if (current != offTarget) {
                for (uint32_t j = 0; j < header->count; j++) {
                    ZN44StaticEntry *candidate = &entries[j];
                    if (ZN44CanonicalIndex(header, candidate, j) != canonicalIndex) continue;
                    ZN55DecodedRVAs candidateRVAs = {};
                    if (!ZN55DecodeEntryRVAs(header, candidate, j, &candidateRVAs)) continue;
                    if (current == runtimeHeader + (uintptr_t)candidateRVAs.onRVA) {
                        [owners addObject:@(candidate->patchID)];
                        break;
                    }
                }
            }
            self.ownerOrderBySite[siteKey] = owners;
        }

        ZNStaticPatchRecord *record = [ZNStaticPatchRecord new];
        record.target = targetName;
        record.title = ZN44StringFromFixed(entry->title, sizeof(entry->title), [NSString stringWithFormat:@"Patch #%u", entry->patchID]);
        record.group = ZN44StringFromFixed(entry->group, sizeof(entry->group), @"Imported");
        record.siteRVA = entryRVAs.siteRVA;
        record.patchID = entry->patchID;
        record.imageBase = runtimeHeader;
        record.entry = entry;
        record.dispatchEntry = dispatchEntry;
        record.offRVA = dispatchRVAs.offRVA;
        record.onRVA = entryRVAs.onRVA;
        record.siteKey = siteKey;
        record.physicalID = (header->version >= ZN44_STATIC_VERSION_V2 && entry->physicalID) ? entry->physicalID : (e + 1);
        record.headerVersion = header->version;
        record.payloadProtectionV2 = (header->flags & ZN44_STATIC_HEADER_FLAG_PAYLOAD_PROTECTION_V2) != 0;
        record.enabled = [owners containsObject:@(entry->patchID)];
        [found addObject:record];
    }
    return YES;
}

- (void)refresh {
    double refreshStart = ZNActivationTraceNow();
    NSMutableArray<ZNStaticPatchRecord *> *found = [NSMutableArray array];
    NSMutableSet<NSString *> *liveSiteKeys = [NSMutableSet set];
    NSString *bundleRoot = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    uint32_t imageCount = _dyld_image_count();
    NSUInteger bundleImages = 0;
    NSUInteger directImages = 0;
    NSUInteger fallbackImages = 0;
    unsigned long long fallbackProbes = 0;
    unsigned long long fallbackBytes = 0;

    ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh begin · thread=%@ · dyldImages=%u",
                          NSThread.isMainThread ? @"main" : @"background",
                          imageCount]);

    for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
        const char *rawPath = _dyld_get_image_name(imageIndex);
        if (!rawPath) continue;
        NSString *path = [[NSString stringWithUTF8String:rawPath] stringByStandardizingPath];
        if (!path.length || ![path hasPrefix:bundleRoot]) continue;
        bundleImages++;

        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(imageIndex);
        if (!mh || mh->magic != MH_MAGIC_64) continue;
        uintptr_t runtimeHeader = (uintptr_t)mh;
        const uint8_t *lcBase = (const uint8_t *)(mh + 1);
        const uint8_t *lcEnd = lcBase + mh->sizeofcmds;
        const struct load_command *lc = (const struct load_command *)lcBase;
        uint64_t imageVMBase = UINT64_MAX;

        for (uint32_t i = 0; i < mh->ncmds; i++) {
            if ((const uint8_t *)lc + sizeof(*lc) > lcEnd || lc->cmdsize < sizeof(*lc) || (const uint8_t *)lc + lc->cmdsize > lcEnd) break;
            if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                if (strncmp(seg->segname, SEG_TEXT, 16) == 0) imageVMBase = seg->vmaddr;
            }
            lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
        }
        if (imageVMBase == UINT64_MAX) continue;

        NSString *targetName = path.lastPathComponent ?: @"unknown";
        BOOL ownedSectionPresent = NO;
        BOOL ownedSectionConsumed = NO;

        lc = (const struct load_command *)lcBase;
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            if ((const uint8_t *)lc + sizeof(*lc) > lcEnd || lc->cmdsize < sizeof(*lc) || (const uint8_t *)lc + lc->cmdsize > lcEnd) break;
            if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                uint64_t sectionBytes = (uint64_t)seg->nsects * sizeof(struct section_64);
                if (lc->cmdsize >= sizeof(struct segment_command_64) + sectionBytes &&
                    strncmp(seg->segname, "__ZNDATA", 16) == 0) {
                    const struct section_64 *sections = (const struct section_64 *)(seg + 1);
                    for (uint32_t j = 0; j < seg->nsects; j++) {
                        const struct section_64 *sec = &sections[j];
                        if (strncmp(sec->sectname, "__zndata", 16) != 0) continue;
                        ownedSectionPresent = YES;
                        if (sec->addr < imageVMBase || sec->size < sizeof(ZN44StaticHeader)) break;

                        uintptr_t start = runtimeHeader + (uintptr_t)(sec->addr - imageVMBase);
                        uintptr_t end = start + (uintptr_t)sec->size;
                        ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] direct-owned-section-v1 target=%@ section=__ZNDATA/__zndata bytes=%llu",
                                              targetName,
                                              (unsigned long long)sec->size]);
                        ownedSectionConsumed = [self zn44_consumeHeader:(const ZN44StaticHeader *)start
                                                               address:start
                                                             regionEnd:end
                                                         runtimeHeader:runtimeHeader
                                                            targetName:targetName
                                                                 found:found
                                                          liveSiteKeys:liveSiteKeys];
                        break;
                    }
                }
            }
            lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
        }

        if (ownedSectionPresent) {
            directImages++;
            if (!ownedSectionConsumed) {
                ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] direct section rejected target=%@; fail-closed, no compatibility full scan", targetName]);
            }
            continue;
        }

        // fallback-compat-scan: retained only for older generated binaries that
        // predate the owned __ZNDATA/__zndata section.
        fallbackImages++;
        ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] fallback-compat-scan target=%@ reason=owned-section-missing", targetName]);
        lc = (const struct load_command *)lcBase;
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            if ((const uint8_t *)lc + sizeof(*lc) > lcEnd || lc->cmdsize < sizeof(*lc) || (const uint8_t *)lc + lc->cmdsize > lcEnd) break;
            if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                if ((seg->initprot & VM_PROT_WRITE) && seg->filesize >= sizeof(ZN44StaticHeader) && seg->vmaddr >= imageVMBase) {
                    uintptr_t start = runtimeHeader + (uintptr_t)(seg->vmaddr - imageVMBase);
                    uintptr_t end = start + (uintptr_t)seg->filesize;
                    uintptr_t cursor = (start + 7u) & ~(uintptr_t)7u;
                    fallbackBytes += (unsigned long long)seg->filesize;
                    for (; cursor + sizeof(ZN44StaticHeader) <= end; cursor += 8) {
                        fallbackProbes++;
                        const ZN44StaticHeader *header = (const ZN44StaticHeader *)cursor;
                        if (header->magic0 != ZN44_STATIC_MAGIC0) continue;
                        if (![self zn44_consumeHeader:header
                                             address:cursor
                                           regionEnd:end
                                       runtimeHeader:runtimeHeader
                                          targetName:targetName
                                               found:found
                                        liveSiteKeys:liveSiteKeys]) continue;
                        cursor += sizeof(ZN44StaticHeader) + (uintptr_t)header->count * sizeof(ZN44StaticEntry) - 8;
                    }
                }
            }
            lc = (const struct load_command *)((const uint8_t *)lc + lc->cmdsize);
        }
    }

    NSMutableSet<NSString *> *previousKeys = [NSMutableSet set];
    for (ZNStaticPatchRecord *r in self.records) if (r.siteKey.length) [previousKeys addObject:r.siteKey];
    for (NSString *key in previousKeys) if (![liveSiteKeys containsObject:key]) [self.ownerOrderBySite removeObjectForKey:key];

    self.records = found;
    NSUInteger shared = 0;
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (ZNStaticPatchRecord *r in found) counts[r.siteKey] = @([counts[r.siteKey] unsignedIntegerValue] + 1);
    for (NSNumber *n in counts.allValues) if (n.unsignedIntegerValue > 1) shared++;
    NSUInteger payloadV2 = 0;
    for (ZNStaticPatchRecord *r in found) if (r.payloadProtectionV2) payloadV2++;

    self.lastRefreshMilliseconds = (ZNActivationTraceNow() - refreshStart) * 1000.0;
    self.lastDiscoverySummary = [NSString stringWithFormat:@"direct=%lu fallback=%lu probes=%llu",
                                 (unsigned long)directImages,
                                 (unsigned long)fallbackImages,
                                 fallbackProbes];

    ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh end · %.1fms · bundleImages=%lu direct=%lu fallback=%lu fallbackBytes=%llu probes=%llu · logical=%lu physical=%lu shared=%lu payload-v2=%lu/%lu",
                          self.lastRefreshMilliseconds,
                          (unsigned long)bundleImages,
                          (unsigned long)directImages,
                          (unsigned long)fallbackImages,
                          fallbackBytes,
                          fallbackProbes,
                          (unsigned long)found.count,
                          (unsigned long)counts.count,
                          (unsigned long)shared,
                          (unsigned long)payloadV2,
                          (unsigned long)found.count]);
}

'''
    s = s[:start] + replacement + s[end:]

# Extend the menu diagnostic line without changing any Patch semantics.
diag_old = '[lines addObject:[NSString stringWithFormat:@"Static Dispatch：%lu 逻辑项 / %lu 物理 Site · Payload V2 %lu/%lu", (unsigned long)self.records.count, (unsigned long)sites.count, (unsigned long)payloadV2, (unsigned long)self.records.count]];'
if '最近扫描' not in s:
    if diag_old not in s:
        raise SystemExit('diagnostic anchor missing')
    diag_new = diag_old + '\n    [lines addObject:[NSString stringWithFormat:@"最近扫描：%.1fms · %@", self.lastRefreshMilliseconds, self.lastDiscoverySummary.length ? self.lastDiscoverySummary : @"尚未执行"]];'
    s = s.replace(diag_old, diag_new, 1)

prepare_old = '''extern "C" void ZNPrepareStaticDispatchRuntimeDeferred(void) {
    @autoreleasepool {
        ZNStaticDispatchRuntime *runtime = [ZNStaticDispatchRuntime sharedRuntime];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [runtime refresh];
        });
    }
}
'''
if '[static-dispatch] refresh timer fired' not in s:
    if prepare_old not in s:
        raise SystemExit('prepare function anchor missing')
    prepare_new = '''extern "C" void ZNPrepareStaticDispatchRuntimeDeferred(void) {
    @autoreleasepool {
        ZNStaticDispatchRuntime *runtime = [ZNStaticDispatchRuntime sharedRuntime];
        ZNActivationTraceLog(@"[static-dispatch] prepare complete; refresh timer armed +350ms");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ZNActivationTraceLog(@"[static-dispatch] refresh timer fired");
            [runtime refresh];
        });
    }
}
'''
    s = s.replace(prepare_old, prepare_new, 1)

p.write_text(s)
print('v0.5.6.1 first-activation fix applied')
