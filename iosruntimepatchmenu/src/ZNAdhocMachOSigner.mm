#import "ZNAdhocMachOSigner.h"
#import <CommonCrypto/CommonDigest.h>
#include <stdint.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#import <mach/vm_prot.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

// Minimal, self-contained ad-hoc Mach-O signer used only for generated
// ZonoPatch outputs. It intentionally mirrors the structural behavior required
// by Apple's embedded signature format without importing third-party signer
// code: rebuild SHA-1 + SHA-256 CodeDirectories, requirements, page hashes,
// LC_CODE_SIGNATURE size, and __LINKEDIT size. Final IPA signing is still
// required after replacing the generated binary.

static const uint32_t kZNCSMagicEmbeddedSignature = 0xfade0cc0u;
static const uint32_t kZNCSMagicRequirements      = 0xfade0c01u;
static const uint32_t kZNCSMagicRequirement       = 0xfade0c00u;
static const uint32_t kZNCSMagicCodeDirectory     = 0xfade0c02u;
static const uint32_t kZNCSSlotCodeDirectory      = 0u;
static const uint32_t kZNCSSlotRequirements       = 2u;
static const uint32_t kZNCSSlotAlternate          = 0x1000u;
static const uint32_t kZNCSRequirementDesignated  = 3u;
static const uint32_t kZNCSCodeDirectoryVersion   = 0x00020400u;
static const uint32_t kZNCSPageShift              = 12u;
static const uint64_t kZNCSPageSize               = 1ULL << kZNCSPageShift;
static const uint64_t kZNVMPage                    = 0x4000ULL;

struct ZNSignLayout {
    uint64_t codeSignatureCommandOffset;
    uint64_t linkeditCommandOffset;
    uint64_t signatureOffset;
    uint64_t signatureSize;
    uint64_t linkeditFileOffset;
    uint64_t execFileStart;
    uint64_t execFileEnd;
    uint64_t execFlags;
};

static uint64_t ZNAlign64(uint64_t value, uint64_t alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

static uint32_t ZNReadBE32(const uint8_t *p) {
    uint32_t value = 0;
    memcpy(&value, p, sizeof(value));
    return __builtin_bswap32(value);
}

static uint64_t ZNReadBE64(const uint8_t *p) {
    uint64_t value = 0;
    memcpy(&value, p, sizeof(value));
    return __builtin_bswap64(value);
}

static void ZNWriteBE32(uint8_t *p, uint32_t value) {
    value = __builtin_bswap32(value);
    memcpy(p, &value, sizeof(value));
}

static void ZNWriteBE64(uint8_t *p, uint64_t value) {
    value = __builtin_bswap64(value);
    memcpy(p, &value, sizeof(value));
}

static void ZNAppendBE32(NSMutableData *data, uint32_t value) {
    uint32_t be = __builtin_bswap32(value);
    [data appendBytes:&be length:sizeof(be)];
}

static BOOL ZNParseSignLayout(uint8_t *base, uint64_t size, ZNSignLayout &layout, NSString **error) {
    if (size < sizeof(struct mach_header_64)) {
        if (error) *error = @"Mach-O 太小";
        return NO;
    }
    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) {
        if (error) *error = @"ad-hoc signer 当前仅支持 thin arm64/arm64e Mach-O";
        return NO;
    }
    uint64_t commandEnd = sizeof(*mh) + (uint64_t)mh->sizeofcmds;
    if (commandEnd > size) {
        if (error) *error = @"Mach-O load commands 越界";
        return NO;
    }

    memset(&layout, 0, sizeof(layout));
    layout.codeSignatureCommandOffset = UINT64_MAX;
    layout.linkeditCommandOffset = UINT64_MAX;
    layout.execFileStart = UINT64_MAX;
    layout.execFlags = (mh->filetype == MH_EXECUTE) ? 1ULL : 0ULL;

    uint8_t *cursor = base + sizeof(*mh);
    uint8_t *limit = base + commandEnd;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > limit) {
            if (error) *error = @"load command 损坏";
            return NO;
        }
        struct load_command *lc = (struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command) || cursor + lc->cmdsize > limit) {
            if (error) *error = @"load command size 损坏";
            return NO;
        }
        if (lc->cmd == LC_CODE_SIGNATURE && lc->cmdsize >= sizeof(struct linkedit_data_command)) {
            struct linkedit_data_command *sig = (struct linkedit_data_command *)cursor;
            layout.codeSignatureCommandOffset = (uint64_t)(cursor - base);
            layout.signatureOffset = sig->dataoff;
            layout.signatureSize = sig->datasize;
        } else if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cursor;
            if (strncmp(seg->segname, SEG_LINKEDIT, 16) == 0) {
                layout.linkeditCommandOffset = (uint64_t)(cursor - base);
                layout.linkeditFileOffset = seg->fileoff;
            }
            if ((seg->initprot & VM_PROT_EXECUTE) && seg->filesize) {
                layout.execFileStart = MIN(layout.execFileStart, seg->fileoff);
                layout.execFileEnd = MAX(layout.execFileEnd, seg->fileoff + seg->filesize);
            }
        }
        cursor += lc->cmdsize;
    }

    if (layout.codeSignatureCommandOffset == UINT64_MAX || !layout.signatureOffset || !layout.signatureSize) {
        if (error) *error = @"目标没有可重建的 LC_CODE_SIGNATURE";
        return NO;
    }
    if (layout.linkeditCommandOffset == UINT64_MAX || layout.linkeditFileOffset > layout.signatureOffset) {
        if (error) *error = @"目标 __LINKEDIT 布局异常";
        return NO;
    }
    if (layout.signatureOffset > size || layout.signatureSize > size - layout.signatureOffset) {
        if (error) *error = @"LC_CODE_SIGNATURE 超出文件范围";
        return NO;
    }
    if (layout.execFileStart == UINT64_MAX || layout.execFileEnd > layout.signatureOffset) {
        if (error) *error = @"可执行 Segment 范围异常";
        return NO;
    }
    return YES;
}

static NSString *ZNExtractExistingIdentifier(const uint8_t *base, uint64_t size, const ZNSignLayout &layout) {
    if (layout.signatureOffset + 12 > size) return nil;
    const uint8_t *sig = base + layout.signatureOffset;
    uint64_t available = MIN(layout.signatureSize, size - layout.signatureOffset);
    if (ZNReadBE32(sig) != kZNCSMagicEmbeddedSignature) return nil;
    uint32_t total = ZNReadBE32(sig + 4);
    uint32_t count = ZNReadBE32(sig + 8);
    if (total > available || total < 12 || count > (total - 12) / 8) return nil;

    NSString *fallback = nil;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t blobOffset = ZNReadBE32(sig + 12 + i * 8 + 4);
        if (blobOffset > total || total - blobOffset < 44) continue;
        const uint8_t *blob = sig + blobOffset;
        if (ZNReadBE32(blob) != kZNCSMagicCodeDirectory) continue;
        uint32_t blobLength = ZNReadBE32(blob + 4);
        if (blobLength < 44 || blobOffset + blobLength > total) continue;
        uint32_t identOffset = ZNReadBE32(blob + 20);
        uint8_t hashType = blob[37];
        if (identOffset >= blobLength) continue;
        const char *ident = (const char *)(blob + identOffset);
        size_t maxLen = blobLength - identOffset;
        size_t len = strnlen(ident, maxLen);
        if (!len || len == maxLen) continue;
        NSString *candidate = [[NSString alloc] initWithBytes:ident length:len encoding:NSUTF8StringEncoding];
        if (!candidate.length) continue;
        if (hashType == 2) return candidate;
        if (!fallback) fallback = candidate;
    }
    return fallback;
}

static void ZNReqAppendBytes(NSMutableData *data, const void *bytes, uint32_t length) {
    ZNAppendBE32(data, length);
    if (length) [data appendBytes:bytes length:length];
    uint32_t padding = (4u - (length & 3u)) & 3u;
    if (padding) {
        static const uint8_t zeros[4] = {0,0,0,0};
        [data appendBytes:zeros length:padding];
    }
}

static void ZNReqAppendString(NSMutableData *data, NSString *string) {
    NSData *utf8 = [string dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    ZNReqAppendBytes(data, utf8.bytes, (uint32_t)utf8.length);
}

static NSData *ZNBuildRequirements(NSString *identifier) {
    NSMutableData *expr = [NSMutableData data];
    ZNAppendBE32(expr, 1);
    ZNAppendBE32(expr, 6);
    ZNAppendBE32(expr, 2);
    ZNReqAppendString(expr, identifier);
    ZNAppendBE32(expr, 6);
    ZNAppendBE32(expr, 15);
    ZNAppendBE32(expr, 6);
    ZNAppendBE32(expr, 11);
    ZNAppendBE32(expr, 0);
    ZNReqAppendString(expr, @"subject.CN");
    ZNAppendBE32(expr, 1);
    ZNReqAppendString(expr, @"");
    ZNAppendBE32(expr, 14);
    ZNAppendBE32(expr, 1);
    static const uint8_t appleExtensionOID[] = {0x2a,0x86,0x48,0x86,0xf7,0x63,0x64,0x06,0x02,0x01};
    ZNReqAppendBytes(expr, appleExtensionOID, sizeof(appleExtensionOID));
    ZNAppendBE32(expr, 0);

    uint32_t nestedLength = (uint32_t)(8 + expr.length);
    uint32_t totalLength = 20 + nestedLength;
    NSMutableData *requirements = [NSMutableData dataWithLength:totalLength];
    uint8_t *p = (uint8_t *)requirements.mutableBytes;
    ZNWriteBE32(p + 0, kZNCSMagicRequirements);
    ZNWriteBE32(p + 4, totalLength);
    ZNWriteBE32(p + 8, 1);
    ZNWriteBE32(p + 12, kZNCSRequirementDesignated);
    ZNWriteBE32(p + 16, 20);
    ZNWriteBE32(p + 20, kZNCSMagicRequirement);
    ZNWriteBE32(p + 24, nestedLength);
    memcpy(p + 28, expr.bytes, expr.length);
    return requirements;
}

static void ZNHashBytes(uint8_t hashType, const void *bytes, size_t length, uint8_t *out) {
    if (hashType == 1) CC_SHA1(bytes, (CC_LONG)length, out);
    else CC_SHA256(bytes, (CC_LONG)length, out);
}

static NSData *ZNBuildCodeDirectory(const uint8_t *base,
                                    uint64_t codeLimit,
                                    uint64_t execStart,
                                    uint64_t execEnd,
                                    uint64_t execFlags,
                                    NSString *identifier,
                                    NSData *requirements,
                                    uint8_t hashType,
                                    uint8_t hashSize,
                                    NSString **error) {
    uint64_t nCode64 = (codeLimit + kZNCSPageSize - 1) / kZNCSPageSize;
    if (nCode64 > UINT32_MAX) {
        if (error) *error = @"CodeDirectory code slot 数量溢出";
        return nil;
    }
    NSData *identData = [identifier dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    uint64_t identLength = identData.length + 1;
    const uint32_t nSpecial = 2;
    const uint32_t identOffset = 88;
    uint64_t hashOffset64 = (uint64_t)identOffset + identLength + (uint64_t)nSpecial * hashSize;
    uint64_t length64 = hashOffset64 + nCode64 * hashSize;
    if (length64 > UINT32_MAX || hashOffset64 > UINT32_MAX) {
        if (error) *error = @"CodeDirectory 大小溢出";
        return nil;
    }

    NSMutableData *directory = [NSMutableData dataWithLength:(NSUInteger)length64];
    uint8_t *p = (uint8_t *)directory.mutableBytes;
    ZNWriteBE32(p + 0, kZNCSMagicCodeDirectory);
    ZNWriteBE32(p + 4, (uint32_t)length64);
    ZNWriteBE32(p + 8, kZNCSCodeDirectoryVersion);
    ZNWriteBE32(p + 12, 0);
    ZNWriteBE32(p + 16, (uint32_t)hashOffset64);
    ZNWriteBE32(p + 20, identOffset);
    ZNWriteBE32(p + 24, nSpecial);
    ZNWriteBE32(p + 28, (uint32_t)nCode64);
    ZNWriteBE32(p + 32, codeLimit > UINT32_MAX ? UINT32_MAX : (uint32_t)codeLimit);
    p[36] = hashSize;
    p[37] = hashType;
    p[38] = 0;
    p[39] = kZNCSPageShift;
    ZNWriteBE32(p + 40, 0);
    ZNWriteBE32(p + 44, 0);
    ZNWriteBE32(p + 48, 0);
    ZNWriteBE32(p + 52, 0);
    ZNWriteBE64(p + 56, codeLimit > UINT32_MAX ? codeLimit : 0);
    ZNWriteBE64(p + 64, execStart);
    ZNWriteBE64(p + 72, execEnd - execStart);
    ZNWriteBE64(p + 80, execFlags);

    memcpy(p + identOffset, identData.bytes, identData.length);
    p[identOffset + identData.length] = 0;

    uint8_t *codeHashes = p + hashOffset64;
    uint8_t *requirementsSlot = codeHashes - 2 * hashSize;
    ZNHashBytes(hashType, requirements.bytes, requirements.length, requirementsSlot);

    for (uint64_t i = 0; i < nCode64; i++) {
        uint64_t pageOffset = i * kZNCSPageSize;
        size_t pageLength = (size_t)MIN(kZNCSPageSize, codeLimit - pageOffset);
        ZNHashBytes(hashType, base + pageOffset, pageLength, codeHashes + i * hashSize);
    }
    return directory;
}

static NSData *ZNBuildSuperBlob(NSData *sha1Directory,
                                NSData *requirements,
                                NSData *sha256Directory) {
    uint64_t total64 = 36ULL + sha1Directory.length + requirements.length + sha256Directory.length;
    if (total64 > UINT32_MAX) return nil;
    uint32_t total = (uint32_t)total64;
    NSMutableData *superBlob = [NSMutableData dataWithLength:total];
    uint8_t *p = (uint8_t *)superBlob.mutableBytes;
    ZNWriteBE32(p + 0, kZNCSMagicEmbeddedSignature);
    ZNWriteBE32(p + 4, total);
    ZNWriteBE32(p + 8, 3);

    uint32_t sha1Offset = 36;
    uint32_t reqOffset = sha1Offset + (uint32_t)sha1Directory.length;
    uint32_t sha256Offset = reqOffset + (uint32_t)requirements.length;
    ZNWriteBE32(p + 12, kZNCSSlotCodeDirectory);
    ZNWriteBE32(p + 16, sha1Offset);
    ZNWriteBE32(p + 20, kZNCSSlotRequirements);
    ZNWriteBE32(p + 24, reqOffset);
    ZNWriteBE32(p + 28, kZNCSSlotAlternate);
    ZNWriteBE32(p + 32, sha256Offset);
    memcpy(p + sha1Offset, sha1Directory.bytes, sha1Directory.length);
    memcpy(p + reqOffset, requirements.bytes, requirements.length);
    memcpy(p + sha256Offset, sha256Directory.bytes, sha256Directory.length);
    return superBlob;
}

static BOOL ZNVerifyCodeDirectory(const uint8_t *base,
                                  uint64_t fileSize,
                                  uint64_t signatureOffset,
                                  const uint8_t *blob,
                                  uint32_t blobLength,
                                  uint32_t *mismatches,
                                  NSString **error) {
    if (blobLength < 88 || ZNReadBE32(blob) != kZNCSMagicCodeDirectory) {
        if (error) *error = @"CodeDirectory 结构损坏";
        return NO;
    }
    uint32_t length = ZNReadBE32(blob + 4);
    uint32_t hashOffset = ZNReadBE32(blob + 16);
    uint32_t nCode = ZNReadBE32(blob + 28);
    uint32_t codeLimit32 = ZNReadBE32(blob + 32);
    uint8_t hashSize = blob[36];
    uint8_t hashType = blob[37];
    uint8_t pageShift = blob[39];
    uint32_t version = ZNReadBE32(blob + 8);
    uint64_t codeLimit = codeLimit32;
    if (version >= 0x20300 && codeLimit32 == UINT32_MAX && length >= 64) codeLimit = ZNReadBE64(blob + 56);
    if (length > blobLength || codeLimit != signatureOffset || codeLimit > fileSize || pageShift >= 31) {
        if (error) *error = @"CodeDirectory codeLimit/pageSize 异常";
        return NO;
    }
    if (!((hashType == 1 && hashSize == CC_SHA1_DIGEST_LENGTH) ||
          (hashType == 2 && hashSize == CC_SHA256_DIGEST_LENGTH))) {
        if (error) *error = @"CodeDirectory hash 算法不受支持";
        return NO;
    }
    uint64_t pageSize = 1ULL << pageShift;
    uint64_t expectedSlots = (codeLimit + pageSize - 1) / pageSize;
    if (expectedSlots != nCode || (uint64_t)hashOffset + (uint64_t)nCode * hashSize > length) {
        if (error) *error = @"CodeDirectory slot 表越界";
        return NO;
    }

    uint32_t bad = 0;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    for (uint64_t i = 0; i < nCode; i++) {
        uint64_t pageOffset = i * pageSize;
        size_t pageLength = (size_t)MIN(pageSize, codeLimit - pageOffset);
        memset(digest, 0, sizeof(digest));
        ZNHashBytes(hashType, base + pageOffset, pageLength, digest);
        if (memcmp(digest, blob + hashOffset + i * hashSize, hashSize) != 0) bad++;
    }
    if (mismatches) *mismatches = bad;
    if (bad) {
        if (error) *error = [NSString stringWithFormat:@"CodeDirectory page hash 不匹配：%u", bad];
        return NO;
    }
    return YES;
}

static BOOL ZNVerifyEmbeddedSignature(uint8_t *base,
                                      uint64_t fileSize,
                                      const ZNSignLayout &layout,
                                      NSDictionary **metadata,
                                      NSString **error) {
    if (layout.signatureOffset + 12 > fileSize || layout.signatureSize > fileSize - layout.signatureOffset) {
        if (error) *error = @"重签后的 LC_CODE_SIGNATURE 越界";
        return NO;
    }
    const uint8_t *sig = base + layout.signatureOffset;
    if (ZNReadBE32(sig) != kZNCSMagicEmbeddedSignature) {
        if (error) *error = @"重签后的 SuperBlob magic 错误";
        return NO;
    }
    uint32_t total = ZNReadBE32(sig + 4);
    uint32_t count = ZNReadBE32(sig + 8);
    if (total > layout.signatureSize || total < 12 || count > (total - 12) / 8) {
        if (error) *error = @"重签后的 SuperBlob 长度错误";
        return NO;
    }

    BOOL sawSHA1 = NO, sawSHA256 = NO;
    uint32_t sha1Bad = UINT32_MAX, sha256Bad = UINT32_MAX;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t offset = ZNReadBE32(sig + 12 + i * 8 + 4);
        if (offset > total || total - offset < 8) continue;
        const uint8_t *blob = sig + offset;
        uint32_t magic = ZNReadBE32(blob);
        uint32_t length = ZNReadBE32(blob + 4);
        if (length < 8 || offset + length > total || magic != kZNCSMagicCodeDirectory) continue;
        uint8_t hashType = blob[37];
        uint32_t bad = 0;
        NSString *verifyError = nil;
        if (!ZNVerifyCodeDirectory(base, fileSize, layout.signatureOffset, blob, length, &bad, &verifyError)) {
            if (error) *error = verifyError ?: @"CodeDirectory 验证失败";
            return NO;
        }
        if (hashType == 1) { sawSHA1 = YES; sha1Bad = bad; }
        if (hashType == 2) { sawSHA256 = YES; sha256Bad = bad; }
    }
    if (!sawSHA1 || !sawSHA256) {
        if (error) *error = @"重签结果缺少 SHA-1/SHA-256 CodeDirectory";
        return NO;
    }
    if (metadata) {
        *metadata = @{
            @"codeLimit": [NSString stringWithFormat:@"0x%llX", layout.signatureOffset],
            @"signatureSize": @(layout.signatureSize),
            @"sha1PageHashMismatches": @(sha1Bad),
            @"sha256PageHashMismatches": @(sha256Bad),
            @"verified": @YES,
        };
    }
    return YES;
}

BOOL ZNAdhocResignMachOAtPath(NSString *path, NSDictionary **metadata, NSString **error) {
    if (!path.length) {
        if (error) *error = @"重签路径为空";
        return NO;
    }
    int fd = open(path.fileSystemRepresentation, O_RDWR);
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"打开待重签 Mach-O 失败：errno=%d", errno];
        return NO;
    }

    BOOL success = NO;
    NSString *localError = nil;
    NSDictionary *verifyMetadata = nil;
    NSString *identifier = nil;
    uint64_t oldSize = 0;
    ZNSignLayout oldLayout = {};

    struct stat st = {};
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        localError = @"读取待重签 Mach-O 大小失败";
    } else {
        oldSize = (uint64_t)st.st_size;
        uint8_t *oldBase = (uint8_t *)mmap(NULL, (size_t)oldSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (oldBase == MAP_FAILED) {
            localError = [NSString stringWithFormat:@"mmap 待重签 Mach-O 失败：errno=%d", errno];
        } else {
            if (ZNParseSignLayout(oldBase, oldSize, oldLayout, &localError)) {
                identifier = ZNExtractExistingIdentifier(oldBase, oldSize, oldLayout);
                if (!identifier.length) identifier = path.lastPathComponent.length ? path.lastPathComponent : @"ZonoPatch.generated";

                uint64_t usedEnd = oldLayout.signatureOffset + oldLayout.signatureSize;
                if (usedEnd > oldSize) {
                    localError = @"旧签名范围越界";
                } else {
                    for (uint64_t i = usedEnd; i < oldSize; i++) {
                        if (oldBase[i] != 0) {
                            localError = @"LC_CODE_SIGNATURE 之后存在非零数据，拒绝截断";
                            break;
                        }
                    }
                }
            }
            munmap(oldBase, (size_t)oldSize);
        }
    }

    NSData *requirements = nil;
    uint64_t codeLimit = oldLayout.signatureOffset;
    uint64_t nCode = (codeLimit + kZNCSPageSize - 1) / kZNCSPageSize;
    uint64_t identLength = [[identifier dataUsingEncoding:NSUTF8StringEncoding] length] + 1;
    uint64_t sha1Length = 88 + identLength + 2 * CC_SHA1_DIGEST_LENGTH + nCode * CC_SHA1_DIGEST_LENGTH;
    uint64_t sha256Length = 88 + identLength + 2 * CC_SHA256_DIGEST_LENGTH + nCode * CC_SHA256_DIGEST_LENGTH;
    uint64_t signatureAlloc = 0;

    if (!localError) {
        requirements = ZNBuildRequirements(identifier);
        uint64_t superLength = 36 + sha1Length + requirements.length + sha256Length;
        if (superLength > UINT32_MAX || codeLimit > UINT32_MAX) {
            localError = @"Phase 1 ad-hoc signer 暂不处理 >4GB Mach-O/签名";
        } else {
            uint64_t normal = nCode;
            uint64_t directoryBase = 8 + 8 + 80 + identLength;
            signatureAlloc = 12 + 8 + requirements.length;
            signatureAlloc = ZNAlign64(signatureAlloc + directoryBase + (2 + normal) * CC_SHA1_DIGEST_LENGTH, 16);
            signatureAlloc = ZNAlign64(signatureAlloc + directoryBase + (2 + normal) * CC_SHA256_DIGEST_LENGTH, 16);
            if (signatureAlloc < superLength || codeLimit > UINT64_MAX - signatureAlloc) localError = @"重签文件大小溢出";
        }
    }

    uint64_t finalSize = codeLimit + signatureAlloc;
    if (!localError && ftruncate(fd, (off_t)finalSize) != 0) {
        localError = [NSString stringWithFormat:@"调整重签文件大小失败：errno=%d", errno];
    }

    if (!localError) {
        uint8_t *base = (uint8_t *)mmap(NULL, (size_t)finalSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (base == MAP_FAILED) {
            localError = [NSString stringWithFormat:@"mmap 重签输出失败：errno=%d", errno];
        } else {
            do {
                struct linkedit_data_command *sig = (struct linkedit_data_command *)(base + oldLayout.codeSignatureCommandOffset);
                struct segment_command_64 *linkedit = (struct segment_command_64 *)(base + oldLayout.linkeditCommandOffset);
                sig->dataoff = (uint32_t)codeLimit;
                sig->datasize = (uint32_t)signatureAlloc;
                linkedit->filesize = finalSize - linkedit->fileoff;
                linkedit->vmsize = ZNAlign64(linkedit->filesize, kZNVMPage);
                memset(base + codeLimit, 0, (size_t)signatureAlloc);

                ZNSignLayout layout = {};
                if (!ZNParseSignLayout(base, finalSize, layout, &localError)) break;
                if (layout.signatureOffset != codeLimit || layout.signatureSize != signatureAlloc) {
                    localError = @"重签后的 LC_CODE_SIGNATURE 布局与预期不一致";
                    break;
                }

                NSData *sha1 = ZNBuildCodeDirectory(base, codeLimit,
                                                    layout.execFileStart, layout.execFileEnd, layout.execFlags,
                                                    identifier, requirements,
                                                    1, CC_SHA1_DIGEST_LENGTH, &localError);
                if (!sha1) break;
                NSData *sha256 = ZNBuildCodeDirectory(base, codeLimit,
                                                      layout.execFileStart, layout.execFileEnd, layout.execFlags,
                                                      identifier, requirements,
                                                      2, CC_SHA256_DIGEST_LENGTH, &localError);
                if (!sha256) break;
                NSData *superBlob = ZNBuildSuperBlob(sha1, requirements, sha256);
                if (!superBlob || superBlob.length > signatureAlloc) {
                    localError = @"生成的 SuperBlob 超出预留签名空间";
                    break;
                }
                memcpy(base + codeLimit, superBlob.bytes, superBlob.length);

                if (msync(base, (size_t)finalSize, MS_SYNC) != 0) {
                    localError = [NSString stringWithFormat:@"重签 msync 失败：errno=%d", errno];
                    break;
                }
                if (!ZNVerifyEmbeddedSignature(base, finalSize, layout, &verifyMetadata, &localError)) break;
                success = YES;
            } while (0);
            munmap(base, (size_t)finalSize);
        }
    }

    close(fd);
    if (!success) {
        if (error) *error = localError ?: @"Mach-O ad-hoc 重签失败";
        return NO;
    }
    if (metadata) {
        NSMutableDictionary *result = [verifyMetadata mutableCopy] ?: [NSMutableDictionary dictionary];
        result[@"identifier"] = identifier ?: @"";
        result[@"mode"] = @"zonoe-self-contained-adhoc";
        result[@"finalPackageResignRequired"] = @YES;
        *metadata = result;
    }
    return YES;
}
