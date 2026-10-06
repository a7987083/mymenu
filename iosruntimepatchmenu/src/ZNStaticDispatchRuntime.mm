#import "ZNStaticDispatchRuntime.h"
#import "ZNStaticPatchFormat.h"
#import "ZNStaticRVAProtection.h"
#import "ZNPatchCore.h"
#import "ZNActivationTrace.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>

@interface ZNStaticPatchRecord ()
@property(nonatomic,copy,readwrite) NSString *target;
@property(nonatomic,copy,readwrite) NSString *title;
@property(nonatomic,copy,readwrite) NSString *group;
@property(nonatomic,copy,readwrite) NSString *featureDescription;
@property(nonatomic,assign,readwrite) uint64_t siteRVA;
@property(nonatomic,assign,readwrite) uint32_t patchID;
@property(nonatomic,assign,readwrite,getter=isEnabled) BOOL enabled;
@property(nonatomic,assign) uintptr_t imageBase;
@property(nonatomic,assign) ZN44StaticEntry *entry;
@property(nonatomic,assign) ZN44StaticEntry *dispatchEntry;
@property(nonatomic,assign) uint64_t offRVA;
@property(nonatomic,assign) uint64_t onRVA;
@property(nonatomic,copy) NSString *siteKey;
@property(nonatomic,assign) uint32_t physicalID;
@property(nonatomic,assign) uint32_t headerVersion;
@property(nonatomic,assign) BOOL payloadProtectionV2;
@end
@implementation ZNStaticPatchRecord
@end

@interface ZNStaticDispatchRuntime ()
@property(nonatomic,copy,readwrite) NSArray<ZNStaticPatchRecord *> *records;
// Per physical site, stores logical patchIDs in activation order. The last
// owner wins. Disabling the last owner automatically falls back to the
// previous active owner; an empty stack selects OFF/Original.
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *ownerOrderBySite;
@property(nonatomic,assign) double lastRefreshMilliseconds;
@property(nonatomic,copy) NSString *lastDiscoverySummary;
@property(nonatomic,assign) BOOL refreshScheduled;
@property(nonatomic,assign) NSUInteger refreshRequestCount;
@property(nonatomic,assign) NSUInteger refreshExecutionCount;
@property(nonatomic,assign) NSUInteger refreshCoalescedCount;
@property(nonatomic,assign) BOOL discoveryDirty;
@property(nonatomic,assign) BOOL refreshInProgress;
@property(nonatomic,assign) uint32_t lastScannedImageCount;
@property(nonatomic,assign) uint64_t snapshotGeneration;
@property(nonatomic,assign) NSUInteger refreshCacheHitCount;
@end

static NSString *ZN44StringFromFixed(const char *bytes, size_t cap, NSString *fallback) {
    if (!bytes || cap == 0) return fallback ?: @"";
    size_t n = strnlen(bytes, cap);
    if (!n) return fallback ?: @"";
    NSString *s = [[NSString alloc] initWithBytes:bytes length:n encoding:NSUTF8StringEncoding];
    return s.length ? s : (fallback ?: @"");
}

static BOOL ZN44HeaderValid(const ZN44StaticHeader *h, uintptr_t headerAddress, uintptr_t segmentEnd) {
    if (!h) return NO;
    if (h->magic0 != ZN44_STATIC_MAGIC0 || h->magic1 != ZN44_STATIC_MAGIC1) return NO;
    if ((h->version != ZN44_STATIC_VERSION_V1 && h->version != ZN44_STATIC_VERSION_V2) ||
        h->entrySize != sizeof(ZN44StaticEntry)) return NO;
    if (h->count == 0 || h->count > ZN44_STATIC_MAX_ENTRIES) return NO;
    uint64_t bytes = sizeof(ZN44StaticHeader) + (uint64_t)h->count * sizeof(ZN44StaticEntry);
    if ((uint64_t)headerAddress + bytes > (uint64_t)segmentEnd) return NO;
    return YES;
}

static uint32_t ZN44CanonicalIndex(const ZN44StaticHeader *header,
                                   const ZN44StaticEntry *entry,
                                   uint32_t entryIndex) {
    if (header && header->version >= ZN44_STATIC_VERSION_V2 && entry &&
        entry->canonicalIndex < header->count) {
        return entry->canonicalIndex;
    }
    return entryIndex;
}

static BOOL ZN44CurrentTargetValid(const ZN44StaticHeader *header,
                                   ZN44StaticEntry *entries,
                                   uint32_t canonicalIndex,
                                   uintptr_t imageBase,
                                   uintptr_t current) {
    if (!header || !entries || canonicalIndex >= header->count) return NO;

    ZN55DecodedRVAs canonicalRVAs = {};
    if (!ZN55DecodeEntryRVAs(header, &entries[canonicalIndex], canonicalIndex, &canonicalRVAs)) return NO;
    uintptr_t offTarget = imageBase + (uintptr_t)canonicalRVAs.offRVA;
    if (current == offTarget) return YES;

    for (uint32_t i = 0; i < header->count; i++) {
        ZN44StaticEntry *candidate = &entries[i];
        if (ZN44CanonicalIndex(header, candidate, i) != canonicalIndex) continue;
        ZN55DecodedRVAs candidateRVAs = {};
        if (!ZN55DecodeEntryRVAs(header, candidate, i, &candidateRVAs)) return NO;
        uintptr_t onTarget = imageBase + (uintptr_t)candidateRVAs.onRVA;
        if (current == onTarget) return YES;
    }
    return NO;
}

@implementation ZNStaticDispatchRuntime

+ (instancetype)sharedRuntime {
    static ZNStaticDispatchRuntime *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [ZNStaticDispatchRuntime new];
        s.records = @[];
        s.ownerOrderBySite = [NSMutableDictionary dictionary];
        s.discoveryDirty = YES;
        s.refreshInProgress = NO;
        s.lastScannedImageCount = 0;
        s.snapshotGeneration = 0;
        s.refreshCacheHitCount = 0;
        [[NSNotificationCenter defaultCenter] addObserver:s selector:@selector(zn44_imageAdded:) name:@"ZNModuleManagerImageAdded" object:nil];
    });
    return s;
}

// v0.5.6.2 refresh-request coalescer: one burst of image additions must
// produce at most one Static Dispatch refresh. The first activation refresh and
// image-added refreshes share the same gate, so dyld bursts cannot build a long
// main-queue backlog.
- (void)zn44_scheduleRefreshAfter:(NSTimeInterval)delay reason:(NSString *)reason {
    void (^scheduleBlock)(void) = ^{
        self.refreshRequestCount += 1;
        if (self.refreshScheduled) {
            self.refreshCoalescedCount += 1;
            if (self.refreshCoalescedCount <= 3 || (self.refreshCoalescedCount % 100) == 0) {
                ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh request coalesced · reason=%@ · requests=%lu executions=%lu coalesced=%lu",
                                      reason ?: @"unknown",
                                      (unsigned long)self.refreshRequestCount,
                                      (unsigned long)self.refreshExecutionCount,
                                      (unsigned long)self.refreshCoalescedCount]);
            }
            return;
        }

        self.refreshScheduled = YES;
        NSUInteger requestID = self.refreshRequestCount;
        ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh scheduled · request=%lu · reason=%@ · delay=%.0fms",
                              (unsigned long)requestID,
                              reason ?: @"unknown",
                              delay * 1000.0]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.0, delay) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            self.refreshScheduled = NO;
            self.refreshExecutionCount += 1;
            ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh execution=%lu · request=%lu · reason=%@",
                                  (unsigned long)self.refreshExecutionCount,
                                  (unsigned long)requestID,
                                  reason ?: @"unknown"]);
            [self refresh];
        });
    };

    if (NSThread.isMainThread) scheduleBlock();
    else dispatch_async(dispatch_get_main_queue(), scheduleBlock);
}

- (void)zn44_imageAdded:(NSNotification *)note {
    self.discoveryDirty = YES;
    NSUInteger burst = [note.userInfo[@"burstCount"] unsignedIntegerValue];
    ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] image notification received · burst=%lu",
                          (unsigned long)MAX((NSUInteger)1, burst)]);
    [self zn44_scheduleRefreshAfter:0.20 reason:@"image-added-burst"];
}

// v0.5.6.1 direct __ZNDATA fast path: current Builder V3 owns exactly one
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
    const ZN44FeatureDescriptionEntry *descriptionEntries = NULL;
    uint64_t descriptionOffset=(sizeof(ZN44StaticHeader)+(uint64_t)header->count*sizeof(ZN44StaticEntry)+7u)&~UINT64_C(7);
    uintptr_t descriptionAddress=headerAddress+(uintptr_t)descriptionOffset;
    if(descriptionAddress+sizeof(ZN44FeatureDescriptionHeader)<=regionEnd){
        const ZN44FeatureDescriptionHeader *descriptionHeader=(const ZN44FeatureDescriptionHeader *)descriptionAddress;
        uint64_t descriptionBytes=sizeof(*descriptionHeader)+(uint64_t)descriptionHeader->count*sizeof(ZN44FeatureDescriptionEntry);
        if(descriptionHeader->magic0==ZN44_FEATURE_DESC_MAGIC0 &&
           descriptionHeader->magic1==ZN44_FEATURE_DESC_MAGIC1 &&
           descriptionHeader->count==header->count &&
           descriptionHeader->entrySize==sizeof(ZN44FeatureDescriptionEntry) &&
           descriptionAddress+descriptionBytes<=regionEnd){
            descriptionEntries=(const ZN44FeatureDescriptionEntry *)(descriptionHeader+1);
        }
    }
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
        record.featureDescription=@"";
        if(descriptionEntries){
            const ZN44FeatureDescriptionEntry *desc=&descriptionEntries[e];
            if(desc->patchID==entry->patchID && desc->length<=ZN44_FEATURE_DESC_MAX_UTF8){
                NSString *decoded=[[NSString alloc] initWithBytes:desc->text length:desc->length encoding:NSUTF8StringEncoding];
                if(decoded.length)record.featureDescription=decoded;
            }
        }
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
    // M6.2.1 discovery cache: legacy UI layers still call refresh() as if it
    // were a getter. Keep those callers untouched for now, but make repeated
    // calls O(1) unless the dyld image set changed or an image-added event
    // explicitly invalidated discovery.
    uint32_t imageCount = _dyld_image_count();
    if (!self.discoveryDirty && self.lastScannedImageCount == imageCount) {
        self.refreshCacheHitCount += 1;
        if (self.refreshCacheHitCount <= 3 || (self.refreshCacheHitCount % 100) == 0) {
            ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch-cache] HIT generation=%llu images=%u hits=%lu records=%lu",
                                  self.snapshotGeneration,
                                  imageCount,
                                  (unsigned long)self.refreshCacheHitCount,
                                  (unsigned long)self.records.count]);
        }
        return;
    }
    if (self.refreshInProgress) {
        self.discoveryDirty = YES;
        ZNActivationTraceLog(@"[static-dispatch-cache] refresh already in progress; invalidation retained");
        return;
    }

    self.refreshInProgress = YES;
    double refreshStart = ZNActivationTraceNow();
    NSMutableArray<ZNStaticPatchRecord *> *found = [NSMutableArray array];
    NSMutableSet<NSString *> *liveSiteKeys = [NSMutableSet set];
    NSString *bundleRoot = NSBundle.mainBundle.bundlePath.stringByStandardizingPath;
    NSUInteger bundleImages = 0;
    NSUInteger directImages = 0;
    NSUInteger fallbackImages = 0;
    unsigned long long fallbackProbes = 0;
    unsigned long long fallbackBytes = 0;

    // owned-section-preflight-v1: determine whether any current Builder V3
    // image in the app bundle carries the exact owned Static Dispatch section.
    // If one exists, unrelated images must never enter the legacy whole-segment
    // compatibility scan just because they do not own ZonoPatch metadata.
    BOOL anyOwnedSection = NO;
    for (uint32_t probeImageIndex = 0; probeImageIndex < imageCount && !anyOwnedSection; probeImageIndex++) {
        const char *probeRawPath = _dyld_get_image_name(probeImageIndex);
        if (!probeRawPath) continue;
        NSString *probePath = [[NSString stringWithUTF8String:probeRawPath] stringByStandardizingPath];
        if (!probePath.length || ![probePath hasPrefix:bundleRoot]) continue;

        const struct mach_header_64 *probeMH = (const struct mach_header_64 *)_dyld_get_image_header(probeImageIndex);
        if (!probeMH || probeMH->magic != MH_MAGIC_64) continue;
        const uint8_t *probeLCBase = (const uint8_t *)(probeMH + 1);
        const uint8_t *probeLCEnd = probeLCBase + probeMH->sizeofcmds;
        const struct load_command *probeLC = (const struct load_command *)probeLCBase;
        for (uint32_t i = 0; i < probeMH->ncmds; i++) {
            if ((const uint8_t *)probeLC + sizeof(*probeLC) > probeLCEnd ||
                probeLC->cmdsize < sizeof(*probeLC) ||
                (const uint8_t *)probeLC + probeLC->cmdsize > probeLCEnd) break;
            if (probeLC->cmd == LC_SEGMENT_64 && probeLC->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)probeLC;
                uint64_t sectionBytes = (uint64_t)seg->nsects * sizeof(struct section_64);
                if (strncmp(seg->segname, "__ZNDATA", 16) == 0 &&
                    probeLC->cmdsize >= sizeof(struct segment_command_64) + sectionBytes) {
                    const struct section_64 *sections = (const struct section_64 *)(seg + 1);
                    for (uint32_t j = 0; j < seg->nsects; j++) {
                        if (strncmp(sections[j].sectname, "__zndata", 16) == 0) {
                            anyOwnedSection = YES;
                            break;
                        }
                    }
                }
            }
            probeLC = (const struct load_command *)((const uint8_t *)probeLC + probeLC->cmdsize);
        }
    }
    ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] owned-section-preflight-v1 present=%@",
                          anyOwnedSection ? @"YES" : @"NO"]);

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

        if (anyOwnedSection) {
            ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] compatibility scan skipped target=%@ reason=current-owned-section-present-elsewhere", targetName]);
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
    self.lastScannedImageCount = imageCount;
    self.snapshotGeneration += 1;
    self.discoveryDirty = NO;
    self.refreshInProgress = NO;
    NSString *mode = found.count ? @"generated-static" : @"original-binary/no-static-metadata";
    self.lastDiscoverySummary = [NSString stringWithFormat:@"mode=%@ generation=%llu direct=%lu fallback=%lu probes=%llu requests=%lu executions=%lu coalesced=%lu cacheHits=%lu",
                                 mode,
                                 self.snapshotGeneration,
                                 (unsigned long)directImages,
                                 (unsigned long)fallbackImages,
                                 fallbackProbes,
                                 (unsigned long)self.refreshRequestCount,
                                 (unsigned long)self.refreshExecutionCount,
                                 (unsigned long)self.refreshCoalescedCount,
                                 (unsigned long)self.refreshCacheHitCount];

    if (found.count == 0) {
        ZNActivationTraceLog(@"[static-dispatch] original-binary mode · no generated Static metadata found");
    } else {
        ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] generated-static mode · logical=%lu physical=%lu",
                              (unsigned long)found.count,
                              (unsigned long)counts.count]);
    }

    ZNActivationTraceLog([NSString stringWithFormat:@"[static-dispatch] refresh end · %.1fms · bundleImages=%lu direct=%lu fallback=%lu fallbackBytes=%llu probes=%llu · logical=%lu physical=%lu shared=%lu payload-v2=%lu/%lu · requests=%lu executions=%lu coalesced=%lu",
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
                          (unsigned long)found.count,
                          (unsigned long)self.refreshRequestCount,
                          (unsigned long)self.refreshExecutionCount,
                          (unsigned long)self.refreshCoalescedCount]);
}

- (ZNStaticPatchRecord *)zn44_recordForPatchID:(uint32_t)patchID siteKey:(NSString *)siteKey {
    for (ZNStaticPatchRecord *candidate in self.records) {
        if ([candidate.siteKey isEqualToString:siteKey] && candidate.patchID == patchID) return candidate;
    }
    return nil;
}

- (BOOL)setEnabled:(BOOL)enabled forRecord:(ZNStaticPatchRecord *)record error:(NSString **)error {
    if (!record || !record.entry || !record.dispatchEntry || !record.imageBase || !record.siteKey.length) {
        if (error) *error = @"Static Dispatch 记录无效";
        return NO;
    }

    NSMutableArray<NSNumber *> *owners = self.ownerOrderBySite[record.siteKey];
    if (!owners) {
        owners = [NSMutableArray array];
        self.ownerOrderBySite[record.siteKey] = owners;
    }
    NSArray<NSNumber *> *previousOwners = [owners copy];
    uintptr_t previousTarget = __atomic_load_n((uintptr_t *)&record.dispatchEntry->selectedTarget, __ATOMIC_ACQUIRE);
    NSNumber *ownerID = @(record.patchID);

    [owners removeObject:ownerID];
    if (enabled) [owners addObject:ownerID];

    uintptr_t target = record.imageBase + (uintptr_t)record.offRVA;
    ZNStaticPatchRecord *selectedRecord = nil;
    if (owners.count) {
        uint32_t selectedID = owners.lastObject.unsignedIntValue;
        selectedRecord = [self zn44_recordForPatchID:selectedID siteKey:record.siteKey];
        if (!selectedRecord || !selectedRecord.onRVA) {
            [owners setArray:previousOwners];
            if (error) *error = @"Shared Site Owner Stack 无法解析当前 Variant";
            return NO;
        }
        target = record.imageBase + (uintptr_t)selectedRecord.onRVA;
    }

    __atomic_store_n((uintptr_t *)&record.dispatchEntry->selectedTarget, target, __ATOMIC_RELEASE);
    uintptr_t readback = __atomic_load_n((uintptr_t *)&record.dispatchEntry->selectedTarget, __ATOMIC_ACQUIRE);
    if (readback != target) {
        [owners setArray:previousOwners];
        __atomic_store_n((uintptr_t *)&record.dispatchEntry->selectedTarget, previousTarget, __ATOMIC_RELEASE);
        if (error) *error = @"RW selectedTarget read-back 不一致";
        return NO;
    }

    for (ZNStaticPatchRecord *candidate in self.records) {
        if ([candidate.siteKey isEqualToString:record.siteKey]) {
            candidate.enabled = [owners containsObject:@(candidate.patchID)];
        }
    }

    NSString *selected = selectedRecord ? (selectedRecord.group.length ? selectedRecord.group : selectedRecord.title) : @"Original";
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[static-dispatch-v2] %@ %@ owner=%u owners=%lu selected=%@ physical=%u",
                                          enabled ? @"ON" : @"OFF",
                                          record.target,
                                          record.patchID,
                                          (unsigned long)owners.count,
                                          selected,
                                          record.physicalID]];
    return YES;
}

- (NSArray<NSString *> *)diagnosticLines {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableSet<NSString *> *sites = [NSMutableSet set];
    for (ZNStaticPatchRecord *r in self.records) if (r.siteKey.length) [sites addObject:r.siteKey];
    NSUInteger payloadV2 = 0; for (ZNStaticPatchRecord *r in self.records) if (r.payloadProtectionV2) payloadV2++;
    [lines addObject:[NSString stringWithFormat:@"Static Dispatch：%lu 逻辑项 / %lu 物理 Site · Payload V2 %lu/%lu", (unsigned long)self.records.count, (unsigned long)sites.count, (unsigned long)payloadV2, (unsigned long)self.records.count]];
    [lines addObject:[NSString stringWithFormat:@"最近扫描：%.1fms · %@", self.lastRefreshMilliseconds, self.lastDiscoverySummary.length ? self.lastDiscoverySummary : @"尚未执行"]];
    for (ZNStaticPatchRecord *r in self.records) {
        NSArray *owners = self.ownerOrderBySite[r.siteKey] ?: @[];
        [lines addObject:[NSString stringWithFormat:@"%@ · %@ · %@ · owners=%lu", r.title, r.target, r.enabled ? @"ON" : @"OFF", (unsigned long)owners.count]];
        if (lines.count >= 12) break;
    }
    return lines;
}

@end

extern "C" void ZNPrepareStaticDispatchRuntimeDeferred(void) {
    @autoreleasepool {
        ZNStaticDispatchRuntime *runtime = [ZNStaticDispatchRuntime sharedRuntime];
        ZNActivationTraceLog(@"[static-dispatch] prepare complete; initial refresh requested +350ms");
        [runtime zn44_scheduleRefreshAfter:0.35 reason:@"first-activation"];
    }
}
