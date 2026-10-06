#import "ZNStaticRVAProtection.h"
#import <mach-o/loader.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>

BOOL ZN55ProtectStaticRVAsAtPath(NSString *path,
                                 NSUInteger *protectedEntries,
                                 NSString **error) {
    if (protectedEntries) *protectedEntries = 0;
    if (!path.length) {
        if (error) *error = @"RVA Protection 输出路径为空";
        return NO;
    }

    int fd = open(path.fileSystemRepresentation, O_RDWR);
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"RVA Protection 打开输出失败：errno=%d", errno];
        return NO;
    }

    struct stat st = {};
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(fd);
        if (error) *error = @"RVA Protection 输出大小无效";
        return NO;
    }

    size_t size = (size_t)st.st_size;
    uint8_t *base = (uint8_t *)mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        close(fd);
        if (error) *error = @"RVA Protection mmap 失败";
        return NO;
    }

    BOOL ok = NO;
    NSString *localError = nil;
    NSUInteger total = 0;

    do {
        struct mach_header_64 *mh = (struct mach_header_64 *)base;
        if (mh->magic != MH_MAGIC_64) {
            localError = @"RVA Protection V1 仅支持 thin 64-bit Mach-O";
            break;
        }

        uint64_t commandEnd = sizeof(*mh) + (uint64_t)mh->sizeofcmds;
        if (commandEnd > size) {
            localError = @"RVA Protection load commands 越界";
            break;
        }

        uint8_t *cursor = base + sizeof(*mh);
        uint8_t *limit = base + commandEnd;
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            if (cursor + sizeof(struct load_command) > limit) {
                localError = @"RVA Protection load command 损坏";
                break;
            }
            struct load_command *lc = (struct load_command *)cursor;
            if (lc->cmdsize < sizeof(struct load_command) || cursor + lc->cmdsize > limit) {
                localError = @"RVA Protection load command size 损坏";
                break;
            }

            if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                struct segment_command_64 *seg = (struct segment_command_64 *)cursor;
                if (strncmp(seg->segname, "__ZNDATA", 16) == 0) {
                    if (seg->fileoff > size || seg->filesize > size - seg->fileoff) {
                        localError = @"RVA Protection __ZNDATA range 越界";
                        break;
                    }

                    uint64_t start = seg->fileoff;
                    uint64_t end = seg->fileoff + seg->filesize;
                    uint64_t scan = (start + 7u) & ~UINT64_C(7);
                    for (; scan + sizeof(ZN44StaticHeader) <= end; scan += 8u) {
                        ZN44StaticHeader *header = (ZN44StaticHeader *)(base + scan);
                        if (header->magic0 != ZN44_STATIC_MAGIC0 || header->magic1 != ZN44_STATIC_MAGIC1) continue;
                        if ((header->version != ZN44_STATIC_VERSION_V1 && header->version != ZN44_STATIC_VERSION_V2) ||
                            header->entrySize != sizeof(ZN44StaticEntry) ||
                            header->count == 0 || header->count > ZN44_STATIC_MAX_ENTRIES) {
                            continue;
                        }

                        uint64_t bytes = sizeof(ZN44StaticHeader) + (uint64_t)header->count * sizeof(ZN44StaticEntry);
                        if (scan + bytes > end) {
                            localError = @"RVA Protection Static Header 越界";
                            break;
                        }

                        ZN44StaticEntry *entries = (ZN44StaticEntry *)(header + 1);
                        if (header->flags & ZN44_STATIC_HEADER_FLAG_RVA_PROTECTION_V1) {
                            if (!ZN55ValidateProtectedHeader(header, entries)) {
                                localError = @"已有 RVA Protection metadata 校验失败";
                                break;
                            }
                        } else {
                            uint64_t nonce = 0;
                            arc4random_buf(&nonce, sizeof(nonce));
                            if (!nonce) nonce = ZN55Mix64((uint64_t)scan ^ (uint64_t)size ^ UINT64_C(0x58D2F4A19E37C60B));
                            if (!ZN55ProtectHeaderEntries(header, entries, nonce)) {
                                localError = @"RVA Protection V1 编码/回读校验失败";
                                break;
                            }
                        }
                        total += header->count;
                        scan += bytes - 8u;
                    }
                    if (localError) break;
                }
            }
            cursor += lc->cmdsize;
        }

        if (localError) break;
        if (!total) {
            localError = @"未在 __ZNDATA 找到可保护的 Static Dispatch metadata";
            break;
        }
        if (msync(base, size, MS_SYNC) != 0) {
            localError = [NSString stringWithFormat:@"RVA Protection msync 失败：errno=%d", errno];
            break;
        }
        ok = YES;
    } while (0);

    munmap(base, size);
    close(fd);

    if (protectedEntries) *protectedEntries = total;
    if (!ok && error) *error = localError ?: @"RVA Protection V1 失败";
    return ok;
}
