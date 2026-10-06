#import "ZNStaticBinaryBuilder.h"
#import "ZNStaticBinaryBuilderV3Internal.h"
#import "ZNBinaryPatchWorkspace.h"
#import "ZNPatchRuntimeValidator.h"
#import "ZNPatchCore.h"
#import "ZNStaticPatchFormat.h"
#import "ZNStaticPayloadProtectionV2.h"
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <mach/vm_prot.h>
#import <objc/runtime.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <stdlib.h>
#import <vector>
#import <algorithm>

// Static Binary Builder V3 — owned-segment allocator.
//
// Architectural rule implemented by this builder:
//   * Existing target Mach-O storage is target state only. Never treat zero
//     padding, __bss, __thread_bss, __common, or an unclaimed code/data gap as
//     persistent ZonoPatch storage.
//   * Generated executable dispatch code lives only in a new __ZNTEXT/__zncode
//     segment owned by ZonoPatch.
//   * Generated Static Dispatch metadata + selectedTarget live only in a new
//     __ZNDATA/__zndata segment owned by ZonoPatch.
//   * Runtime Feature/owner/UI state continues to live in the ZonoPatch dylib.
//
// Phase-1 V3 intentionally requires existing load-command header slack. If the
// target cannot safely fit two new LC_SEGMENT_64 commands, generation refuses
// instead of moving original __TEXT content or falling back to a guessed gap.

static const uint64_t kZNV3Page = 0x4000ULL;
static const char kZNV3TextSegment[] = "__ZNTEXT";
static const char kZNV3TextSection[] = "__zncode";
static const char kZNV3DataSegment[] = "__ZNDATA";
static const char kZNV3DataSection[] = "__zndata";

struct ZNV3Section {
    uint64_t fileStart;
    uint64_t fileEnd;
    uint64_t addr;
    uint64_t size;
    uint32_t flags;
    bool fileBacked;
};

struct ZNV3Segment {
    uint64_t vmaddr;
    uint64_t vmsize;
    uint64_t fileoff;
    uint64_t filesize;
    vm_prot_t initprot;
    vm_prot_t maxprot;
    char name[17];
    std::vector<ZNV3Section> sections;
};

struct ZNV3Layout {
    uint64_t imageVMBase;
    uint64_t firstFileSectionOffset;
    uint64_t oldCommandEnd;
    uint64_t linkeditCommandOffset;
    uint64_t linkeditVMAddr;
    uint64_t linkeditVMSize;
    uint64_t linkeditFileOffset;
    uint64_t linkeditFileSize;
};

struct ZNV3Logical {
    __unsafe_unretained ZNBinaryPatchRow *row;
    uint64_t rva;
    uint64_t fileoff;
    uint64_t length;
    size_t segIndex;
    NSData *original;
    NSData *enabled;
};

struct ZNV3Physical {
    uint64_t rva;
    uint64_t fileoff;
    uint64_t window;
    size_t segIndex;
    std::vector<size_t> members;
    NSData *original;
    uint64_t thunkRVA;
    uint64_t offRVA;
};

struct ZNV3OwnedSegmentCommand {
    struct segment_command_64 segment;
    struct section_64 section;
};

static_assert(sizeof(ZNV3OwnedSegmentCommand) == sizeof(struct segment_command_64) + sizeof(struct section_64), "owned segment load command ABI");

static uint64_t ZNV3Align(uint64_t value, uint64_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

static int64_t ZNV3SX(uint64_t value, int bits) {
    uint64_t sign = 1ULL << (bits - 1);
    return (int64_t)((value ^ sign) - sign);
}

static uint32_t ZNV3Read32(const uint8_t *p) {
    uint32_t value = 0;
    memcpy(&value, p, sizeof(value));
    return value;
}

static void ZNV3Write32(uint8_t *p, uint32_t value) {
    memcpy(p, &value, sizeof(value));
}

static BOOL ZNV3Parse(uint8_t *base,
                      size_t size,
                      std::vector<ZNV3Segment> &segments,
                      ZNV3Layout &layout,
                      NSString **error) {
    if (size < sizeof(struct mach_header_64)) {
        if (error) *error = @"Mach-O 太小";
        return NO;
    }
    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    if (mh->magic != MH_MAGIC_64) {
        if (error) *error = @"Static Builder V3 Phase 1 仅支持 thin 64-bit Mach-O";
        return NO;
    }
    if (mh->cputype != CPU_TYPE_ARM64) {
        if (error) *error = @"目标不是 arm64/arm64e Mach-O";
        return NO;
    }
#ifdef MH_FILESET
    if (mh->filetype == MH_FILESET) {
        if (error) *error = @"Static Builder V3 Phase 1 暂不处理 MH_FILESET";
        return NO;
    }
#endif
    uint64_t commandEnd = sizeof(*mh) + (uint64_t)mh->sizeofcmds;
    if (commandEnd > size) {
        if (error) *error = @"Mach-O load commands 越界";
        return NO;
    }

    memset(&layout, 0, sizeof(layout));
    layout.imageVMBase = UINT64_MAX;
    layout.firstFileSectionOffset = UINT64_MAX;
    layout.oldCommandEnd = commandEnd;
    layout.linkeditCommandOffset = UINT64_MAX;

    uint8_t *cursor = base + sizeof(*mh);
    uint8_t *commandLimit = base + commandEnd;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commandLimit) {
            if (error) *error = @"load command 损坏";
            return NO;
        }
        struct load_command *lc = (struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command) || cursor + lc->cmdsize > commandLimit) {
            if (error) *error = @"load command size 损坏";
            return NO;
        }
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cursor;
            if (seg->fileoff > size || seg->filesize > size - seg->fileoff) {
                if (error) *error = @"segment file range 越界";
                return NO;
            }
            ZNV3Segment parsed = {};
            parsed.vmaddr = seg->vmaddr;
            parsed.vmsize = seg->vmsize;
            parsed.fileoff = seg->fileoff;
            parsed.filesize = seg->filesize;
            parsed.initprot = seg->initprot;
            parsed.maxprot = seg->maxprot;
            memcpy(parsed.name, seg->segname, 16);
            parsed.name[16] = 0;

            if (strncmp(seg->segname, SEG_TEXT, 16) == 0) layout.imageVMBase = seg->vmaddr;
            if (strncmp(seg->segname, SEG_LINKEDIT, 16) == 0) {
                layout.linkeditCommandOffset = (uint64_t)(cursor - base);
                layout.linkeditVMAddr = seg->vmaddr;
                layout.linkeditVMSize = seg->vmsize;
                layout.linkeditFileOffset = seg->fileoff;
                layout.linkeditFileSize = seg->filesize;
            }

            uint64_t sectionBytes = (uint64_t)seg->nsects * sizeof(struct section_64);
            if (lc->cmdsize < sizeof(struct segment_command_64) + sectionBytes) {
                if (error) *error = @"segment section table 越界";
                return NO;
            }
            struct section_64 *sec = (struct section_64 *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++) {
                uint32_t type = sec[j].flags & SECTION_TYPE;
                BOOL zeroFill = (type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL);
                BOOL fileBacked = !zeroFill && sec[j].size && sec[j].offset;
                uint64_t fileStart = fileBacked ? sec[j].offset : 0;
                uint64_t fileEnd = fileBacked ? fileStart + sec[j].size : 0;
                if (fileBacked) {
                    if (fileStart > size || sec[j].size > size - fileStart) {
                        if (error) *error = @"section file range 越界";
                        return NO;
                    }
                    layout.firstFileSectionOffset = std::min(layout.firstFileSectionOffset, fileStart);
                }
                parsed.sections.push_back({fileStart, fileEnd, sec[j].addr, sec[j].size, sec[j].flags, (bool)fileBacked});
            }
            segments.push_back(parsed);
        }
        cursor += lc->cmdsize;
    }

    if (layout.imageVMBase == UINT64_MAX) {
        if (error) *error = @"未找到 __TEXT segment";
        return NO;
    }
    if (layout.linkeditCommandOffset == UINT64_MAX || !layout.linkeditFileOffset || !layout.linkeditFileSize) {
        if (error) *error = @"未找到可移动的 __LINKEDIT segment";
        return NO;
    }
    if (layout.linkeditFileOffset + layout.linkeditFileSize > size) {
        if (error) *error = @"__LINKEDIT 超出文件范围";
        return NO;
    }
    if (layout.firstFileSectionOffset == UINT64_MAX) {
        if (error) *error = @"无法确定首个 file-backed section";
        return NO;
    }
    return YES;
}

static BOOL ZNV3RVAToFile(const std::vector<ZNV3Segment> &segments,
                          uint64_t imageVMBase,
                          uint64_t rva,
                          uint64_t length,
                          uint64_t &fileOffset,
                          size_t &segmentIndex) {
    uint64_t va = imageVMBase + rva;
    for (size_t i = 0; i < segments.size(); i++) {
        const ZNV3Segment &seg = segments[i];
        if (va >= seg.vmaddr && va + length <= seg.vmaddr + seg.filesize) {
            fileOffset = seg.fileoff + (va - seg.vmaddr);
            segmentIndex = i;
            return YES;
        }
    }
    return NO;
}

static BOOL ZNV3InstructionRange(const std::vector<ZNV3Segment> &segments,
                                 uint64_t imageVMBase,
                                 uint64_t rva,
                                 uint64_t length) {
    uint64_t va = imageVMBase + rva;
    for (const ZNV3Segment &seg : segments) {
        if (!(seg.initprot & VM_PROT_EXECUTE)) continue;
        for (const ZNV3Section &sec : seg.sections) {
            if (!sec.fileBacked) continue;
            if (!(sec.flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))) continue;
            if (va >= sec.addr && va + length <= sec.addr + sec.size) return YES;
        }
    }
    return NO;
}

static BOOL ZNV3EncodeB(uint64_t fromRVA, uint64_t toRVA, BOOL link, uint32_t *outInstruction) {
    int64_t delta = (int64_t)toRVA - (int64_t)fromRVA;
    if ((delta & 3) || delta < -(1LL << 27) || delta >= (1LL << 27)) return NO;
    uint32_t imm26 = (uint32_t)((delta >> 2) & 0x03FFFFFFu);
    *outInstruction = (link ? 0x94000000u : 0x14000000u) | imm26;
    return YES;
}

static BOOL ZNV3EncodeADRPX17(uint64_t fromRVA, uint64_t toRVA, uint32_t *outInstruction) {
    int64_t pages = ((int64_t)(toRVA & ~0xFFFULL) - (int64_t)(fromRVA & ~0xFFFULL)) >> 12;
    if (pages < -(1LL << 20) || pages >= (1LL << 20)) return NO;
    uint64_t imm = (uint64_t)pages & 0x1FFFFFu;
    *outInstruction = 0x90000000u | ((uint32_t)(imm & 3u) << 29) |
                      ((uint32_t)((imm >> 2) & 0x7FFFFu) << 5) | 17u;
    return YES;
}

static uint32_t ZNV3LdrX17FromX17(uint64_t targetRVA) {
    uint32_t imm12 = (uint32_t)((targetRVA & 0xFFFULL) >> 3);
    return 0xF9400000u | (imm12 << 10) | (17u << 5) | 17u;
}

static BOOL ZNV3IsRET(uint32_t instruction) { return (instruction & 0xFFFFFC1Fu) == 0xD65F0000u; }
static BOOL ZNV3IsBR(uint32_t instruction) { return (instruction & 0xFFFFFC1Fu) == 0xD61F0000u; }

static BOOL ZNV3Relocate(uint32_t instruction,
                         uint64_t sourceRVA,
                         uint64_t destinationRVA,
                         uint64_t windowStart,
                         uint64_t windowEnd,
                         uint32_t *outInstruction,
                         BOOL *terminal,
                         NSString **error) {
    *terminal = NO;
    if ((instruction & 0x7C000000u) == 0x14000000u) {
        BOOL link = (instruction & 0x80000000u) != 0;
        int64_t delta = ZNV3SX(instruction & 0x03FFFFFFu, 26) << 2;
        uint64_t target = (uint64_t)((int64_t)sourceRVA + delta);
        if (target >= windowStart && target < windowEnd) { if(error)*error=@"PC-relative B/BL 指向覆盖窗口内部"; return NO; }
        if (!ZNV3EncodeB(destinationRVA, target, link, outInstruction)) { if(error)*error=@"重定位 B/BL 超出 ±128MB"; return NO; }
        *terminal = !link;
        return YES;
    }
    if ((instruction & 0xFF000010u) == 0x54000000u ||
        (instruction & 0x7E000000u) == 0x34000000u ||
        (instruction & 0x3B000000u) == 0x18000000u) {
        int64_t delta = ZNV3SX((instruction >> 5) & 0x7FFFFu, 19) << 2;
        uint64_t target = (uint64_t)((int64_t)sourceRVA + delta);
        if (target >= windowStart && target < windowEnd) { if(error)*error=@"PC-relative imm19 指向覆盖窗口内部"; return NO; }
        int64_t newDelta = (int64_t)target - (int64_t)destinationRVA;
        if ((newDelta & 3) || newDelta < -(1LL << 20) || newDelta >= (1LL << 20)) { if(error)*error=@"重定位 imm19 超出 ±1MB"; return NO; }
        *outInstruction = (instruction & ~0x00FFFFE0u) | (((uint32_t)(newDelta >> 2) & 0x7FFFFu) << 5);
        return YES;
    }
    if ((instruction & 0x7E000000u) == 0x36000000u) {
        int64_t delta = ZNV3SX((instruction >> 5) & 0x3FFFu, 14) << 2;
        uint64_t target = (uint64_t)((int64_t)sourceRVA + delta);
        if (target >= windowStart && target < windowEnd) { if(error)*error=@"TBZ/TBNZ 指向覆盖窗口内部"; return NO; }
        int64_t newDelta = (int64_t)target - (int64_t)destinationRVA;
        if ((newDelta & 3) || newDelta < -(1LL << 15) || newDelta >= (1LL << 15)) { if(error)*error=@"重定位 TBZ/TBNZ 超出 ±32KB"; return NO; }
        *outInstruction = (instruction & ~0x0007FFE0u) | (((uint32_t)(newDelta >> 2) & 0x3FFFu) << 5);
        return YES;
    }
    uint32_t adrMask = instruction & 0x9F000000u;
    if (adrMask == 0x10000000u || adrMask == 0x90000000u) {
        uint64_t imm = ((uint64_t)((instruction >> 5) & 0x7FFFFu) << 2) | ((instruction >> 29) & 3u);
        int64_t signedImm = ZNV3SX(imm, 21);
        uint64_t target = adrMask == 0x90000000u
            ? (uint64_t)((int64_t)(sourceRVA & ~0xFFFULL) + (signedImm << 12))
            : (uint64_t)((int64_t)sourceRVA + signedImm);
        if (target >= windowStart && target < windowEnd) { if(error)*error=@"ADR/ADRP 指向覆盖窗口内部"; return NO; }
        int64_t newImm = adrMask == 0x90000000u
            ? (((int64_t)(target & ~0xFFFULL) - (int64_t)(destinationRVA & ~0xFFFULL)) >> 12)
            : ((int64_t)target - (int64_t)destinationRVA);
        if (newImm < -(1LL << 20) || newImm >= (1LL << 20)) { if(error)*error=@"重定位 ADR/ADRP 超范围"; return NO; }
        uint64_t u = (uint64_t)newImm & 0x1FFFFFu;
        *outInstruction = (instruction & ~((3u << 29) | (0x7FFFFu << 5))) |
                          ((uint32_t)(u & 3u) << 29) |
                          ((uint32_t)((u >> 2) & 0x7FFFFu) << 5);
        return YES;
    }
    *outInstruction = instruction;
    if (ZNV3IsRET(instruction) || ZNV3IsBR(instruction)) *terminal = YES;
    return YES;
}

static BOOL ZNV3InboundInterior(const uint8_t *base,
                                const std::vector<ZNV3Segment> &segments,
                                uint64_t imageVMBase,
                                uint64_t siteRVA,
                                uint64_t length) {
    uint64_t endRVA = siteRVA + length;
    for (const ZNV3Segment &seg : segments) {
        if (!(seg.initprot & VM_PROT_EXECUTE)) continue;
        for (const ZNV3Section &sec : seg.sections) {
            if (!sec.fileBacked) continue;
            if (!(sec.flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))) continue;
            if (sec.fileEnd <= sec.fileStart) continue;
            for (uint64_t offset = sec.fileStart; offset + 4 <= sec.fileEnd; offset += 4) {
                uint32_t instruction = ZNV3Read32(base + offset);
                uint64_t sourceRVA = sec.addr + (offset - sec.fileStart) - imageVMBase;
                uint64_t targetRVA = 0;
                BOOL direct = NO;
                if ((instruction & 0x7C000000u) == 0x14000000u) {
                    targetRVA = (uint64_t)((int64_t)sourceRVA + (ZNV3SX(instruction & 0x03FFFFFFu, 26) << 2));
                    direct = YES;
                } else if ((instruction & 0xFF000010u) == 0x54000000u || (instruction & 0x7E000000u) == 0x34000000u) {
                    targetRVA = (uint64_t)((int64_t)sourceRVA + (ZNV3SX((instruction >> 5) & 0x7FFFFu, 19) << 2));
                    direct = YES;
                } else if ((instruction & 0x7E000000u) == 0x36000000u) {
                    targetRVA = (uint64_t)((int64_t)sourceRVA + (ZNV3SX((instruction >> 5) & 0x3FFFu, 14) << 2));
                    direct = YES;
                }
                if (direct && targetRVA > siteRVA && targetRVA < endRVA) return YES;
            }
        }
    }
    return NO;
}

static BOOL ZNV3WriteVariantV2(uint8_t *base,
                               uint64_t fileOffset,
                               uint64_t variantRVA,
                               uint64_t reserved,
                               NSData *source,
                               uint64_t sourceRVA,
                               uint64_t windowStart,
                               uint64_t windowEnd,
                               uint64_t resumeRVA,
                               uint64_t layoutState,
                               uint64_t *entryRVAOut,
                               uint32_t *fragmentCountOut,
                               NSString **error) {
    const uint32_t NOP = 0xD503201Fu;
    const uint32_t LDP_X16_X17_POST = 0xA8C147F0u;
    if (!source.length || (source.length & 3u)) {
        if (error) *error = @"Protection V2 Variant 长度必须为 4-byte 倍数";
        return NO;
    }

    uint64_t slotCount64 = source.length / 4u;
    uint64_t required = ZN60VariantReservedBytes((uint64_t)source.length);
    if (!required || reserved < required || slotCount64 > UINT32_MAX) {
        if (error) *error = @"Protection V2 Variant slot 预算无效";
        return NO;
    }
    for (uint64_t p = 0; p < reserved; p += 4) ZNV3Write32(base + fileOffset + p, NOP);

    std::vector<uint32_t> slots((size_t)slotCount64);
    for (uint32_t i = 0; i < (uint32_t)slotCount64; ++i) slots[i] = i;
    ZN60ShuffleU32(slots.data(), slots.size(), layoutState);
    if (!ZN60IsPermutationU32(slots.data(), slots.size())) {
        if (error) *error = @"Protection V2 slot permutation 损坏";
        return NO;
    }

    const uint8_t *sourceBytes = (const uint8_t *)source.bytes;
    BOOL terminalSeen = NO;
    uint32_t emitted = 0;
    if (entryRVAOut) *entryRVAOut = variantRVA + (uint64_t)slots[0] * ZN60_PAYLOAD_SLOT_SIZE;

    for (uint32_t logicalIndex = 0; logicalIndex < (uint32_t)slotCount64; ++logicalIndex) {
        if (terminalSeen) break;
        uint64_t slotOffset = (uint64_t)slots[logicalIndex] * ZN60_PAYLOAD_SLOT_SIZE;
        uint64_t instructionFileOffset = fileOffset + slotOffset;
        uint64_t instructionRVA = variantRVA + slotOffset;

        // Only the entry fragment restores registers saved by the dispatch thunk.
        if (logicalIndex == 0) {
            ZNV3Write32(base + instructionFileOffset, LDP_X16_X17_POST);
            instructionFileOffset += 4;
            instructionRVA += 4;
        }

        uint32_t relocated = 0;
        BOOL terminal = NO;
        uint64_t originalInstructionRVA = sourceRVA + (uint64_t)logicalIndex * 4u;
        if (!ZNV3Relocate(ZNV3Read32(sourceBytes + (size_t)logicalIndex * 4u),
                          originalInstructionRVA,
                          instructionRVA,
                          windowStart,
                          windowEnd,
                          &relocated,
                          &terminal,
                          error)) return NO;
        ZNV3Write32(base + instructionFileOffset, relocated);
        emitted++;

        if (terminal) {
            terminalSeen = YES;
            continue;
        }

        uint64_t branchInstructionRVA = instructionRVA + 4u;
        uint64_t nextRVA = resumeRVA;
        if (logicalIndex + 1u < (uint32_t)slotCount64) {
            nextRVA = variantRVA + (uint64_t)slots[logicalIndex + 1u] * ZN60_PAYLOAD_SLOT_SIZE;
        }
        uint32_t nextBranch = 0;
        if (!ZNV3EncodeB(branchInstructionRVA, nextRVA, NO, &nextBranch)) {
            if (error) *error = @"Protection V2 fragment 链超出 ARM64 B ±128MB";
            return NO;
        }
        ZNV3Write32(base + instructionFileOffset + 4u, nextBranch);
    }

    if (fragmentCountOut) *fragmentCountOut = emitted;
    return YES;
}

static BOOL ZNV3WriteThunkV2(uint8_t *base,
                             uint64_t fileOffset,
                             uint64_t thunkRVA,
                             uint64_t reserved,
                             uint64_t selectedTargetEntryRVA,
                             uint64_t offRVA,
                             uint64_t layoutState,
                             NSString **error) {
    const uint32_t STP_X16_X17_PRE = 0xA9BF47F0u;
    const uint32_t BR_X17 = 0xD61F0220u;
    const uint32_t NOP = 0xD503201Fu;
    if (reserved < 32u) {
        if (error) *error = @"Protection V2 thunk 预算不足";
        return NO;
    }
    for (uint64_t p = 0; p < reserved; p += 4) ZNV3Write32(base + fileOffset + p, NOP);

    uint32_t nopCount = (uint32_t)(ZN60NextLayoutWord(&layoutState) % 3u);
    uint64_t offBranchRVA = thunkRVA + 16u + (uint64_t)nopCount * 4u;
    uint64_t selectedBranchRVA = offBranchRVA + 4u;
    uint64_t cbnzRVA = thunkRVA + 12u;
    int64_t cbnzDelta = (int64_t)selectedBranchRVA - (int64_t)cbnzRVA;
    if ((cbnzDelta & 3) || cbnzDelta <= 0 || cbnzDelta >= (1LL << 20)) {
        if (error) *error = @"Protection V2 thunk CBNZ 布局无效";
        return NO;
    }
    uint32_t cbnz = 0xB5000011u | (((uint32_t)(cbnzDelta >> 2) & 0x7FFFFu) << 5);

    uint32_t adrp = 0;
    uint32_t offBranch = 0;
    if (!ZNV3EncodeADRPX17(thunkRVA + 4u, selectedTargetEntryRVA, &adrp)) {
        if (error) *error = @"Protection V2 thunk → selectedTarget ADRP 超出 ±4GB";
        return NO;
    }
    if (!ZNV3EncodeB(offBranchRVA, offRVA, NO, &offBranch)) {
        if (error) *error = @"Protection V2 thunk OFF fallback 超出 ARM64 B ±128MB";
        return NO;
    }

    ZNV3Write32(base + fileOffset + 0u, STP_X16_X17_PRE);
    ZNV3Write32(base + fileOffset + 4u, adrp);
    ZNV3Write32(base + fileOffset + 8u, ZNV3LdrX17FromX17(selectedTargetEntryRVA));
    ZNV3Write32(base + fileOffset + 12u, cbnz);
    for (uint32_t i = 0; i < nopCount; ++i) ZNV3Write32(base + fileOffset + 16u + (uint64_t)i * 4u, NOP);
    ZNV3Write32(base + fileOffset + 16u + (uint64_t)nopCount * 4u, offBranch);
    ZNV3Write32(base + fileOffset + 20u + (uint64_t)nopCount * 4u, BR_X17);
    return YES;
}

static void ZNV3CopyFixed(char *destination, size_t capacity, NSString *string) {
    memset(destination, 0, capacity);
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || !capacity) return;
    memcpy(destination, data.bytes, std::min(capacity - 1, (size_t)data.length));
}

static NSData *ZNV3ComposedVariant(const ZNV3Physical &physical, const ZNV3Logical &logical) {
    NSMutableData *data = [physical.original mutableCopy];
    if (!data || logical.enabled.length > data.length) return nil;
    [data replaceBytesInRange:NSMakeRange(0, logical.enabled.length) withBytes:logical.enabled.bytes];
    return data;
}

static BOOL ZNV3ShiftU32(uint32_t *field, uint64_t threshold, uint64_t delta, NSString **error) {
    if (!field || !*field || (uint64_t)*field < threshold) return YES;
    uint64_t shifted = (uint64_t)*field + delta;
    if (shifted > UINT32_MAX) {
        if (error) *error = @"__LINKEDIT file offset 超过 32-bit load-command 字段范围";
        return NO;
    }
    *field = (uint32_t)shifted;
    return YES;
}

static BOOL ZNV3ShiftLinkeditReferences(uint8_t *base,
                                        uint64_t size,
                                        uint64_t oldLinkeditFileOffset,
                                        uint64_t oldLinkeditVMAddr,
                                        uint64_t delta,
                                        NSString **error) {
    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    uint8_t *cursor = base + sizeof(*mh);
    uint8_t *end = cursor + mh->sizeofcmds;
    if (end > base + size) { if(error)*error=@"扩展后的 load commands 越界"; return NO; }

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > end) { if(error)*error=@"扩展后的 load command 损坏"; return NO; }
        struct load_command *lc = (struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > end) { if(error)*error=@"扩展后的 load command size 损坏"; return NO; }

        switch (lc->cmd) {
            case LC_SEGMENT_64: {
                struct segment_command_64 *seg = (struct segment_command_64 *)cursor;
                if (strncmp(seg->segname, SEG_LINKEDIT, 16) == 0) {
                    seg->fileoff += delta;
                    seg->vmaddr += delta;
                }
                break;
            }
            case LC_DYLD_INFO:
            case LC_DYLD_INFO_ONLY: {
                struct dyld_info_command *d = (struct dyld_info_command *)cursor;
                if (!ZNV3ShiftU32(&d->rebase_off, oldLinkeditFileOffset, delta, error) ||
                    !ZNV3ShiftU32(&d->bind_off, oldLinkeditFileOffset, delta, error) ||
                    !ZNV3ShiftU32(&d->weak_bind_off, oldLinkeditFileOffset, delta, error) ||
                    !ZNV3ShiftU32(&d->lazy_bind_off, oldLinkeditFileOffset, delta, error) ||
                    !ZNV3ShiftU32(&d->export_off, oldLinkeditFileOffset, delta, error)) return NO;
                break;
            }
            case LC_SYMTAB: {
                struct symtab_command *s = (struct symtab_command *)cursor;
                if (!ZNV3ShiftU32(&s->symoff, oldLinkeditFileOffset, delta, error) ||
                    !ZNV3ShiftU32(&s->stroff, oldLinkeditFileOffset, delta, error)) return NO;
                break;
            }
            case LC_DYSYMTAB: {
                struct dysymtab_command *d = (struct dysymtab_command *)cursor;
                if (!ZNV3ShiftU32(&d->tocoff, oldLinkeditFileOffset, delta, error) ||
                    !ZNV3ShiftU32(&d->modtaboff, oldLinkeditFileOffset, delta, error) ||
                    !ZNV3ShiftU32(&d->extrefsymoff, oldLinkeditFileOffset, delta, error) ||
                    !ZNV3ShiftU32(&d->indirectsymoff, oldLinkeditFileOffset, delta, error) ||
                    !ZNV3ShiftU32(&d->extreloff, oldLinkeditFileOffset, delta, error) ||
                    !ZNV3ShiftU32(&d->locreloff, oldLinkeditFileOffset, delta, error)) return NO;
                break;
            }
            case LC_TWOLEVEL_HINTS: {
                struct twolevel_hints_command *h = (struct twolevel_hints_command *)cursor;
                if (!ZNV3ShiftU32(&h->offset, oldLinkeditFileOffset, delta, error)) return NO;
                break;
            }
            case LC_CODE_SIGNATURE:
            case LC_SEGMENT_SPLIT_INFO:
            case LC_FUNCTION_STARTS:
            case LC_DATA_IN_CODE:
#ifdef LC_DYLIB_CODE_SIGN_DRS
            case LC_DYLIB_CODE_SIGN_DRS:
#endif
#ifdef LC_LINKER_OPTIMIZATION_HINT
            case LC_LINKER_OPTIMIZATION_HINT:
#endif
#ifdef LC_DYLD_EXPORTS_TRIE
            case LC_DYLD_EXPORTS_TRIE:
#endif
#ifdef LC_DYLD_CHAINED_FIXUPS
            case LC_DYLD_CHAINED_FIXUPS:
#endif
            {
                struct linkedit_data_command *d = (struct linkedit_data_command *)cursor;
                if (!ZNV3ShiftU32(&d->dataoff, oldLinkeditFileOffset, delta, error)) return NO;
                break;
            }
#ifdef LC_NOTE
            case LC_NOTE: {
                struct note_command *n = (struct note_command *)cursor;
                if (n->offset && n->offset >= oldLinkeditFileOffset) n->offset += delta;
                break;
            }
#endif
            default:
                break;
        }
        cursor += lc->cmdsize;
    }

    (void)oldLinkeditVMAddr;
    return YES;
}

static void ZNV3FillOwnedSegment(ZNV3OwnedSegmentCommand &command,
                                 const char *segmentName,
                                 const char *sectionName,
                                 uint64_t vmaddr,
                                 uint64_t vmsize,
                                 uint64_t fileoff,
                                 uint64_t filesize,
                                 vm_prot_t prot,
                                 uint64_t sectionSize,
                                 uint32_t alignPower,
                                 uint32_t sectionFlags) {
    memset(&command, 0, sizeof(command));
    command.segment.cmd = LC_SEGMENT_64;
    command.segment.cmdsize = sizeof(command);
    strncpy(command.segment.segname, segmentName, sizeof(command.segment.segname));
    command.segment.vmaddr = vmaddr;
    command.segment.vmsize = vmsize;
    command.segment.fileoff = fileoff;
    command.segment.filesize = filesize;
    command.segment.maxprot = prot;
    command.segment.initprot = prot;
    command.segment.nsects = 1;

    strncpy(command.section.sectname, sectionName, sizeof(command.section.sectname));
    strncpy(command.section.segname, segmentName, sizeof(command.section.segname));
    command.section.addr = vmaddr;
    command.section.size = sectionSize;
    command.section.offset = (uint32_t)fileoff;
    command.section.align = alignPower;
    command.section.flags = sectionFlags;
}

static BOOL ZNV3InstallOwnedSegments(uint8_t *base,
                                     uint64_t newFileSize,
                                     const ZNV3Layout &layout,
                                     uint64_t codeSegmentSize,
                                     uint64_t dataSegmentSize,
                                     uint64_t codeUsed,
                                     uint64_t dataUsed,
                                     uint64_t *codeFileOffset,
                                     uint64_t *codeRVA,
                                     uint64_t *dataFileOffset,
                                     uint64_t *dataRVA,
                                     NSString **error) {
    if (layout.linkeditFileOffset > UINT32_MAX ||
        layout.linkeditFileOffset + codeSegmentSize > UINT32_MAX) {
        if (error) *error = @"V3 Phase 1 新 section file offset 超过 32-bit section.offset";
        return NO;
    }

    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    const uint64_t extraCommands = 2ULL * sizeof(ZNV3OwnedSegmentCommand);
    if (layout.oldCommandEnd + extraCommands > layout.firstFileSectionOffset) {
        if (error) *error = [NSString stringWithFormat:@"V3 Phase 1 load-command 空间不足：需要 0x%llX，Header slack 仅 0x%llX；拒绝回退到 code/data gap",
                            extraCommands,
                            layout.firstFileSectionOffset > layout.oldCommandEnd ? layout.firstFileSectionOffset - layout.oldCommandEnd : 0];
        return NO;
    }
    if (layout.linkeditCommandOffset < sizeof(*mh) || layout.linkeditCommandOffset > layout.oldCommandEnd) {
        if (error) *error = @"__LINKEDIT load command 位置异常";
        return NO;
    }

    const uint64_t insertedBytes = codeSegmentSize + dataSegmentSize;
    if (layout.linkeditFileOffset > newFileSize || insertedBytes > newFileSize - layout.linkeditFileOffset) {
        if (error) *error = @"V3 owned segment 插入范围越界";
        return NO;
    }

    const uint64_t oldFileSize = newFileSize - insertedBytes;
    if (layout.linkeditFileOffset > oldFileSize) { if(error)*error=@"原 __LINKEDIT fileoff 越界"; return NO; }
    memmove(base + layout.linkeditFileOffset + insertedBytes,
            base + layout.linkeditFileOffset,
            oldFileSize - layout.linkeditFileOffset);
    memset(base + layout.linkeditFileOffset, 0, insertedBytes);

    memmove(base + layout.linkeditCommandOffset + extraCommands,
            base + layout.linkeditCommandOffset,
            layout.oldCommandEnd - layout.linkeditCommandOffset);
    memset(base + layout.linkeditCommandOffset, 0, extraCommands);

    uint64_t newSizeOfCmds = (uint64_t)mh->sizeofcmds + extraCommands;
    if (newSizeOfCmds > UINT32_MAX) { if(error)*error=@"sizeofcmds 溢出"; return NO; }
    mh->ncmds += 2;
    mh->sizeofcmds = (uint32_t)newSizeOfCmds;

    uint64_t zntFile = layout.linkeditFileOffset;
    uint64_t zntVM = layout.linkeditVMAddr;
    uint64_t zndFile = zntFile + codeSegmentSize;
    uint64_t zndVM = zntVM + codeSegmentSize;

    ZNV3OwnedSegmentCommand textCommand = {};
    ZNV3OwnedSegmentCommand dataCommand = {};
    ZNV3FillOwnedSegment(textCommand,
                         kZNV3TextSegment,
                         kZNV3TextSection,
                         zntVM,
                         codeSegmentSize,
                         zntFile,
                         codeSegmentSize,
                         VM_PROT_READ | VM_PROT_EXECUTE,
                         codeUsed,
                         4,
                         S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS);
    ZNV3FillOwnedSegment(dataCommand,
                         kZNV3DataSegment,
                         kZNV3DataSection,
                         zndVM,
                         dataSegmentSize,
                         zndFile,
                         dataSegmentSize,
                         VM_PROT_READ | VM_PROT_WRITE,
                         dataUsed,
                         3,
                         S_REGULAR);
    memcpy(base + layout.linkeditCommandOffset, &textCommand, sizeof(textCommand));
    memcpy(base + layout.linkeditCommandOffset + sizeof(textCommand), &dataCommand, sizeof(dataCommand));

    if (!ZNV3ShiftLinkeditReferences(base,
                                     newFileSize,
                                     layout.linkeditFileOffset,
                                     layout.linkeditVMAddr,
                                     insertedBytes,
                                     error)) return NO;

    if (codeFileOffset) *codeFileOffset = zntFile;
    if (dataFileOffset) *dataFileOffset = zndFile;
    if (codeRVA) *codeRVA = zntVM - layout.imageVMBase;
    if (dataRVA) *dataRVA = zndVM - layout.imageVMBase;
    return YES;
}

static BOOL ZNV3BuildTarget(NSString *target,
                            NSArray<ZNBinaryPatchRow *> *rows,
                            NSString *folder,
                            NSString **outPath,
                            NSDictionary **metadata,
                            NSString **error) {
    NSDictionary *module = [[ZNModuleManager sharedManager] moduleNamed:target];
    if (!module) { if(error)*error=[NSString stringWithFormat:@"目标模块未加载：%@",target]; return NO; }
    NSString *inputPath = module[@"path"];
    if (!inputPath.length) { if(error)*error=@"无法取得目标 Mach-O 路径"; return NO; }
    NSString *name = inputPath.lastPathComponent.length ? inputPath.lastPathComponent : target;
    NSString *outputPath = [folder stringByAppendingPathComponent:[name stringByAppendingString:@".znpatched"]];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:outputPath error:nil];
    NSError *copyError = nil;
    if (![fm copyItemAtPath:inputPath toPath:outputPath error:&copyError]) {
        if(error)*error=[NSString stringWithFormat:@"复制目标失败：%@",copyError.localizedDescription?:@"未知错误"];
        return NO;
    }

    int fd = open(outputPath.fileSystemRepresentation, O_RDWR);
    if (fd < 0) { [fm removeItemAtPath:outputPath error:nil]; if(error)*error=[NSString stringWithFormat:@"打开输出文件失败：errno=%d",errno]; return NO; }
    struct stat st = {};
    if (fstat(fd,&st)!=0 || st.st_size<=0) { close(fd); [fm removeItemAtPath:outputPath error:nil]; if(error)*error=@"读取输出文件大小失败"; return NO; }
    uint64_t oldFileSize = (uint64_t)st.st_size;
    uint8_t *oldBase = (uint8_t *)mmap(NULL,(size_t)oldFileSize,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if (oldBase == MAP_FAILED) { close(fd); [fm removeItemAtPath:outputPath error:nil]; if(error)*error=@"mmap 原始输出文件失败"; return NO; }

    BOOL success = NO;
    NSString *localError = nil;
    std::vector<ZNV3Segment> segments;
    ZNV3Layout layout = {};
    std::vector<ZNV3Logical> logicals;
    std::vector<ZNV3Physical> physicals;
    std::vector<size_t> logicalToPhysical;
    uint64_t codeNeeded = 0;
    uint64_t dataNeeded = 0;
    uint64_t codeSegmentSize = 0;
    uint64_t dataSegmentSize = 0;
    uint64_t protectionV2Nonce = 0;
    arc4random_buf(&protectionV2Nonce, sizeof(protectionV2Nonce));
    if (!protectionV2Nonce) protectionV2Nonce = ZN60Mix64((uint64_t)oldFileSize ^ (uint64_t)rows.count ^ UINT64_C(0x605056325A4E));
    uint64_t protectionV2LayoutTag = ZN60Mix64(protectionV2Nonce ^ UINT64_C(0x76302E352E365A4E));
    uint64_t protectionV2Fragments = 0;
    uint64_t protectionV2Variants = 0;

    do {
        if (!ZNV3Parse(oldBase,(size_t)oldFileSize,segments,layout,&localError)) break;
        if (rows.count > ZN44_STATIC_MAX_ENTRIES) { localError=@"Patch 数量超过 Static Dispatch 上限"; break; }

        logicals.reserve(rows.count);
        for (ZNBinaryPatchRow *row in rows) {
            NSData *enabled = row.validator.patchBytes;
            NSData *liveOriginal = row.validator.capturedOriginalBytes;
            if (!enabled.length || !liveOriginal.length || enabled.length != liveOriginal.length || (enabled.length & 3u)) {
                localError=@"Patch 必须已验证，且 Enabled/Original 长度一致并为 4-byte 倍数";
                break;
            }
            uint64_t rva=row.validator.rva,fileOffset=0;
            size_t segmentIndex=0;
            if (!ZNV3RVAToFile(segments,layout.imageVMBase,rva,enabled.length,fileOffset,segmentIndex)) {
                localError=[NSString stringWithFormat:@"%@+0x%llX 无法映射到 file offset",target,rva]; break;
            }
            if (!(segments[segmentIndex].initprot & VM_PROT_EXECUTE) || !ZNV3InstructionRange(segments,layout.imageVMBase,rva,enabled.length)) {
                localError=[NSString stringWithFormat:@"%@+0x%llX 不在可确认的 ARM64 instruction section",target,rva]; break;
            }
            if (fileOffset >= layout.linkeditFileOffset) {
                localError=[NSString stringWithFormat:@"%@+0x%llX 位于 __LINKEDIT 或其后，V3 拒绝",target,rva]; break;
            }
            NSData *diskOriginal=[NSData dataWithBytes:oldBase+fileOffset length:enabled.length];
            if (![diskOriginal isEqualToData:liveOriginal]) {
                localError=[NSString stringWithFormat:@"%@+0x%llX 磁盘原字节与 Live Original 不一致",target,rva]; break;
            }
            logicals.push_back({row,rva,fileOffset,(uint64_t)enabled.length,segmentIndex,diskOriginal,enabled});
        }
        if (localError) break;

        logicalToPhysical.assign(logicals.size(),0);
        for (size_t i=0;i<logicals.size();i++) {
            ZNV3Logical &logical=logicals[i];
            size_t pIndex=SIZE_MAX;
            for(size_t p=0;p<physicals.size();p++) if(physicals[p].rva==logical.rva){pIndex=p;break;}
            if(pIndex==SIZE_MAX){
                ZNV3Physical physical={};
                physical.rva=logical.rva; physical.fileoff=logical.fileoff; physical.window=logical.length; physical.segIndex=logical.segIndex;
                physical.members.push_back(i); physical.original=nil; physical.thunkRVA=0; physical.offRVA=0;
                physicals.push_back(physical); pIndex=physicals.size()-1;
            } else {
                ZNV3Physical &physical=physicals[pIndex];
                physical.window=std::max(physical.window,logical.length);
                physical.members.push_back(i);
            }
            logicalToPhysical[i]=pIndex;
        }

        for(size_t p=0;p<physicals.size();p++) {
            ZNV3Physical &physical=physicals[p];
            uint64_t mapped=0; size_t segIndex=0;
            if(!ZNV3RVAToFile(segments,layout.imageVMBase,physical.rva,physical.window,mapped,segIndex) || mapped!=physical.fileoff || segIndex!=physical.segIndex){
                localError=[NSString stringWithFormat:@"%@+0x%llX Physical Site 最大窗口无法映射",target,physical.rva]; break;
            }
            if(!ZNV3InstructionRange(segments,layout.imageVMBase,physical.rva,physical.window)){
                localError=[NSString stringWithFormat:@"%@+0x%llX Physical Site 最大窗口不在 instruction section",target,physical.rva]; break;
            }
            if(ZNV3InboundInterior(oldBase,segments,layout.imageVMBase,physical.rva,physical.window)){
                localError=[NSString stringWithFormat:@"%@+0x%llX 覆盖窗口内部存在直接分支目标",target,physical.rva]; break;
            }
            physical.original=[NSData dataWithBytes:oldBase+physical.fileoff length:physical.window];
        }
        if(localError)break;

        for(size_t a=0;a<physicals.size();a++){
            for(size_t b=a+1;b<physicals.size();b++){
                uint64_t aStart=physicals[a].rva,aEnd=aStart+physicals[a].window;
                uint64_t bStart=physicals[b].rva,bEnd=bStart+physicals[b].window;
                if(aStart<bEnd&&bStart<aEnd){localError=[NSString stringWithFormat:@"不同起点 Patch 覆盖窗口重叠：0x%llX / 0x%llX",aStart,bStart];break;}
            }
            if(localError)break;
        }
        if(localError)break;

        const uint64_t thunkStride=ZN60_PAYLOAD_THUNK_STRIDE;
        for(const ZNV3Physical &physical:physicals){
            uint64_t variantStride=ZN60VariantStrideBytes(physical.window);
            if(!variantStride){localError=@"Protection V2 Variant stride 计算失败";break;}
            NSMutableArray<NSData *> *unique=[NSMutableArray array];
            for(size_t logicalIndex:physical.members){
                NSData *source=ZNV3ComposedVariant(physical,logicals[logicalIndex]);
                if(!source){localError=@"Variant 合成失败";break;}
                BOOL exists=NO; for(NSData *x in unique)if([x isEqualToData:source]){exists=YES;break;}
                if(!exists)[unique addObject:source];
            }
            if(localError)break;
            codeNeeded=ZNV3Align(codeNeeded,16)+thunkStride+variantStride*(1+unique.count);
        }
        if(localError)break;
        codeNeeded+=64;
        uint64_t staticTableBytes=ZNV3Align(sizeof(ZN44StaticHeader)+logicals.size()*sizeof(ZN44StaticEntry),8);
        uint64_t descriptionBytes=sizeof(ZN44FeatureDescriptionHeader)+logicals.size()*sizeof(ZN44FeatureDescriptionEntry);
        dataNeeded=ZNV3Align(staticTableBytes+descriptionBytes,8);
        codeSegmentSize=ZNV3Align(codeNeeded,kZNV3Page);
        dataSegmentSize=ZNV3Align(dataNeeded,kZNV3Page);

        uint64_t codeRVA=layout.linkeditVMAddr-layout.imageVMBase;
        for(const ZNV3Physical &physical:physicals){
            int64_t delta=(int64_t)codeRVA-(int64_t)physical.rva;
            if(delta<=-(1LL<<27)||delta>=(1LL<<27)){
                localError=[NSString stringWithFormat:@"%@+0x%llX → 新 __ZNTEXT 超出 ARM64 B ±128MB；V3 不回退到 code cave",target,physical.rva];break;
            }
        }
        if(localError)break;

        const uint64_t extraCommands=2ULL*sizeof(ZNV3OwnedSegmentCommand);
        if(layout.oldCommandEnd+extraCommands>layout.firstFileSectionOffset){
            localError=[NSString stringWithFormat:@"V3 Phase 1 Header slack 不足：需要 0x%llX，只有 0x%llX；当前版本不会移动原 __TEXT",extraCommands,layout.firstFileSectionOffset>layout.oldCommandEnd?layout.firstFileSectionOffset-layout.oldCommandEnd:0];break;
        }
    } while(0);

    munmap(oldBase,(size_t)oldFileSize);

    if(!localError){
        uint64_t insertedBytes=codeSegmentSize+dataSegmentSize;
        uint64_t newFileSize=oldFileSize+insertedBytes;
        if(newFileSize>SIZE_MAX){localError=@"扩展后的文件过大";}
        else if(ftruncate(fd,(off_t)newFileSize)!=0){localError=[NSString stringWithFormat:@"扩展输出文件失败：errno=%d",errno];}
        else {
            uint8_t *base=(uint8_t *)mmap(NULL,(size_t)newFileSize,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
            if(base==MAP_FAILED){localError=@"mmap 扩展输出文件失败";}
            else {
                do {
                    uint64_t codeFileOffset=0,codeRVA=0,dataFileOffset=0,dataRVA=0;
                    if(!ZNV3InstallOwnedSegments(base,newFileSize,layout,codeSegmentSize,dataSegmentSize,codeNeeded,dataNeeded,
                                                &codeFileOffset,&codeRVA,&dataFileOffset,&dataRVA,&localError))break;

                    ZN44StaticHeader *header=(ZN44StaticHeader *)(base+dataFileOffset);
                    memset(header,0,dataNeeded);
                    header->magic0=ZN44_STATIC_MAGIC0;
                    header->magic1=ZN44_STATIC_MAGIC1;
                    header->version=ZN44_STATIC_VERSION_V3;
                    header->count=(uint32_t)logicals.size();
                    header->entrySize=sizeof(ZN44StaticEntry);
                    header->flags |= ZN44_STATIC_HEADER_FLAG_PAYLOAD_PROTECTION_V2 | ZN44_STATIC_HEADER_FLAG_GENERATED_LAYOUT_V1;
                    ZN44StaticEntry *entries=(ZN44StaticEntry *)(header+1);
                    std::vector<uint64_t> onRVAs(logicals.size(),0);

                    const uint32_t NOP=0xD503201Fu;
                    const uint64_t thunkStride=ZN60_PAYLOAD_THUNK_STRIDE;
                    uint64_t codeCursor=codeFileOffset;

                    for(size_t p=0;p<physicals.size();p++){
                        ZNV3Physical &physical=physicals[p];
                        uint64_t thunkState=ZN60DeriveLayoutState(protectionV2Nonce,physical.rva,0x80000000u|(uint32_t)p);
                        uint64_t thunkBase=ZNV3Align(codeCursor,16);
                        uint64_t thunkPad=(ZN60NextLayoutWord(&thunkState)&1u)?16u:0u;
                        uint64_t thunkFileOffset=thunkBase+thunkPad;
                        uint64_t thunkRVA=codeRVA+(thunkFileOffset-codeFileOffset);
                        codeCursor=thunkBase+thunkStride;

                        uint64_t variantReserved=ZN60VariantReservedBytes(physical.window);
                        uint64_t variantStride=ZN60VariantStrideBytes(physical.window);
                        if(!variantReserved||!variantStride){localError=@"Protection V2 Variant region 计算失败";break;}

                        uint64_t offState=ZN60DeriveLayoutState(protectionV2Nonce,physical.rva,0u);
                        uint64_t offRegionBase=ZNV3Align(codeCursor,16);
                        uint64_t offPad=(ZN60NextLayoutWord(&offState)%5u)*16u;
                        uint64_t offFileOffset=offRegionBase+offPad;
                        uint64_t offRegionRVA=codeRVA+(offFileOffset-codeFileOffset);
                        codeCursor=offRegionBase+variantStride;
                        uint64_t offRVA=0;
                        uint32_t offFragments=0;
                        if(!ZNV3WriteVariantV2(base,offFileOffset,offRegionRVA,variantReserved,physical.original,physical.rva,
                                               physical.rva,physical.rva+physical.window,physical.rva+physical.window,
                                               offState,&offRVA,&offFragments,&localError))break;
                        protectionV2Variants++;
                        protectionV2Fragments+=offFragments;
                        physical.thunkRVA=thunkRVA;
                        physical.offRVA=offRVA;

                        NSMutableArray<NSData *> *writtenSources=[NSMutableArray array];
                        NSMutableArray<NSNumber *> *writtenRVAs=[NSMutableArray array];
                        for(size_t logicalIndex:physical.members){
                            NSData *source=ZNV3ComposedVariant(physical,logicals[logicalIndex]);
                            NSUInteger found=NSNotFound;
                            for(NSUInteger j=0;j<writtenSources.count;j++)if([writtenSources[j] isEqualToData:source]){found=j;break;}
                            if(found!=NSNotFound){onRVAs[logicalIndex]=writtenRVAs[found].unsignedLongLongValue;continue;}

                            uint32_t variantOrdinal=(uint32_t)writtenSources.count+1u;
                            uint64_t onState=ZN60DeriveLayoutState(protectionV2Nonce,physical.rva,variantOrdinal);
                            uint64_t onRegionBase=ZNV3Align(codeCursor,16);
                            uint64_t onPad=(ZN60NextLayoutWord(&onState)%5u)*16u;
                            uint64_t onFileOffset=onRegionBase+onPad;
                            uint64_t onRegionRVA=codeRVA+(onFileOffset-codeFileOffset);
                            codeCursor=onRegionBase+variantStride;
                            uint64_t onEntryRVA=0;
                            uint32_t onFragments=0;
                            if(!ZNV3WriteVariantV2(base,onFileOffset,onRegionRVA,variantReserved,source,physical.rva,
                                                   physical.rva,physical.rva+physical.window,physical.rva+physical.window,
                                                   onState,&onEntryRVA,&onFragments,&localError))break;
                            protectionV2Variants++;
                            protectionV2Fragments+=onFragments;
                            [writtenSources addObject:source]; [writtenRVAs addObject:@(onEntryRVA)]; onRVAs[logicalIndex]=onEntryRVA;
                        }
                        if(localError)break;

                        size_t canonicalLogical=physical.members.front();
                        uint64_t entryRVA=dataRVA+sizeof(ZN44StaticHeader)+canonicalLogical*sizeof(ZN44StaticEntry);
                        if(entryRVA&7u){localError=@"V3 canonical selectedTarget 未 8-byte 对齐";break;}
                        if(!ZNV3WriteThunkV2(base,thunkFileOffset,thunkRVA,32u,entryRVA,offRVA,thunkState,&localError))break;

                        uint32_t siteBranch=0;
                        if(!ZNV3EncodeB(physical.rva,thunkRVA,NO,&siteBranch)){localError=@"Site → Protection V2 thunk 超出 ±128MB";break;}
                        ZNV3Write32(base+physical.fileoff,siteBranch);
                        for(uint64_t q=4;q<physical.window;q+=4)ZNV3Write32(base+physical.fileoff+q,NOP);
                    }
                    if(localError)break;
                    if(codeCursor-codeFileOffset>codeNeeded){localError=@"Protection V2 __ZNTEXT 预算计算错误";break;}

                    for(size_t i=0;i<logicals.size();i++){
                        ZNV3Logical &logical=logicals[i];
                        ZNV3Physical &physical=physicals[logicalToPhysical[i]];
                        ZN44StaticEntry &entry=entries[i];
                        memset(&entry,0,sizeof(entry));
                        entry.offRVA=physical.offRVA;
                        entry.onRVA=onRVAs[i];
                        entry.siteRVA=physical.rva;
                        entry.windowLength=(uint32_t)physical.window;
                        entry.patchID=(uint32_t)i+1;
                        entry.enabledLength=(uint32_t)logical.enabled.length;
                        entry.physicalID=(uint32_t)logicalToPhysical[i]+1;
                        entry.canonicalIndex=(uint32_t)physical.members.front();
                        entry.flags=(i==physical.members.front()?ZN44_STATIC_ENTRY_FLAG_CANONICAL:0u) |
                                    (physical.members.size()>1?ZN44_STATIC_ENTRY_FLAG_SHARED:0u);
                        ZNV3CopyFixed(entry.title,sizeof(entry.title),logical.row.title.length?logical.row.title:[NSString stringWithFormat:@"Patch #%u",entry.patchID]);
                        ZNV3CopyFixed(entry.group,sizeof(entry.group),logical.row.group.length?logical.row.group:@"Imported");
                    }

                    uint64_t descOffset=ZNV3Align(sizeof(ZN44StaticHeader)+logicals.size()*sizeof(ZN44StaticEntry),8);
                    ZN44FeatureDescriptionHeader *descHeader=(ZN44FeatureDescriptionHeader *)((uint8_t *)header+descOffset);
                    memset(descHeader,0,sizeof(*descHeader)+logicals.size()*sizeof(ZN44FeatureDescriptionEntry));
                    descHeader->magic0=ZN44_FEATURE_DESC_MAGIC0;
                    descHeader->magic1=ZN44_FEATURE_DESC_MAGIC1;
                    descHeader->count=(uint32_t)logicals.size();
                    descHeader->entrySize=sizeof(ZN44FeatureDescriptionEntry);
                    ZN44FeatureDescriptionEntry *descEntries=(ZN44FeatureDescriptionEntry *)(descHeader+1);
                    for(size_t i=0;i<logicals.size();i++){
                        ZN44FeatureDescriptionEntry &descEntry=descEntries[i];
                        descEntry.patchID=(uint32_t)i+1u;
                        NSData *utf8=[logicals[i].row.featureDescription dataUsingEncoding:NSUTF8StringEncoding]?:[NSData data];
                        NSUInteger length=MIN((NSUInteger)ZN44_FEATURE_DESC_MAX_UTF8,utf8.length);
                        while(length>0){
                            NSData *candidate=[utf8 subdataWithRange:NSMakeRange(0,length)];
                            if([[NSString alloc] initWithData:candidate encoding:NSUTF8StringEncoding])break;
                            length--;
                        }
                        descEntry.length=(uint16_t)length;
                        if(length)memcpy(descEntry.text,utf8.bytes,length);
                    }

                    if(msync(base,(size_t)newFileSize,MS_SYNC)!=0){localError=[NSString stringWithFormat:@"msync 失败：errno=%d",errno];break;}

                    success=YES;
                    NSUInteger sharedSites=0;
                    for(const ZNV3Physical &p:physicals)if(p.members.size()>1)sharedSites++;
                    if(metadata)*metadata=@{
                        @"target":target,
                        @"input":inputPath,
                        @"output":outputPath,
                        @"builder":@"Static Binary Builder V3",
                        @"allocationPolicy":@"owned-segments-only",
                        @"logicalPatchCount":@(logicals.size()),
                        @"physicalSiteCount":@(physicals.size()),
                        @"sharedSiteCount":@(sharedSites),
                        @"zntTextRVA":[NSString stringWithFormat:@"0x%llX",codeRVA],
                        @"zntTextSize":[NSString stringWithFormat:@"0x%llX",codeSegmentSize],
                        @"zntDataRVA":[NSString stringWithFormat:@"0x%llX",dataRVA],
                        @"zntDataSize":[NSString stringWithFormat:@"0x%llX",dataSegmentSize],
                        @"linkeditShift":[NSString stringWithFormat:@"0x%llX",insertedBytes],
                        @"ownerPolicy":@"last-enabled-active-owner-wins",
                        @"bootSafeOffFallback":@YES,
                        @"payloadProtectionV2":@YES,
                        @"payloadLayout":@"fragmented-16-byte-slot-chain-v1",
                        @"maxContiguousSourceInstructions":@1,
                        @"variantEntryPermutation":@YES,
                        @"thunkTemplateDiversification":@YES,
                        @"runtimeExecutableWrites":@NO,
                        @"payloadVariantCount":@(protectionV2Variants),
                        @"payloadFragmentCount":@(protectionV2Fragments),
                        @"layoutTag":[NSString stringWithFormat:@"%016llX",protectionV2LayoutTag],
                        @"needsResign":@YES
                    };
                    if(outPath)*outPath=outputPath;
                }while(0);
                munmap(base,(size_t)newFileSize);
            }
        }
    }

    close(fd);
    if(!success){[fm removeItemAtPath:outputPath error:nil];if(error)*error=localError?:@"Static Binary Builder V3 生成失败";}
    return success;
}

BOOL ZNStaticBinaryBuilderV3BuildWorkspace(ZNBinaryPatchWorkspace *workspace,
                               NSArray<NSString *> **outputs,
                               NSString **report,
                               NSString **error) {
    if(!workspace||workspace.hasAnyApplied){if(error)*error=@"生成前必须恢复所有临时 Runtime Patch";return NO;}
    if(!workspace.filledCount){if(error)*error=@"没有 Patch";return NO;}

    NSMutableDictionary<NSString *,NSMutableArray<ZNBinaryPatchRow *> *> *groups=[NSMutableDictionary dictionary];
    for(ZNBinaryPatchRow *row in workspace.rows){
        if(!row.offsetText.length&&!row.enabledText.length)continue;
        if(!row.validated||!row.validator){if(error)*error=@"所有已填写 Patch 必须先“读取验证”通过";return NO;}
        NSString *global=[workspace.defaultTarget ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        BOOL autoTarget=!global.length||[global caseInsensitiveCompare:@"自动"]==NSOrderedSame||[global caseInsensitiveCompare:@"auto"]==NSOrderedSame;
        NSString *target=autoTarget?((row.explicitTarget&&row.target.length)?row.target:@"main"):global;
        if(!groups[target])groups[target]=[NSMutableArray array];
        [groups[target] addObject:row];
    }

    NSString *root=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/ZonoePatchOutput"];
    NSDateFormatter *formatter=[NSDateFormatter new];formatter.dateFormat=@"yyyyMMdd-HHmmss";
    NSString *folder=[root stringByAppendingPathComponent:[formatter stringFromDate:[NSDate date]]];
    NSError *directoryError=nil;
    if(![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&directoryError]){
        if(error)*error=directoryError.localizedDescription?:@"创建输出目录失败";return NO;
    }

    NSMutableArray<NSString *> *paths=[NSMutableArray array];
    NSMutableArray<NSDictionary *> *metadata=[NSMutableArray array];
    NSString *failure=nil;
    for(NSString *target in groups){
        NSString *path=nil,*targetError=nil;NSDictionary *targetMetadata=nil;
        if(!ZNV3BuildTarget(target,groups[target],folder,&path,&targetMetadata,&targetError)){
            failure=[NSString stringWithFormat:@"%@：%@",target,targetError?:@"生成失败"];break;
        }
        if(path.length)[paths addObject:path];if(targetMetadata)[metadata addObject:targetMetadata];
    }
    if(failure){[NSFileManager.defaultManager removeItemAtPath:folder error:nil];if(error)*error=failure;return NO;}

    NSDictionary *reportObject=@{
        @"format":@"com.zonoe.static-dispatch/v3-owned-segments-protection-v2",
        @"generatedAt":[[NSDate date] description],
        @"targets":metadata,
        @"notes":@[
            @"Target Mach-O original storage is never used as persistent ZonoPatch storage",
            @"Dispatch code and all variants live in the newly owned __ZNTEXT/__zncode segment",
            @"Protection V2 stores each relocated source instruction in an independently shuffled 16-byte fragment slot",
            @"Protection V2 varies thunk live length and entry placement per generated output; it is a static-analysis cost layer, not cryptographic secrecy",
            @"Static Dispatch metadata and selectedTarget live in the newly owned __ZNDATA/__zndata segment",
            @"No executable/data gap fallback is allowed",
            @"Same Target + same starting RVA is one physical site",
            @"Different Enabled values become logical variants",
            @"Short variants are composed with the current validated Original tail before relocation",
            @"Runtime owner policy: most recently enabled active owner wins",
            @"No active owner selects relocated Original",
            @"Different-start overlapping windows remain a hard conflict",
            @"Runtime changes RW selectedTarget only; executable pages are not modified after launch",
            @"Original patch sites remain one direct ARM64 B where the validated overwrite window is one instruction; V2 does not claim to hide this architectural requirement",
            @"Phase 1 requires enough load-command header slack and direct B reachability",
            @"Output Mach-O must be re-signed before installation"
        ]
    };
    NSData *json=[NSJSONSerialization dataWithJSONObject:reportObject options:NSJSONWritingPrettyPrinted error:nil];
    NSString *reportPath=[folder stringByAppendingPathComponent:@"build_report.json"];
    [json writeToFile:reportPath atomically:YES];[paths addObject:reportPath];
    NSDictionary *protectionV2Validation=@{
        @"format":@"com.zonoe.protection-v2-validation/v1",
        @"version":@"0.5.6",
        @"payloadLayout":@"fragmented-16-byte-slot-chain-v1",
        @"headerFlag":[NSString stringWithFormat:@"0x%08X",ZN44_STATIC_HEADER_FLAG_PAYLOAD_PROTECTION_V2],
        @"maxContiguousSourceInstructions":@1,
        @"runtimeExecutableWrites":@NO,
        @"targets":metadata,
        @"deviceChecks":@[
            @"Cold launch without tapping ZN: no Patch Runtime or saved feature restoration",
            @"First tap completes deferred bootstrap before menu appears",
            @"OFF path matches original behavior",
            @"ON path matches enabled behavior",
            @"Shared-site owner fallback remains correct",
            @"Kill/relaunch stays OFF until first ZN tap, then restores saved state",
            @"Generated Mach-O installs and launches after normal package re-sign"
        ]
    };
    NSData *validationJSON=[NSJSONSerialization dataWithJSONObject:protectionV2Validation options:NSJSONWritingPrettyPrinted error:nil];
    NSString *validationPath=[folder stringByAppendingPathComponent:@"protection_v2_validation.json"];
    if(validationJSON){[validationJSON writeToFile:validationPath atomically:YES];[paths addObject:validationPath];}
    if(outputs)*outputs=paths;
    if(report)*report=[NSString stringWithFormat:@"Static Binary Builder V3 生成成功：%lu 个目标 · %lu 个逻辑 Patch\n输出：%@\n已新增 __ZNTEXT + __ZNDATA；不再使用目标 Mach-O 的 code/data gap；必须重新签名后安装",
                        (unsigned long)groups.count,(unsigned long)workspace.filledCount,folder];
    return YES;
}

// v0.5.4: V3 is invoked explicitly by ZNStaticBinaryPipeline.mm.
// No Objective-C +load or method_exchange is used for builder selection.
