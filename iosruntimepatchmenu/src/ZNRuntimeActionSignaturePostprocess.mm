#import "ZNRuntimeActionSignaturePostprocess.h"

#import "ZNIL2CPPMethodSignature.h"
#import "ZNRuntimeActionFormat.h"
#import "ZNRuntimeActionModel.h"
#import "ZNNativeHookAction.h"
#import "ZNStaticPatchFormat.h"
#import "ZNGeneratedDataLayout.h"
#import "ZNPatchCore.h"
#import <mach-o/loader.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#include <string.h>

static uint64_t ZNM46Align8(uint64_t value) {
    return (value + 7ULL) & ~7ULL;
}

static BOOL ZNM46ZeroRange(const uint8_t *bytes, uint64_t length) {
    for (uint64_t i = 0; i < length; i++) if (bytes[i] != 0) return NO;
    return YES;
}

static NSString *ZNM46UnityOutput(NSArray<NSString *> *outputs) {
    for (NSString *path in outputs ?: @[]) {
        NSString *name = path.lastPathComponent.lowercaseString;
        if ([name hasSuffix:@".znpatched"] && [name containsString:@"unityframework"]) return path;
    }
    return nil;
}

static BOOL ZNM46AugmentPath(NSString *path,
                             NSArray<ZNRuntimeMethodAction *> *actions,
                             NSUInteger *outFullCount,
                             NSString **error) {
    int fd = open(path.fileSystemRepresentation, O_RDWR);
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"M4.6 打开 %@ 失败 errno=%d", path.lastPathComponent, errno];
        return NO;
    }
    struct stat st = {};
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        if (error) *error = @"M4.6 读取生成物大小失败";
        return NO;
    }
    size_t fileSize = (size_t)st.st_size;
    uint8_t *base = (uint8_t *)mmap(NULL, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        close(fd);
        if (error) *error = @"M4.6 mmap 生成物失败";
        return NO;
    }

    BOOL ok = NO;
    NSString *localError = nil;
    NSUInteger fullCount = 0;
    do {
        if (fileSize < sizeof(struct mach_header_64)) { localError = @"M4.6 生成物不是完整 Mach-O"; break; }
        struct mach_header_64 *mh = (struct mach_header_64 *)base;
        if (mh->magic != MH_MAGIC_64) { localError = @"M4.6 仅支持 thin 64-bit Mach-O"; break; }
        uint64_t commandEnd = sizeof(*mh) + (uint64_t)mh->sizeofcmds;
        if (commandEnd > fileSize) { localError = @"M4.6 Mach-O load commands 越界"; break; }

        struct segment_command_64 *owned = NULL;
        struct section_64 *zndata = NULL;
        uint8_t *cursor = base + sizeof(*mh);
        uint8_t *limit = base + commandEnd;
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            if (cursor + sizeof(struct load_command) > limit) { localError = @"M4.6 load command 损坏"; break; }
            struct load_command *lc = (struct load_command *)cursor;
            if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > limit) { localError = @"M4.6 load command size 损坏"; break; }
            if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                struct segment_command_64 *seg = (struct segment_command_64 *)cursor;
                if (strncmp(seg->segname, "__ZNDATA", 16) == 0) {
                    owned = seg;
                    uint64_t sectionBytes = (uint64_t)seg->nsects * sizeof(struct section_64);
                    if (lc->cmdsize < sizeof(*seg) + sectionBytes) { localError = @"M4.6 __ZNDATA section table 越界"; break; }
                    struct section_64 *sections = (struct section_64 *)(seg + 1);
                    for (uint32_t j = 0; j < seg->nsects; j++) {
                        if (strncmp(sections[j].sectname, "__zndata", 16) == 0) { zndata = &sections[j]; break; }
                    }
                }
            }
            cursor += lc->cmdsize;
        }
        if (localError) break;
        if (!owned || !zndata) { localError = @"M4.6 缺少 __ZNDATA/__zndata"; break; }
        if (owned->fileoff > fileSize || owned->filesize > fileSize - owned->fileoff) { localError = @"M4.6 __ZNDATA file range 越界"; break; }
        if (zndata->offset > fileSize || zndata->size > fileSize - zndata->offset) { localError = @"M4.6 __zndata range 越界"; break; }
        if (zndata->size < sizeof(ZN44StaticHeader)) { localError = @"M4.6 __zndata 缺少 Static Header"; break; }

        uint64_t sectionStart = zndata->offset;
        ZN44StaticHeader *staticHeader = (ZN44StaticHeader *)(base + sectionStart);
        if (staticHeader->magic0 != ZN44_STATIC_MAGIC0 || staticHeader->magic1 != ZN44_STATIC_MAGIC1 ||
            staticHeader->entrySize != sizeof(ZN44StaticEntry) || staticHeader->count > ZN44_STATIC_MAX_ENTRIES) {
            localError = @"M4.6 Static Dispatch Header 无效";
            break;
        }
        uint64_t actionRelative = 0;
        if (!ZNGeneratedDataLayoutV1LocateRuntimeAction(base + sectionStart, zndata->size, &actionRelative) ||
            actionRelative > zndata->size || zndata->size - actionRelative < sizeof(ZNRuntimeActionHeader)) {
            localError = @"M6.8.4 Generated Data Layout V1 / Runtime Action table 无效";
            break;
        }

        uint64_t tableOffset = sectionStart + actionRelative;
        ZNRuntimeActionHeader *header = (ZNRuntimeActionHeader *)(base + tableOffset);
        if (header->magic != ZN_RUNTIME_ACTION_MAGIC || header->version != ZN_RUNTIME_ACTION_VERSION ||
            header->entrySize != sizeof(ZNRuntimeMethodCallEntry) || header->count > ZN_RUNTIME_ACTION_MAX_ENTRIES) {
            localError = @"M4.6 Runtime Action Header 无效";
            break;
        }
        NSUInteger hookCount = [[ZNNativeHookStore sharedStore] actionsSnapshot].count;
        NSUInteger expectedTotal = actions.count + hookCount;
        if (header->count != expectedTotal) {
            localError = [NSString stringWithFormat:@"M6.4 Runtime Action 顺序契约不一致：table=%u methods=%lu hooks=%lu",
                          header->count, (unsigned long)actions.count, (unsigned long)hookCount];
            break;
        }
        uint64_t entryBytes = (uint64_t)header->count * header->entrySize;
        uint64_t fixedEnd = sizeof(*header) + entryBytes;
        if (fixedEnd > header->totalSize || header->stringPoolOffset < fixedEnd ||
            header->totalSize > zndata->size - actionRelative) {
            localError = @"M4.6 Runtime Action table size 无效";
            break;
        }

        ZNRuntimeMethodCallEntry *entries = (ZNRuntimeMethodCallEntry *)(base + tableOffset + sizeof(*header));
        NSMutableArray<NSData *> *encodedStrings = [NSMutableArray arrayWithCapacity:actions.count];
        uint64_t addedBytes = 0;
        for (NSUInteger i = 0; i < actions.count; i++) {
            ZNRuntimeMethodAction *action = actions[i];
            if (entries[i].actionID != action.actionID) {
                localError = [NSString stringWithFormat:@"M4.6 Runtime Action actionID 顺序不一致 index=%lu table=%u model=%u",
                              (unsigned long)i, entries[i].actionID, action.actionID];
                break;
            }
            if (!action.signatureAvailable || action.parameterTypeNames.count != action.argumentCount) {
                [encodedStrings addObject:[NSData data]];
                continue;
            }
            NSString *encoded = ZNIL2CPPEncodeParameterTypeNames(action.parameterTypeNames ?: @[]);
            if (action.argumentCount > 0 && !encoded.length) {
                localError = [NSString stringWithFormat:@"M4.6 参数签名编码失败：%@", action.canonicalIdentity];
                break;
            }
            NSMutableData *bytes = [[encoded dataUsingEncoding:NSUTF8StringEncoding] mutableCopy] ?: [NSMutableData data];
            uint8_t zero = 0;
            [bytes appendBytes:&zero length:1];
            [encodedStrings addObject:bytes];
            addedBytes += bytes.length;
            fullCount++;
        }
        if (localError) break;

        uint64_t oldTotal = header->totalSize;
        uint64_t newTotalUnaligned = oldTotal + addedBytes;
        uint64_t newTotal = ZNM46Align8(newTotalUnaligned);
        uint64_t tableEnd = tableOffset + newTotal;
        uint64_t segmentEnd = owned->fileoff + owned->filesize;
        if (tableEnd < tableOffset || tableEnd > segmentEnd || tableEnd > fileSize) {
            localError = [NSString stringWithFormat:@"M4.6 signature string pool capacity 不足：+%llu bytes",
                          (unsigned long long)(newTotal - oldTotal)];
            break;
        }
        uint64_t appendOffset = tableOffset + oldTotal;
        if (newTotal > oldTotal && !ZNM46ZeroRange(base + appendOffset, newTotal - oldTotal)) {
            localError = @"M4.6 signature 目标区域不是 owned zero padding；拒绝覆盖未知数据";
            break;
        }

        uint64_t writeOffset = appendOffset;
        for (NSUInteger i = 0; i < actions.count; i++) {
            NSData *bytes = encodedStrings[i];
            if (!bytes.length) continue;
            uint64_t relative = writeOffset - tableOffset;
            if (relative > UINT32_MAX) { localError = @"M4.6 signature offset 超过 32-bit"; break; }
            memcpy(base + writeOffset, bytes.bytes, bytes.length);
            entries[i].flags |= ZNRuntimeActionFlagParameterSignature;
            entries[i].reserved[1] = (uint32_t)relative;
            writeOffset += bytes.length;
        }
        if (localError) break;

        header->totalSize = (uint32_t)newTotal;
        header->stringPoolSize = header->totalSize - header->stringPoolOffset;
        zndata->size = actionRelative + newTotal;
        if (msync(base, fileSize, MS_SYNC) != 0) {
            localError = [NSString stringWithFormat:@"M4.6 signature msync 失败 errno=%d", errno];
            break;
        }
        ok = YES;
    } while (0);

    munmap(base, fileSize);
    close(fd);
    if (outFullCount) *outFullCount = fullCount;
    if (!ok && error) *error = localError ?: @"M4.6 signature table augmentation 失败";
    return ok;
}

BOOL ZNRuntimeActionAugmentGeneratedOutputsM46(NSArray<NSString *> *builderOutputs,
                                               NSString **report,
                                               NSString **error) {
    NSArray<ZNRuntimeMethodAction *> *actions = [[ZNRuntimeActionStore sharedStore] actionsSnapshot];
    if (!actions.count) {
        if (report) *report = @"M4.6 Full Signature：无 Runtime Action";
        return YES;
    }
    NSString *unityOutput = ZNM46UnityOutput(builderOutputs);
    if (!unityOutput.length) {
        if (error) *error = @"M4.6 Full Signature：没有 UnityFramework.znpatched 输出";
        return NO;
    }
    NSUInteger fullCount = 0;
    NSString *localError = nil;
    if (!ZNM46AugmentPath(unityOutput, actions, &fullCount, &localError)) {
        if (error) *error = localError ?: @"M4.6 Full Signature 写入失败";
        return NO;
    }
    if (report) {
        *report = [NSString stringWithFormat:@"M4.6 Full Signature：%lu/%lu actions 已持久化精确参数类型 · Runtime Entry 仍为 64 bytes",
                   (unsigned long)fullCount, (unsigned long)actions.count];
    }
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m4.6-signature] embedded full signatures=%lu/%lu output=%@",
                                         (unsigned long)fullCount, (unsigned long)actions.count, unityOutput.lastPathComponent]];
    return YES;
}
