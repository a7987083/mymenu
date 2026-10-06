#import "ZNStaticBinaryBuilder.h"
#import "ZNBinaryPatchWorkspace.h"
#import "ZNPatchRuntimeValidator.h"
#import "ZNPatchCore.h"
#import "ZNStaticPatchFormat.h"
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <mach/vm_prot.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <vector>
#import <algorithm>

// Binary Builder V1 deliberately does not grow the Mach-O. It only consumes
// zero-filled, file-backed gaps that are not claimed by any section. If a safe
// executable/data gap cannot be proven, generation fails instead of guessing.

struct ZNBSection {
    uint64_t fileStart;
    uint64_t fileEnd;
    uint64_t addr;
    uint64_t size;
    uint32_t flags;
};

struct ZNBSegment {
    uint64_t vmaddr;
    uint64_t vmsize;
    uint64_t fileoff;
    uint64_t filesize;
    vm_prot_t initprot;
    vm_prot_t maxprot;
    char name[17];
    std::vector<ZNBSection> sections;
};

struct ZNBGap {
    uint64_t fileoff;
    uint64_t size;
    uint64_t rva;
    size_t segIndex;
};

struct ZNBSite {
    __unsafe_unretained ZNBinaryPatchRow *row;
    uint64_t rva;
    uint64_t fileoff;
    uint64_t window;
    size_t segIndex;
    NSData *original;
    NSData *enabled;
};

static uint64_t ZNBAlign(uint64_t value, uint64_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

static int64_t ZNBSX(uint64_t value, int bits) {
    uint64_t sign = 1ULL << (bits - 1);
    return (int64_t)((value ^ sign) - sign);
}

static uint32_t ZNBRead32(const uint8_t *p) {
    uint32_t value = 0;
    memcpy(&value, p, sizeof(value));
    return value;
}

static void ZNBWrite32(uint8_t *p, uint32_t value) {
    memcpy(p, &value, sizeof(value));
}

static BOOL ZNBZero(const uint8_t *base, uint64_t offset, uint64_t length) {
    for (uint64_t i = 0; i < length; i++) {
        if (base[offset + i] != 0) return NO;
    }
    return YES;
}

static BOOL ZNBParse(uint8_t *base,
                     size_t size,
                     std::vector<ZNBSegment> &segments,
                     uint64_t &imageVMBase,
                     NSString **error) {
    if (size < sizeof(struct mach_header_64)) {
        if (error) *error = @"Mach-O 太小";
        return NO;
    }

    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    if (mh->magic != MH_MAGIC_64) {
        if (error) *error = @"Binary Builder V1 仅支持 thin 64-bit Mach-O";
        return NO;
    }
    if (mh->cputype != CPU_TYPE_ARM64) {
        if (error) *error = @"目标不是 arm64/arm64e Mach-O";
        return NO;
    }
    if (sizeof(*mh) + (uint64_t)mh->sizeofcmds > size) {
        if (error) *error = @"Mach-O load commands 越界";
        return NO;
    }

    imageVMBase = UINT64_MAX;
    uint8_t *cursor = base + sizeof(*mh);
    uint8_t *commandEnd = cursor + mh->sizeofcmds;

    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > commandEnd) {
            if (error) *error = @"load command 损坏";
            return NO;
        }
        struct load_command *lc = (struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command) || cursor + lc->cmdsize > commandEnd) {
            if (error) *error = @"load command size 损坏";
            return NO;
        }

        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cursor;
            if (seg->fileoff + seg->filesize > size) {
                if (error) *error = @"segment file range 越界";
                return NO;
            }

            ZNBSegment parsed = {};
            parsed.vmaddr = seg->vmaddr;
            parsed.vmsize = seg->vmsize;
            parsed.fileoff = seg->fileoff;
            parsed.filesize = seg->filesize;
            parsed.initprot = seg->initprot;
            parsed.maxprot = seg->maxprot;
            memcpy(parsed.name, seg->segname, 16);
            parsed.name[16] = 0;

            if (strncmp(seg->segname, SEG_TEXT, 16) == 0) imageVMBase = seg->vmaddr;

            uint64_t sectionBytes = (uint64_t)seg->nsects * sizeof(struct section_64);
            if (lc->cmdsize >= sizeof(struct segment_command_64) + sectionBytes) {
                struct section_64 *sec = (struct section_64 *)(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    uint32_t type = sec[j].flags & SECTION_TYPE;
                    if (type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL) continue;
                    if (!sec[j].size || !sec[j].offset) continue;
                    uint64_t fileStart = sec[j].offset;
                    uint64_t fileEnd = fileStart + sec[j].size;
                    if (fileEnd > size) continue;
                    parsed.sections.push_back({fileStart, fileEnd, sec[j].addr, sec[j].size, sec[j].flags});
                }
            }
            segments.push_back(parsed);
        }
        cursor += lc->cmdsize;
    }

    if (imageVMBase == UINT64_MAX) {
        if (error) *error = @"未找到 __TEXT segment";
        return NO;
    }
    return YES;
}

static BOOL ZNBRVAToFile(const std::vector<ZNBSegment> &segments,
                         uint64_t imageVMBase,
                         uint64_t rva,
                         uint64_t length,
                         uint64_t &fileOffset,
                         size_t &segmentIndex) {
    uint64_t va = imageVMBase + rva;
    for (size_t i = 0; i < segments.size(); i++) {
        const ZNBSegment &seg = segments[i];
        if (va >= seg.vmaddr && va + length <= seg.vmaddr + seg.filesize) {
            fileOffset = seg.fileoff + (va - seg.vmaddr);
            segmentIndex = i;
            return YES;
        }
    }
    return NO;
}

static uint64_t ZNBFileToRVA(const ZNBSegment &segment, uint64_t imageVMBase, uint64_t fileOffset) {
    return segment.vmaddr + (fileOffset - segment.fileoff) - imageVMBase;
}

static BOOL ZNBInstructionRange(const std::vector<ZNBSegment> &segments,
                                uint64_t imageVMBase,
                                uint64_t rva,
                                uint64_t length) {
    uint64_t va = imageVMBase + rva;
    for (const ZNBSegment &seg : segments) {
        if (!(seg.initprot & VM_PROT_EXECUTE)) continue;
        for (const ZNBSection &sec : seg.sections) {
            if (!(sec.flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))) continue;
            if (va >= sec.addr && va + length <= sec.addr + sec.size) return YES;
        }
    }
    return NO;
}

static std::vector<ZNBGap> ZNBGaps(const uint8_t *base,
                                   const std::vector<ZNBSegment> &segments,
                                   uint64_t imageVMBase,
                                   BOOL executable,
                                   uint64_t needed,
                                   const std::vector<uint64_t> &sites) {
    std::vector<ZNBGap> result;

    for (size_t segmentIndex = 0; segmentIndex < segments.size(); segmentIndex++) {
        const ZNBSegment &seg = segments[segmentIndex];
        if (executable) {
            if (!(seg.initprot & VM_PROT_EXECUTE)) continue;
        } else {
            if (!(seg.initprot & VM_PROT_WRITE)) continue;
        }
        if (!seg.filesize || seg.sections.empty()) continue;

        std::vector<std::pair<uint64_t, uint64_t>> ranges;
        for (const ZNBSection &sec : seg.sections) {
            if (sec.fileStart >= seg.fileoff && sec.fileEnd <= seg.fileoff + seg.filesize) {
                ranges.push_back({sec.fileStart, sec.fileEnd});
            }
        }
        if (ranges.empty()) continue;
        std::sort(ranges.begin(), ranges.end());

        uint64_t cursor = ranges.front().second;
        for (size_t i = 1; i <= ranges.size(); i++) {
            uint64_t nextStart = (i < ranges.size()) ? ranges[i].first : (seg.fileoff + seg.filesize);
            if (nextStart > cursor) {
                uint64_t aligned = ZNBAlign(cursor, executable ? 16 : 8);
                if (nextStart > aligned && nextStart - aligned >= needed && ZNBZero(base, aligned, needed)) {
                    uint64_t gapRVA = ZNBFileToRVA(seg, imageVMBase, aligned);
                    BOOL reachable = YES;
                    if (executable) {
                        for (uint64_t site : sites) {
                            int64_t deltaStart = (int64_t)gapRVA - (int64_t)site;
                            int64_t deltaEnd = (int64_t)(gapRVA + needed) - (int64_t)site;
                            if (deltaStart <= -(1LL << 27) || deltaStart >= (1LL << 27) ||
                                deltaEnd <= -(1LL << 27) || deltaEnd >= (1LL << 27)) {
                                reachable = NO;
                                break;
                            }
                        }
                    }
                    if (reachable) result.push_back({aligned, nextStart - aligned, gapRVA, segmentIndex});
                }
            }
            if (i < ranges.size()) cursor = std::max(cursor, ranges[i].second);
        }
    }

    std::sort(result.begin(), result.end(), [](const ZNBGap &a, const ZNBGap &b) {
        return a.size > b.size;
    });
    return result;
}

static BOOL ZNBEncodeB(uint64_t fromRVA, uint64_t toRVA, BOOL link, uint32_t *outInstruction) {
    int64_t delta = (int64_t)toRVA - (int64_t)fromRVA;
    if ((delta & 3) || delta < -(1LL << 27) || delta >= (1LL << 27)) return NO;
    uint32_t imm26 = (uint32_t)((delta >> 2) & 0x03FFFFFF);
    *outInstruction = (link ? 0x94000000u : 0x14000000u) | imm26;
    return YES;
}

static BOOL ZNBEncodeADRPX17(uint64_t fromRVA, uint64_t toRVA, uint32_t *outInstruction) {
    int64_t pages = ((int64_t)(toRVA & ~0xFFFULL) - (int64_t)(fromRVA & ~0xFFFULL)) >> 12;
    if (pages < -(1LL << 20) || pages >= (1LL << 20)) return NO;
    uint64_t imm = (uint64_t)pages & 0x1FFFFF;
    *outInstruction = 0x90000000u |
                      ((uint32_t)(imm & 3) << 29) |
                      ((uint32_t)((imm >> 2) & 0x7FFFF) << 5) |
                      17u;
    return YES;
}

static uint32_t ZNBLdrX17FromX17(uint64_t targetRVA) {
    uint32_t imm12 = (uint32_t)((targetRVA & 0xFFFULL) >> 3);
    return 0xF9400000u | (imm12 << 10) | (17u << 5) | 17u;
}

static BOOL ZNBIsRET(uint32_t instruction) {
    return (instruction & 0xFFFFFC1Fu) == 0xD65F0000u;
}

static BOOL ZNBIsBR(uint32_t instruction) {
    return (instruction & 0xFFFFFC1Fu) == 0xD61F0000u;
}

static BOOL ZNBRelocate(uint32_t instruction,
                        uint64_t sourceRVA,
                        uint64_t destinationRVA,
                        uint64_t windowStart,
                        uint64_t windowEnd,
                        uint32_t *outInstruction,
                        BOOL *terminal,
                        NSString **error) {
    *terminal = NO;

    // B / BL, imm26.
    if ((instruction & 0x7C000000u) == 0x14000000u) {
        BOOL link = (instruction & 0x80000000u) != 0;
        int64_t delta = ZNBSX(instruction & 0x03FFFFFFu, 26) << 2;
        uint64_t target = (uint64_t)((int64_t)sourceRVA + delta);
        if (target >= windowStart && target < windowEnd) {
            if (error) *error = @"PC-relative B/BL 指向被覆盖窗口内部，V1 拒绝生成";
            return NO;
        }
        if (!ZNBEncodeB(destinationRVA, target, link, outInstruction)) {
            if (error) *error = @"重定位 B/BL 超出 ±128MB";
            return NO;
        }
        *terminal = !link;
        return YES;
    }

    // B.cond / CBZ / CBNZ / LDR literal family, imm19.
    if ((instruction & 0xFF000010u) == 0x54000000u ||
        (instruction & 0x7E000000u) == 0x34000000u ||
        (instruction & 0x3B000000u) == 0x18000000u) {
        int64_t delta = ZNBSX((instruction >> 5) & 0x7FFFFu, 19) << 2;
        uint64_t target = (uint64_t)((int64_t)sourceRVA + delta);
        if (target >= windowStart && target < windowEnd) {
            if (error) *error = @"PC-relative imm19 指向被覆盖窗口内部";
            return NO;
        }
        int64_t newDelta = (int64_t)target - (int64_t)destinationRVA;
        if ((newDelta & 3) || newDelta < -(1LL << 20) || newDelta >= (1LL << 20)) {
            if (error) *error = @"重定位 imm19 超出 ±1MB";
            return NO;
        }
        *outInstruction = (instruction & ~0x00FFFFE0u) |
                          (((uint32_t)(newDelta >> 2) & 0x7FFFFu) << 5);
        return YES;
    }

    // TBZ / TBNZ, imm14.
    if ((instruction & 0x7E000000u) == 0x36000000u) {
        int64_t delta = ZNBSX((instruction >> 5) & 0x3FFFu, 14) << 2;
        uint64_t target = (uint64_t)((int64_t)sourceRVA + delta);
        if (target >= windowStart && target < windowEnd) {
            if (error) *error = @"TBZ/TBNZ 指向被覆盖窗口内部";
            return NO;
        }
        int64_t newDelta = (int64_t)target - (int64_t)destinationRVA;
        if ((newDelta & 3) || newDelta < -(1LL << 15) || newDelta >= (1LL << 15)) {
            if (error) *error = @"重定位 TBZ/TBNZ 超出 ±32KB";
            return NO;
        }
        *outInstruction = (instruction & ~0x0007FFE0u) |
                          (((uint32_t)(newDelta >> 2) & 0x3FFFu) << 5);
        return YES;
    }

    // ADR / ADRP.
    uint32_t adrMask = instruction & 0x9F000000u;
    if (adrMask == 0x10000000u || adrMask == 0x90000000u) {
        uint64_t imm = ((uint64_t)((instruction >> 5) & 0x7FFFF) << 2) | ((instruction >> 29) & 3);
        int64_t signedImm = ZNBSX(imm, 21);
        uint64_t target = 0;
        if (adrMask == 0x90000000u) {
            target = (uint64_t)((int64_t)(sourceRVA & ~0xFFFULL) + (signedImm << 12));
        } else {
            target = (uint64_t)((int64_t)sourceRVA + signedImm);
        }
        if (target >= windowStart && target < windowEnd) {
            if (error) *error = @"ADR/ADRP 指向被覆盖窗口内部";
            return NO;
        }

        int64_t newImm = 0;
        if (adrMask == 0x90000000u) {
            newImm = ((int64_t)(target & ~0xFFFULL) - (int64_t)(destinationRVA & ~0xFFFULL)) >> 12;
        } else {
            newImm = (int64_t)target - (int64_t)destinationRVA;
        }
        if (newImm < -(1LL << 20) || newImm >= (1LL << 20)) {
            if (error) *error = @"重定位 ADR/ADRP 超范围";
            return NO;
        }
        uint64_t u = (uint64_t)newImm & 0x1FFFFF;
        *outInstruction = (instruction & ~((3u << 29) | (0x7FFFFu << 5))) |
                          ((uint32_t)(u & 3) << 29) |
                          ((uint32_t)((u >> 2) & 0x7FFFF) << 5);
        return YES;
    }

    // Everything else in V1 is copied only if it is not PC-relative according
    // to the supported classes above. RET/BR are terminal after the copy.
    *outInstruction = instruction;
    if (ZNBIsRET(instruction) || ZNBIsBR(instruction)) *terminal = YES;
    return YES;
}

static BOOL ZNBInboundInterior(const uint8_t *base,
                               const std::vector<ZNBSegment> &segments,
                               uint64_t imageVMBase,
                               uint64_t siteRVA,
                               uint64_t length) {
    uint64_t endRVA = siteRVA + length;

    for (const ZNBSegment &seg : segments) {
        if (!(seg.initprot & VM_PROT_EXECUTE)) continue;
        for (const ZNBSection &sec : seg.sections) {
            if (!(sec.flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))) continue;
            if (sec.fileEnd <= sec.fileStart) continue;

            for (uint64_t offset = sec.fileStart; offset + 4 <= sec.fileEnd; offset += 4) {
                uint32_t instruction = ZNBRead32(base + offset);
                uint64_t sourceRVA = sec.addr + (offset - sec.fileStart) - imageVMBase;
                uint64_t targetRVA = 0;
                BOOL hasDirectTarget = NO;

                if ((instruction & 0x7C000000u) == 0x14000000u) {
                    targetRVA = (uint64_t)((int64_t)sourceRVA + (ZNBSX(instruction & 0x03FFFFFFu, 26) << 2));
                    hasDirectTarget = YES;
                } else if ((instruction & 0xFF000010u) == 0x54000000u ||
                           (instruction & 0x7E000000u) == 0x34000000u) {
                    targetRVA = (uint64_t)((int64_t)sourceRVA + (ZNBSX((instruction >> 5) & 0x7FFFFu, 19) << 2));
                    hasDirectTarget = YES;
                } else if ((instruction & 0x7E000000u) == 0x36000000u) {
                    targetRVA = (uint64_t)((int64_t)sourceRVA + (ZNBSX((instruction >> 5) & 0x3FFFu, 14) << 2));
                    hasDirectTarget = YES;
                }

                // Incoming branch to site start is valid; incoming branch to
                // any displaced instruction after the first one is rejected.
                if (hasDirectTarget && targetRVA > siteRVA && targetRVA < endRVA) return YES;
            }
        }
    }
    return NO;
}

static BOOL ZNBWriteVariant(uint8_t *base,
                            uint64_t fileOffset,
                            uint64_t variantRVA,
                            uint64_t reserved,
                            NSData *source,
                            uint64_t sourceRVA,
                            uint64_t windowStart,
                            uint64_t windowEnd,
                            uint64_t resumeRVA,
                            NSString **error) {
    const uint32_t NOP = 0xD503201Fu;
    const uint32_t LDP_X16_X17_POST = 0xA8C147F0u;

    for (uint64_t p = 0; p < reserved; p += 4) ZNBWrite32(base + fileOffset + p, NOP);

    // Per-site thunk saves x16/x17. Every destination starts by restoring them,
    // so an internal patch point does not require x16/x17 to be dead.
    ZNBWrite32(base + fileOffset, LDP_X16_X17_POST);

    const uint8_t *sourceBytes = (const uint8_t *)source.bytes;
    BOOL terminalSeen = NO;
    NSUInteger emittedLength = 0;
    for (NSUInteger i = 0; i < source.length; i += 4) {
        if (terminalSeen) break;
        uint32_t instruction = ZNBRead32(sourceBytes + i);
        uint32_t relocated = 0;
        BOOL terminal = NO;
        if (!ZNBRelocate(instruction,
                         sourceRVA + i,
                         variantRVA + 4 + i,
                         windowStart,
                         windowEnd,
                         &relocated,
                         &terminal,
                         error)) {
            return NO;
        }
        ZNBWrite32(base + fileOffset + 4 + i, relocated);
        emittedLength = i + 4;
        if (terminal) terminalSeen = YES;
    }

    if (!terminalSeen) {
        uint32_t resumeBranch = 0;
        uint64_t branchRVA = variantRVA + 4 + emittedLength;
        if (!ZNBEncodeB(branchRVA, resumeRVA, NO, &resumeBranch)) {
            if (error) *error = @"Variant 返回原代码超出 ±128MB";
            return NO;
        }
        ZNBWrite32(base + fileOffset + 4 + emittedLength, resumeBranch);
    }
    return YES;
}

static void ZNBCopyFixed(char *destination, size_t capacity, NSString *string) {
    memset(destination, 0, capacity);
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length || capacity == 0) return;
    memcpy(destination, data.bytes, std::min(capacity - 1, (size_t)data.length));
}

static BOOL ZNBBuildTarget(NSString *target,
                           NSArray<ZNBinaryPatchRow *> *rows,
                           NSString *folder,
                           NSString **outPath,
                           NSDictionary **metadata,
                           NSString **error) {
    NSDictionary *module = [[ZNModuleManager sharedManager] moduleNamed:target];
    if (!module) {
        if (error) *error = [NSString stringWithFormat:@"目标模块未加载：%@", target];
        return NO;
    }

    NSString *inputPath = module[@"path"];
    if (!inputPath.length) {
        if (error) *error = @"无法取得目标 Mach-O 路径";
        return NO;
    }

    NSString *name = inputPath.lastPathComponent.length ? inputPath.lastPathComponent : target;
    NSString *outputPath = [folder stringByAppendingPathComponent:[name stringByAppendingString:@".znpatched"]];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:outputPath error:nil];

    NSError *copyError = nil;
    if (![fm copyItemAtPath:inputPath toPath:outputPath error:&copyError]) {
        if (error) *error = [NSString stringWithFormat:@"复制目标失败：%@", copyError.localizedDescription ?: @"未知错误"];
        return NO;
    }

    int fd = open(outputPath.fileSystemRepresentation, O_RDWR);
    if (fd < 0) {
        [fm removeItemAtPath:outputPath error:nil];
        if (error) *error = [NSString stringWithFormat:@"打开输出文件失败：errno=%d", errno];
        return NO;
    }

    struct stat st = {};
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        [fm removeItemAtPath:outputPath error:nil];
        if (error) *error = @"读取输出文件大小失败";
        return NO;
    }

    size_t fileSize = (size_t)st.st_size;
    uint8_t *base = (uint8_t *)mmap(NULL, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        close(fd);
        [fm removeItemAtPath:outputPath error:nil];
        if (error) *error = @"mmap 输出文件失败";
        return NO;
    }

    BOOL success = NO;
    NSString *localError = nil;
    std::vector<ZNBSegment> segments;
    uint64_t imageVMBase = 0;

    do {
        if (!ZNBParse(base, fileSize, segments, imageVMBase, &localError)) break;

        std::vector<ZNBSite> sites;
        std::vector<uint64_t> siteRVAs;

        for (ZNBinaryPatchRow *row in rows) {
            NSData *enabled = row.validator.patchBytes;
            NSData *liveOriginal = row.validator.capturedOriginalBytes;
            if (!enabled.length || !liveOriginal.length || enabled.length != liveOriginal.length || (enabled.length & 3)) {
                localError = @"Patch 必须已验证，且 Enabled/Original 长度一致并为 4-byte 倍数";
                break;
            }

            uint64_t rva = row.validator.rva;
            uint64_t fileOffset = 0;
            size_t segmentIndex = 0;
            if (!ZNBRVAToFile(segments, imageVMBase, rva, enabled.length, fileOffset, segmentIndex)) {
                localError = [NSString stringWithFormat:@"%@+0x%llX 无法映射到 file offset", target, rva];
                break;
            }
            if (!(segments[segmentIndex].initprot & VM_PROT_EXECUTE) ||
                !ZNBInstructionRange(segments, imageVMBase, rva, enabled.length)) {
                localError = [NSString stringWithFormat:@"%@+0x%llX 不在可确认的 ARM64 instruction section", target, rva];
                break;
            }

            NSData *diskOriginal = [NSData dataWithBytes:base + fileOffset length:enabled.length];
            if (![diskOriginal isEqualToData:liveOriginal]) {
                localError = [NSString stringWithFormat:@"%@+0x%llX 磁盘原字节与 Live Original 不一致", target, rva];
                break;
            }

            if (ZNBInboundInterior(base, segments, imageVMBase, rva, enabled.length)) {
                localError = [NSString stringWithFormat:@"%@+0x%llX 覆盖窗口内部存在直接分支目标，V1 拒绝", target, rva];
                break;
            }

            sites.push_back({row, rva, fileOffset, (uint64_t)enabled.length, segmentIndex, diskOriginal, enabled});
            siteRVAs.push_back(rva);
        }
        if (localError) break;

        for (size_t a = 0; a < sites.size(); a++) {
            for (size_t b = a + 1; b < sites.size(); b++) {
                uint64_t aStart = sites[a].rva;
                uint64_t aEnd = aStart + sites[a].window;
                uint64_t bStart = sites[b].rva;
                uint64_t bEnd = bStart + sites[b].window;
                if (aStart < bEnd && bStart < aEnd) {
                    localError = @"Patch 覆盖窗口互相重叠";
                    break;
                }
            }
            if (localError) break;
        }
        if (localError) break;

        // 24-byte per-site thunk:
        //   STP X16,X17,[SP,#-16]!
        //   ADRP X17, selectedTarget@PAGE
        //   LDR X17,[X17,#pageoff]
        //   CBNZ X17, +8
        //   B OffVariant              ; boot-safe fallback before runtime init
        //   BR X17                    ; runtime-selected OFF/ON target
        const uint64_t thunkSize = 24;
        uint64_t codeNeeded = 0;
        for (const ZNBSite &site : sites) {
            uint64_t variantSize = ZNBAlign(4 + site.window + 4, 16);
            codeNeeded = ZNBAlign(codeNeeded, 16) + thunkSize + variantSize + variantSize;
        }
        codeNeeded += 32;

        uint64_t dataNeeded = ZNBAlign(sizeof(ZN44StaticHeader) + sites.size() * sizeof(ZN44StaticEntry), 8);
        std::vector<ZNBGap> codeGaps = ZNBGaps(base, segments, imageVMBase, YES, codeNeeded, siteRVAs);
        std::vector<ZNBGap> dataGaps = ZNBGaps(base, segments, imageVMBase, NO, dataNeeded, {});
        if (codeGaps.empty()) {
            localError = @"无安全 executable gap：V1 不会把任意 0 区当 code cave";
            break;
        }
        if (dataGaps.empty()) {
            localError = @"无安全 writable gap：V1 拒绝生成";
            break;
        }

        ZNBGap codeGap = codeGaps.front();
        ZNBGap dataGap = dataGaps.front();

        ZN44StaticHeader *header = (ZN44StaticHeader *)(base + dataGap.fileoff);
        memset(header, 0, dataNeeded);
        header->magic0 = ZN44_STATIC_MAGIC0;
        header->magic1 = ZN44_STATIC_MAGIC1;
        header->version = ZN44_STATIC_VERSION;
        header->count = (uint32_t)sites.size();
        header->entrySize = sizeof(ZN44StaticEntry);
        ZN44StaticEntry *entries = (ZN44StaticEntry *)(header + 1);

        const uint32_t STP_X16_X17_PRE = 0xA9BF47F0u;
        const uint32_t CBNZ_X17_PLUS_8 = 0xB5000051u;
        const uint32_t BR_X17 = 0xD61F0220u;
        const uint32_t NOP = 0xD503201Fu;

        uint64_t codeCursor = codeGap.fileoff;
        for (size_t i = 0; i < sites.size(); i++) {
            ZNBSite &site = sites[i];
            codeCursor = ZNBAlign(codeCursor, 16);

            uint64_t thunkFileOffset = codeCursor;
            uint64_t thunkRVA = ZNBFileToRVA(segments[codeGap.segIndex], imageVMBase, thunkFileOffset);
            codeCursor += thunkSize;

            uint64_t variantSize = ZNBAlign(4 + site.window + 4, 16);
            uint64_t offFileOffset = ZNBAlign(codeCursor, 16);
            uint64_t offRVA = ZNBFileToRVA(segments[codeGap.segIndex], imageVMBase, offFileOffset);
            codeCursor = offFileOffset + variantSize;

            uint64_t onFileOffset = ZNBAlign(codeCursor, 16);
            uint64_t onRVA = ZNBFileToRVA(segments[codeGap.segIndex], imageVMBase, onFileOffset);
            codeCursor = onFileOffset + variantSize;

            uint64_t entryRVA = dataGap.rva + sizeof(ZN44StaticHeader) + i * sizeof(ZN44StaticEntry);
            if ((entryRVA & 7) != 0) {
                localError = @"selectedTarget 未 8-byte 对齐";
                break;
            }

            uint32_t adrp = 0;
            if (!ZNBEncodeADRPX17(thunkRVA + 4, entryRVA, &adrp)) {
                localError = @"Thunk → selectedTarget ADRP 超出 ±4GB";
                break;
            }

            uint32_t offFallbackBranch = 0;
            if (!ZNBEncodeB(thunkRVA + 16, offRVA, NO, &offFallbackBranch)) {
                localError = @"Thunk boot-safe OFF fallback 超出 ±128MB";
                break;
            }

            ZNBWrite32(base + thunkFileOffset + 0, STP_X16_X17_PRE);
            ZNBWrite32(base + thunkFileOffset + 4, adrp);
            ZNBWrite32(base + thunkFileOffset + 8, ZNBLdrX17FromX17(entryRVA));
            ZNBWrite32(base + thunkFileOffset + 12, CBNZ_X17_PLUS_8);
            ZNBWrite32(base + thunkFileOffset + 16, offFallbackBranch);
            ZNBWrite32(base + thunkFileOffset + 20, BR_X17);

            if (!ZNBWriteVariant(base,
                                 offFileOffset,
                                 offRVA,
                                 variantSize,
                                 site.original,
                                 site.rva,
                                 site.rva,
                                 site.rva + site.window,
                                 site.rva + site.window,
                                 &localError)) {
                break;
            }

            if (!ZNBWriteVariant(base,
                                 onFileOffset,
                                 onRVA,
                                 variantSize,
                                 site.enabled,
                                 site.rva,
                                 site.rva,
                                 site.rva + site.window,
                                 site.rva + site.window,
                                 &localError)) {
                break;
            }

            uint32_t siteBranch = 0;
            if (!ZNBEncodeB(site.rva, thunkRVA, NO, &siteBranch)) {
                localError = @"Site → thunk 超出 ±128MB";
                break;
            }
            ZNBWrite32(base + site.fileoff, siteBranch);
            for (uint64_t p = 4; p < site.window; p += 4) ZNBWrite32(base + site.fileoff + p, NOP);

            ZN44StaticEntry &entry = entries[i];
            memset(&entry, 0, sizeof(entry));
            // selectedTarget intentionally remains zero on disk. The thunk has
            // a signed OFF fallback, so target code is safe even if it executes
            // before ZonoePatch.dylib initializes the RW pointer.
            entry.offRVA = offRVA;
            entry.onRVA = onRVA;
            entry.siteRVA = site.rva;
            entry.windowLength = (uint32_t)site.window;
            entry.patchID = (uint32_t)i + 1;
            entry.enabledLength = (uint32_t)site.enabled.length;
            ZNBCopyFixed(entry.title,
                         sizeof(entry.title),
                         site.row.title.length ? site.row.title : [NSString stringWithFormat:@"Patch #%u", entry.patchID]);
            ZNBCopyFixed(entry.group,
                         sizeof(entry.group),
                         site.row.group.length ? site.row.group : @"Imported");
        }
        if (localError) break;

        if (msync(base, fileSize, MS_SYNC) != 0) {
            localError = [NSString stringWithFormat:@"msync 失败：errno=%d", errno];
            break;
        }

        success = YES;
        if (metadata) {
            *metadata = @{
                @"target": target,
                @"input": inputPath,
                @"output": outputPath,
                @"patchCount": @(sites.size()),
                @"codeGapRVA": [NSString stringWithFormat:@"0x%llX", codeGap.rva],
                @"dataGapRVA": [NSString stringWithFormat:@"0x%llX", dataGap.rva],
                @"bootSafeOffFallback": @YES,
                @"needsResign": @YES,
            };
        }
        if (outPath) *outPath = outputPath;
    } while (0);

    munmap(base, fileSize);
    close(fd);

    if (!success) {
        [fm removeItemAtPath:outputPath error:nil];
        if (error) *error = localError ?: @"生成失败";
    }
    return success;
}

@implementation ZNStaticBinaryBuilder

+ (BOOL)buildWorkspace:(ZNBinaryPatchWorkspace *)workspace
               outputs:(NSArray<NSString *> **)outputs
                report:(NSString **)report
                 error:(NSString **)error {
    if (!workspace || workspace.hasAnyApplied) {
        if (error) *error = @"生成前必须恢复所有临时 Runtime Patch";
        return NO;
    }
    if (!workspace.filledCount) {
        if (error) *error = @"没有 Patch";
        return NO;
    }

    NSMutableDictionary<NSString *, NSMutableArray<ZNBinaryPatchRow *> *> *groups = [NSMutableDictionary dictionary];
    for (ZNBinaryPatchRow *row in workspace.rows) {
        if (!row.offsetText.length && !row.enabledText.length) continue;
        if (!row.validated || !row.validator) {
            if (error) *error = @"所有已填写 Patch 必须先“读取验证”通过";
            return NO;
        }
        NSString *target = (row.explicitTarget && row.target.length) ? row.target : workspace.defaultTarget;
        if (!groups[target]) groups[target] = [NSMutableArray array];
        [groups[target] addObject:row];
    }

    NSString *root = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/ZonoePatchOutput"];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *folder = [root stringByAppendingPathComponent:[formatter stringFromDate:[NSDate date]]];

    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:folder
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&directoryError]) {
        if (error) *error = directoryError.localizedDescription ?: @"创建输出目录失败";
        return NO;
    }

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *metadata = [NSMutableArray array];
    NSString *failure = nil;

    for (NSString *target in groups) {
        NSString *path = nil;
        NSDictionary *targetMetadata = nil;
        NSString *targetError = nil;
        if (!ZNBBuildTarget(target, groups[target], folder, &path, &targetMetadata, &targetError)) {
            failure = [NSString stringWithFormat:@"%@：%@", target, targetError ?: @"生成失败"];
            break;
        }
        if (path.length) [paths addObject:path];
        if (targetMetadata) [metadata addObject:targetMetadata];
    }

    if (failure) {
        [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
        if (error) *error = failure;
        return NO;
    }

    NSDictionary *reportObject = @{
        @"format": @"com.zonoe.static-dispatch/v1",
        @"generatedAt": [[NSDate date] description],
        @"targets": metadata,
        @"notes": @[
            @"JSON original is ignored",
            @"OFF bytes are captured/verified from the installed original binary",
            @"Runtime toggles only RW selectedTarget pointers",
            @"Each thunk has a signed OFF fallback before runtime pointer initialization",
            @"Output Mach-O must be re-signed before installation",
            @"V1 uses only unclaimed zero-filled file-backed segment gaps and rejects unsafe layouts",
        ],
    };

    NSData *json = [NSJSONSerialization dataWithJSONObject:reportObject options:NSJSONWritingPrettyPrinted error:nil];
    NSString *reportPath = [folder stringByAppendingPathComponent:@"build_report.json"];
    [json writeToFile:reportPath atomically:YES];
    [paths addObject:reportPath];

    if (outputs) *outputs = paths;
    if (report) {
        *report = [NSString stringWithFormat:@"生成成功：%lu 个目标 · %lu 个 Patch\n输出：%@\n必须重新签名后安装",
                   (unsigned long)groups.count,
                   (unsigned long)workspace.filledCount,
                   folder];
    }
    return YES;
}

@end
