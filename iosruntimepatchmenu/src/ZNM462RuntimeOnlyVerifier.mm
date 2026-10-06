#import "ZNM462RuntimeOnlyVerifier.h"
#import "ZNRuntimeActionFormat.h"
#import "ZNStaticPatchFormat.h"
#import "ZNGeneratedDataLayout.h"
#import "ZNPatchCore.h"
#import "ZNComplexStructCodec.h"

#import <mach-o/loader.h>
#import <mach/vm_prot.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static uint64_t ZNM462Align8(uint64_t value) {
    return (value + 7ULL) & ~7ULL;
}

static BOOL ZNM462StringOffsetValid(const uint8_t *table,
                                    const ZNRuntimeActionHeader *header,
                                    uint32_t offset) {
    if (!table || !header) return NO;
    uint64_t poolStart = header->stringPoolOffset;
    uint64_t poolEnd = (uint64_t)header->stringPoolOffset + header->stringPoolSize;
    if (poolEnd > header->totalSize || offset < poolStart || offset >= poolEnd) return NO;
    const uint8_t *start = table + offset;
    const uint8_t *end = table + poolEnd;
    return memchr(start, 0, (size_t)(end - start)) != NULL;
}

static NSString *ZNM462ReadString(const uint8_t *table,
                                  const ZNRuntimeActionHeader *header,
                                  uint32_t offset) {
    if (!ZNM462StringOffsetValid(table, header, offset)) return nil;
    uint64_t poolEnd = (uint64_t)header->stringPoolOffset + header->stringPoolSize;
    const uint8_t *start = table + offset;
    const uint8_t *end = table + poolEnd;
    const uint8_t *nul = (const uint8_t *)memchr(start, 0, (size_t)(end - start));
    if (!nul) return nil;
    NSData *data = [NSData dataWithBytes:start length:(NSUInteger)(nul - start)];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static BOOL ZNM462ArgumentVectorValid(const uint8_t *table,
                                      const ZNRuntimeActionHeader *header,
                                      const ZNRuntimeMethodCallEntry *entry) {
    if (!entry || entry->argumentCount == 0) return YES;
    if ((entry->flags & ZNRuntimeActionFlagArgumentVectorText) == 0) return NO;
    NSString *json = ZNM462ReadString(table, header, entry->reserved[2]);
    if (!json.length) return NO;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![object isKindOfClass:NSArray.class] || [(NSArray *)object count] != entry->argumentCount) return NO;
    for (id item in (NSArray *)object) if (![item isKindOfClass:NSString.class]) return NO;
    return YES;
}

static BOOL ZNM462NativeHookConfigValid(const uint8_t *table,
                                        const ZNRuntimeActionHeader *header,
                                        const ZNRuntimeMethodCallEntry *entry) {
    if (!entry || entry->kind != ZNRuntimeActionKindIL2CPPNativeHook ||
        (entry->flags & ZNRuntimeActionFlagNativeHookConfig) == 0) return NO;
    NSString *json = ZNM462ReadString(table, header, entry->reserved[0]);
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *cfg = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![cfg isKindOfClass:NSDictionary.class]) return NO;
    NSString *templateKey=[cfg[@"template"] isKindOfClass:NSString.class]?cfg[@"template"]:@"";
    if ([templateKey isEqual:@"arg-scale-int32"]) {
        NSUInteger arg = [cfg[@"argumentIndex"] unsignedIntegerValue];
        NSInteger min = [cfg[@"min"] integerValue], max = [cfg[@"max"] integerValue], def = [cfg[@"default"] integerValue];
        return arg < entry->argumentCount && min >= 1 && max >= min && def >= min && def <= max;
    }
    if ([templateKey isEqual:@"managed-callback-short-circuit"]) {
        NSUInteger arg=[cfg[@"callbackArgumentIndex"] unsignedIntegerValue];
        return arg < entry->argumentCount && [cfg[@"skipOriginal"] boolValue];
    }
    if ([templateKey isEqual:@"return-bool-override"]) {
        return [cfg[@"returnBoolValue"] isKindOfClass:NSNumber.class];
    }
    if ([templateKey isEqual:@"struct-field-transform"]) {
        NSUInteger arg=[cfg[@"fieldArgumentIndex"] unsignedIntegerValue];
        NSString *mode=[cfg[@"fieldArgumentMode"] isKindOfClass:NSString.class]?cfg[@"fieldArgumentMode"]:@"";
        NSString *codec=[cfg[@"fieldCodec"] isKindOfClass:NSString.class]?cfg[@"fieldCodec"]:@"";
        NSString *codecClass=[cfg[@"codecClass"] isKindOfClass:NSString.class]?cfg[@"codecClass"]:@"";
        NSString *getter=[cfg[@"codecGetterMethod"] isKindOfClass:NSString.class]?cfg[@"codecGetterMethod"]:@"";
        NSString *setter=[cfg[@"codecSetterMethod"] isKindOfClass:NSString.class]?cfg[@"codecSetterMethod"]:@"";
        uint64_t fieldOffset=[cfg[@"fieldOffset"] unsignedLongLongValue];
        NSInteger min=[cfg[@"min"] integerValue],max=[cfg[@"max"] integerValue],def=[cfg[@"default"] integerValue];
        return arg < entry->argumentCount &&
               [mode isEqualToString:@"indirect-pointer"] &&
               [codec isEqualToString:@"secure-long-accessor"] &&
               fieldOffset <= 0x100000ULL &&
               codecClass.length && getter.length && setter.length &&
               min >= 1 && max >= min && def >= min && def <= max;
    }
    if ([templateKey isEqual:@"complex-struct-transform"]) {
        NSUInteger arg=[cfg[@"fieldArgumentIndex"] unsignedIntegerValue];
        NSString *mode=[cfg[@"fieldArgumentMode"] isKindOfClass:NSString.class]?cfg[@"fieldArgumentMode"]:@"";
        NSString *codec=[cfg[@"fieldCodec"] isKindOfClass:NSString.class]?cfg[@"fieldCodec"]:@"";
        NSString *codecClass=[cfg[@"codecClass"] isKindOfClass:NSString.class]?cfg[@"codecClass"]:@"";
        uint64_t fieldOffset=[cfg[@"fieldOffset"] unsignedLongLongValue];
        NSInteger min=[cfg[@"min"] integerValue],max=[cfg[@"max"] integerValue],def=[cfg[@"default"] integerValue];
        NSString *expected=ZNComplexStructCodecKeyForManagedType(codecClass);
        return arg < entry->argumentCount &&
               [mode isEqualToString:@"indirect-pointer"] &&
               codec.length && [expected isEqualToString:codec] &&
               fieldOffset == 0 && codecClass.length &&
               min >= 1 && max >= min && def >= min && def <= max;
    }
    return NO;
}

static BOOL ZNM462VerifyPath(NSString *path,
                             NSUInteger expectedActionCount,
                             NSString **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
        if (error) *error = [NSString stringWithFormat:@"M4.6.2 verifier：打开 %@ 失败 errno=%d", path.lastPathComponent, errno];
        return NO;
    }
    struct stat st = {};
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(fd);
        if (error) *error = @"M4.6.2 verifier：生成物大小无效";
        return NO;
    }
    size_t size = (size_t)st.st_size;
    const uint8_t *base = (const uint8_t *)mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (base == MAP_FAILED) {
        close(fd);
        if (error) *error = @"M4.6.2 verifier：mmap 失败";
        return NO;
    }

    BOOL ok = NO;
    NSString *localError = nil;
    do {
        const struct mach_header_64 *mh = (const struct mach_header_64 *)base;
        if (mh->magic != MH_MAGIC_64) { localError = @"M4.6.2 verifier：不是 thin 64-bit Mach-O"; break; }
        uint64_t commandEnd = sizeof(*mh) + (uint64_t)mh->sizeofcmds;
        if (commandEnd > size) { localError = @"M4.6.2 verifier：load commands 越界"; break; }

        const struct segment_command_64 *owned = NULL;
        const struct section_64 *zndata = NULL;
        NSUInteger ownedCount = 0;
        const uint8_t *cursor = base + sizeof(*mh);
        const uint8_t *limit = base + commandEnd;
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            if (cursor + sizeof(struct load_command) > limit) { localError = @"M4.6.2 verifier：load command 损坏"; break; }
            const struct load_command *lc = (const struct load_command *)cursor;
            if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > limit) { localError = @"M4.6.2 verifier：load command size 损坏"; break; }
            if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cursor;
                uint64_t sectionBytes = (uint64_t)seg->nsects * sizeof(struct section_64);
                if (lc->cmdsize < sizeof(*seg) + sectionBytes) { localError = @"M4.6.2 verifier：section table 越界"; break; }
                if (strncmp(seg->segname, "__ZNDATA", 16) == 0) {
                    ownedCount++;
                    owned = seg;
                    const struct section_64 *sections = (const struct section_64 *)(seg + 1);
                    for (uint32_t j = 0; j < seg->nsects; j++) {
                        if (strncmp(sections[j].sectname, "__zndata", 16) == 0) {
                            if (zndata) { localError = @"M4.6.2 verifier：存在多个 __zndata section"; break; }
                            zndata = &sections[j];
                        }
                    }
                    if (localError) break;
                }
            }
            cursor += lc->cmdsize;
        }
        if (localError) break;
        if (ownedCount != 1 || !owned || !zndata) { localError = @"M4.6.2 verifier：必须且只能存在一个 __ZNDATA/__zndata"; break; }
        if ((owned->initprot & VM_PROT_EXECUTE) != 0 || (owned->initprot & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) {
            localError = @"M4.6.2 verifier：__ZNDATA protection 必须为 RW 且不可执行";
            break;
        }
        if (owned->fileoff > size || owned->filesize > size - owned->fileoff) { localError = @"M4.6.2 verifier：__ZNDATA file range 越界"; break; }
        if (zndata->offset < owned->fileoff || zndata->offset > owned->fileoff + owned->filesize) { localError = @"M4.6.2 verifier：__zndata 不在 owned segment 内"; break; }
        if (zndata->offset > size || zndata->size > size - zndata->offset) { localError = @"M4.6.2 verifier：__zndata range 越界"; break; }
        if ((uint64_t)zndata->offset + zndata->size > owned->fileoff + owned->filesize) { localError = @"M4.6.2 verifier：__zndata 超过 __ZNDATA 容量"; break; }

        const ZN44StaticHeader *staticHeader = (const ZN44StaticHeader *)(base + zndata->offset);
        if (staticHeader->magic0 != ZN44_STATIC_MAGIC0 || staticHeader->magic1 != ZN44_STATIC_MAGIC1 ||
            staticHeader->version != ZN44_STATIC_VERSION_V3 || staticHeader->entrySize != sizeof(ZN44StaticEntry) ||
            staticHeader->count != 0 ||
            (staticHeader->flags & ZN44_STATIC_HEADER_FLAG_GENERATED_LAYOUT_V1) == 0) {
            localError = @"M6.8.4 verifier：runtime-only Generated Data Layout V1 Static Header 契约无效";
            break;
        }
        uint64_t actionRelative = 0;
        if (!ZNGeneratedDataLayoutV1LocateRuntimeAction(base + zndata->offset, zndata->size, &actionRelative) ||
            actionRelative > zndata->size || zndata->size - actionRelative < sizeof(ZNRuntimeActionHeader)) {
            localError = @"M6.8.4 verifier：Generated Data Layout V1 Runtime Action table 缺失/越界";
            break;
        }

        const uint8_t *table = base + zndata->offset + actionRelative;
        const ZNRuntimeActionHeader *header = (const ZNRuntimeActionHeader *)table;
        if (header->magic != ZN_RUNTIME_ACTION_MAGIC || header->version != ZN_RUNTIME_ACTION_VERSION ||
            header->entrySize != sizeof(ZNRuntimeMethodCallEntry) || header->count > ZN_RUNTIME_ACTION_MAX_ENTRIES) {
            localError = @"M4.6.2 verifier：Runtime Action Header 无效";
            break;
        }
        if (header->count != expectedActionCount) {
            localError = [NSString stringWithFormat:@"M4.6.2 verifier：action count 不一致 table=%u model=%lu",
                          header->count, (unsigned long)expectedActionCount];
            break;
        }
        uint64_t entryBytes = (uint64_t)header->count * header->entrySize;
        uint64_t fixedEnd = sizeof(*header) + entryBytes;
        if (fixedEnd > header->totalSize || header->stringPoolOffset < fixedEnd ||
            header->stringPoolOffset > header->totalSize ||
            header->stringPoolSize > header->totalSize - header->stringPoolOffset) {
            localError = @"M4.6.2 verifier：Runtime Action table/string pool range 无效";
            break;
        }
        if (actionRelative + header->totalSize > zndata->size) {
            localError = @"M4.6.2 verifier：Runtime Action table 超过 __zndata section size";
            break;
        }

        const ZNRuntimeMethodCallEntry *entries = (const ZNRuntimeMethodCallEntry *)(table + sizeof(*header));
        for (uint32_t i = 0; i < header->count; i++) {
            const ZNRuntimeMethodCallEntry *entry = &entries[i];
            BOOL methodLike=(entry->kind==ZNRuntimeActionKindIL2CPPMethodCall ||
                             entry->kind==ZNRuntimeActionKindDirectNativeCall);
            BOOL nativeHook=(entry->kind==ZNRuntimeActionKindIL2CPPNativeHook);
            if (entry->argumentCount > ZN_RUNTIME_ACTION_MAX_ARGUMENTS || (!methodLike && !nativeHook)) {
                localError = [NSString stringWithFormat:@"M6.13 verifier：entry %u kind/argc 无效 kind=%u argc=%u",
                              i,entry->kind,entry->argumentCount];
                break;
            }
            uint32_t required[] = {entry->titleOffset, entry->groupOffset, entry->assemblyOffset,
                                   entry->namespaceOffset, entry->classOffset, entry->methodOffset};
            for (NSUInteger si = 0; si < sizeof(required) / sizeof(required[0]); si++) {
                if (!ZNM462StringOffsetValid(table, header, required[si])) {
                    localError = [NSString stringWithFormat:@"M6.4 verifier：entry %u string offset 无效", i];
                    break;
                }
            }
            if (localError) break;

            if ((entry->flags & ZNRuntimeActionFlagParameterSignature) == 0 ||
                !ZNM462StringOffsetValid(table, header, entry->reserved[1])) {
                localError = [NSString stringWithFormat:@"M6.4 verifier：entry %u 缺少/损坏 Full Signature", i];
                break;
            }

            if (methodLike) {
                if (entry->argumentCount == 1 && (entry->flags & ZNRuntimeActionFlagArgument0Text) != 0 &&
                    !ZNM462StringOffsetValid(table, header, entry->reserved[0])) {
                    localError = [NSString stringWithFormat:@"M6.4 verifier：entry %u argument0 string 无效", i];
                    break;
                }
                if (!ZNM462ArgumentVectorValid(table, header, entry)) {
                    localError = [NSString stringWithFormat:@"M6.4 verifier：entry %u 参数向量缺失/损坏", i];
                    break;
                }
            } else {
                if (!ZNM462NativeHookConfigValid(table, header, entry)) {
                    localError = [NSString stringWithFormat:@"M6.4 verifier：entry %u Native Hook config 无效", i];
                    break;
                }
            }
        }
        if (localError) break;
        ok = YES;
    } while (0);

    munmap((void *)base, size);
    close(fd);
    if (!ok && error) *error = localError ?: @"M4.7 runtime-only verifier 失败";
    return ok;
}

static BOOL ZNM462LooksLikeMachOPath(NSString *path) {
    if (!path.length || [path.lastPathComponent isEqualToString:@"build_report.json"]) return NO;
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return NO;
    uint32_t magic = 0;
    ssize_t n = read(fd, &magic, sizeof(magic));
    close(fd);
    return n == sizeof(magic) && magic == MH_MAGIC_64;
}

BOOL ZNM462VerifyRuntimeOnlyOutputs(NSArray<NSString *> *outputs,
                                    NSUInteger expectedActionCount,
                                    NSString **report,
                                    NSString **error) {
    NSUInteger verified = 0;
    for (NSString *path in outputs ?: @[]) {
        // Runtime-only Builder has intentionally been suffixless since M5.1.
        // Verify actual Mach-O outputs by content, not by the historical
        // `.znpatched` staging suffix.
        if (!ZNM462LooksLikeMachOPath(path)) continue;
        NSString *localError = nil;
        if (!ZNM462VerifyPath(path, expectedActionCount, &localError)) {
            if (error) *error = [NSString stringWithFormat:@"%@：%@", path.lastPathComponent, localError ?: @"verify failed"];
            return NO;
        }
        verified++;
    }
    if (!verified) {
        if (error) *error = @"M5.7 verifier：没有找到 Runtime-only Mach-O 输出";
        return NO;
    }
    if (report) {
        *report = [NSString stringWithFormat:@"M6.4 Runtime-only Verify：%lu 个 suffixless Mach-O · %lu Runtime/Hook Actions · Static count=0 · Full Signature + action config + section bounds/RW protection 全部通过",
                   (unsigned long)verified, (unsigned long)expectedActionCount];
    }
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m6.4-runtime-only-verify] targets=%lu actions=%lu suffixless=YES PASS",
                                         (unsigned long)verified,
                                         (unsigned long)expectedActionCount]];
    return YES;
}
