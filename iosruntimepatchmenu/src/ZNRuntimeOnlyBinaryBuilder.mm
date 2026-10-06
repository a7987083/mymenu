#import "ZNRuntimeOnlyBinaryBuilder.h"
#import "ZNBinaryPatchWorkspace.h"
#import "ZNStaticPatchFormat.h"
#import "ZNGeneratedDataLayout.h"
#import "ZNAdhocMachOSigner.h"
#import "ZNPatchCore.h"

#import <mach-o/loader.h>
#import <mach/machine.h>
#import <mach/vm_prot.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>

static const uint64_t kZNRBPage = 0x4000ULL;
static const uint64_t kZNRBDataSegmentSize = 0x10000ULL;

struct ZNRBOwnedDataCommand { struct segment_command_64 segment; struct section_64 section; };
static_assert(sizeof(ZNRBOwnedDataCommand) == sizeof(struct segment_command_64) + sizeof(struct section_64), "runtime-only owned segment ABI");

struct ZNRBLayout { uint64_t imageVMBase; uint64_t firstFileSectionOffset; uint64_t oldCommandEnd; uint64_t linkeditCommandOffset; uint64_t linkeditVMAddr; uint64_t linkeditFileOffset; uint64_t linkeditFileSize; };

static BOOL ZNRBShiftU32(uint32_t *field, uint64_t threshold, uint64_t delta, NSString **error) {
    if (!field || !*field || (uint64_t)*field < threshold) return YES;
    uint64_t value = (uint64_t)*field + delta;
    if (value > UINT32_MAX) { if (error) *error = @"Runtime-only Builder：__LINKEDIT offset 超过 32-bit 字段范围"; return NO; }
    *field = (uint32_t)value; return YES;
}

static BOOL ZNRBParse(uint8_t *base, size_t size, ZNRBLayout *layout, NSString **error) {
    if (!base || size < sizeof(struct mach_header_64) || !layout) { if (error) *error = @"Runtime-only Builder：Mach-O 太小"; return NO; }
    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    if (mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) { if (error) *error = @"Runtime-only Builder：仅支持 thin arm64 Mach-O"; return NO; }
    uint64_t commandEnd = sizeof(*mh) + (uint64_t)mh->sizeofcmds;
    if (commandEnd > size) { if (error) *error = @"Runtime-only Builder：load commands 越界"; return NO; }
    memset(layout, 0, sizeof(*layout)); layout->imageVMBase = UINT64_MAX; layout->firstFileSectionOffset = UINT64_MAX; layout->oldCommandEnd = commandEnd; layout->linkeditCommandOffset = UINT64_MAX;
    uint8_t *cursor = base + sizeof(*mh); uint8_t *limit = base + commandEnd;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > limit) { if (error) *error = @"Runtime-only Builder：load command 损坏"; return NO; }
        struct load_command *lc = (struct load_command *)cursor;
        if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > limit) { if (error) *error = @"Runtime-only Builder：load command size 损坏"; return NO; }
        if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cursor;
            if (seg->fileoff > size || seg->filesize > size - seg->fileoff) { if (error) *error = @"Runtime-only Builder：segment file range 越界"; return NO; }
            if (strncmp(seg->segname, SEG_TEXT, 16) == 0) layout->imageVMBase = seg->vmaddr;
            if (strncmp(seg->segname, SEG_LINKEDIT, 16) == 0) { layout->linkeditCommandOffset = (uint64_t)(cursor - base); layout->linkeditVMAddr = seg->vmaddr; layout->linkeditFileOffset = seg->fileoff; layout->linkeditFileSize = seg->filesize; }
            uint64_t sectionBytes = (uint64_t)seg->nsects * sizeof(struct section_64);
            if (lc->cmdsize < sizeof(*seg) + sectionBytes) { if (error) *error = @"Runtime-only Builder：section table 越界"; return NO; }
            struct section_64 *sections = (struct section_64 *)(seg + 1);
            for (uint32_t j = 0; j < seg->nsects; j++) {
                uint32_t type = sections[j].flags & SECTION_TYPE;
                BOOL zero = type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL;
                if (!zero && sections[j].size && sections[j].offset) layout->firstFileSectionOffset = MIN(layout->firstFileSectionOffset, (uint64_t)sections[j].offset);
            }
        }
        cursor += lc->cmdsize;
    }
    if (layout->imageVMBase == UINT64_MAX || layout->linkeditCommandOffset == UINT64_MAX || !layout->linkeditFileOffset || !layout->linkeditFileSize || layout->firstFileSectionOffset == UINT64_MAX) { if (error) *error = @"Runtime-only Builder：缺少 __TEXT/__LINKEDIT 或 header layout"; return NO; }
    if (layout->linkeditFileOffset + layout->linkeditFileSize > size) { if (error) *error = @"Runtime-only Builder：__LINKEDIT 超出文件"; return NO; }
    return YES;
}

static BOOL ZNRBShiftLinkeditReferences(uint8_t *base, size_t size, uint64_t oldLinkeditFileOffset, uint64_t delta, NSString **error) {
    struct mach_header_64 *mh = (struct mach_header_64 *)base; uint8_t *cursor = base + sizeof(*mh); uint8_t *limit = cursor + mh->sizeofcmds;
    if (limit > base + size) { if (error) *error = @"Runtime-only Builder：扩展后 load commands 越界"; return NO; }
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (cursor + sizeof(struct load_command) > limit) return NO; struct load_command *lc = (struct load_command *)cursor; if (lc->cmdsize < sizeof(*lc) || cursor + lc->cmdsize > limit) return NO;
        switch (lc->cmd) {
            case LC_SEGMENT_64: { struct segment_command_64 *seg = (struct segment_command_64 *)cursor; if (strncmp(seg->segname, SEG_LINKEDIT, 16) == 0) { seg->fileoff += delta; seg->vmaddr += delta; } break; }
            case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY: { struct dyld_info_command *d=(struct dyld_info_command *)cursor; if(!ZNRBShiftU32(&d->rebase_off,oldLinkeditFileOffset,delta,error)||!ZNRBShiftU32(&d->bind_off,oldLinkeditFileOffset,delta,error)||!ZNRBShiftU32(&d->weak_bind_off,oldLinkeditFileOffset,delta,error)||!ZNRBShiftU32(&d->lazy_bind_off,oldLinkeditFileOffset,delta,error)||!ZNRBShiftU32(&d->export_off,oldLinkeditFileOffset,delta,error)) return NO; break; }
            case LC_SYMTAB: { struct symtab_command *s=(struct symtab_command *)cursor; if(!ZNRBShiftU32(&s->symoff,oldLinkeditFileOffset,delta,error)||!ZNRBShiftU32(&s->stroff,oldLinkeditFileOffset,delta,error)) return NO; break; }
            case LC_DYSYMTAB: { struct dysymtab_command *d=(struct dysymtab_command *)cursor; if(!ZNRBShiftU32(&d->tocoff,oldLinkeditFileOffset,delta,error)||!ZNRBShiftU32(&d->modtaboff,oldLinkeditFileOffset,delta,error)||!ZNRBShiftU32(&d->extrefsymoff,oldLinkeditFileOffset,delta,error)||!ZNRBShiftU32(&d->indirectsymoff,oldLinkeditFileOffset,delta,error)||!ZNRBShiftU32(&d->extreloff,oldLinkeditFileOffset,delta,error)||!ZNRBShiftU32(&d->locreloff,oldLinkeditFileOffset,delta,error)) return NO; break; }
            case LC_TWOLEVEL_HINTS: { struct twolevel_hints_command *h=(struct twolevel_hints_command *)cursor; if(!ZNRBShiftU32(&h->offset,oldLinkeditFileOffset,delta,error)) return NO; break; }
            case LC_CODE_SIGNATURE: case LC_SEGMENT_SPLIT_INFO: case LC_FUNCTION_STARTS: case LC_DATA_IN_CODE:
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
            { struct linkedit_data_command *d=(struct linkedit_data_command *)cursor; if(!ZNRBShiftU32(&d->dataoff,oldLinkeditFileOffset,delta,error)) return NO; break; }
#ifdef LC_NOTE
            case LC_NOTE: { struct note_command *n=(struct note_command *)cursor; if(n->offset&&n->offset>=oldLinkeditFileOffset)n->offset+=delta; break; }
#endif
            default: break;
        }
        cursor += lc->cmdsize;
    }
    return YES;
}

static BOOL ZNRBBuildTarget(NSString *target, NSString *folder, NSString **outPath, NSDictionary **metadata, NSString **error) {
    NSDictionary *module = [[ZNModuleManager sharedManager] moduleNamed:target];
    if (!module) { if (error) *error = [NSString stringWithFormat:@"Runtime-only Builder：目标模块未加载：%@", target ?: @""]; return NO; }
    NSString *inputPath = [module[@"path"] isKindOfClass:NSString.class] ? module[@"path"] : @"";
    if (!inputPath.length) { if (error) *error = @"Runtime-only Builder：无法取得目标 Mach-O 路径"; return NO; }
    NSString *name = inputPath.lastPathComponent.length ? inputPath.lastPathComponent : target;
    // M5.1: generated binary keeps the original Mach-O filename. No .znpatched suffix.
    NSString *outputPath = [folder stringByAppendingPathComponent:name];
    NSFileManager *fm = NSFileManager.defaultManager; [fm removeItemAtPath:outputPath error:nil]; NSError *copyError = nil;
    if (![fm copyItemAtPath:inputPath toPath:outputPath error:&copyError]) { if (error) *error = [NSString stringWithFormat:@"Runtime-only Builder：复制目标失败：%@", copyError.localizedDescription ?: @"未知错误"]; return NO; }
    int fd = open(outputPath.fileSystemRepresentation, O_RDWR); if (fd < 0) { [fm removeItemAtPath:outputPath error:nil]; if (error) *error = @"Runtime-only Builder：打开输出失败"; return NO; }
    struct stat st = {}; if (fstat(fd, &st) != 0 || st.st_size <= 0) { close(fd); [fm removeItemAtPath:outputPath error:nil]; if (error) *error = @"Runtime-only Builder：输出大小无效"; return NO; }
    uint64_t oldSize=(uint64_t)st.st_size; uint8_t *oldBase=(uint8_t *)mmap(NULL,(size_t)oldSize,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0); if(oldBase==MAP_FAILED){close(fd);[fm removeItemAtPath:outputPath error:nil];if(error)*error=@"Runtime-only Builder：mmap 原始输出失败";return NO;}
    ZNRBLayout layout={}; NSString *localError=nil; BOOL parsed=ZNRBParse(oldBase,(size_t)oldSize,&layout,&localError); munmap(oldBase,(size_t)oldSize); if(!parsed){close(fd);[fm removeItemAtPath:outputPath error:nil];if(error)*error=localError;return NO;}
    const uint64_t extraCommands=sizeof(ZNRBOwnedDataCommand); if(layout.oldCommandEnd+extraCommands>layout.firstFileSectionOffset){close(fd);[fm removeItemAtPath:outputPath error:nil];if(error)*error=@"Runtime-only Builder：Mach-O header slack 不足以加入 __ZNDATA";return NO;} if(layout.linkeditFileOffset>UINT32_MAX){close(fd);[fm removeItemAtPath:outputPath error:nil];if(error)*error=@"Runtime-only Builder：__ZNDATA section.offset 超过 32-bit";return NO;}
    uint64_t inserted=kZNRBDataSegmentSize,newSize=oldSize+inserted; if(newSize>SIZE_MAX||ftruncate(fd,(off_t)newSize)!=0){close(fd);[fm removeItemAtPath:outputPath error:nil];if(error)*error=@"Runtime-only Builder：扩展输出文件失败";return NO;} uint8_t *base=(uint8_t *)mmap(NULL,(size_t)newSize,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(base==MAP_FAILED){close(fd);[fm removeItemAtPath:outputPath error:nil];if(error)*error=@"Runtime-only Builder：mmap 扩展输出失败";return NO;}
    BOOL ok=NO;do{memmove(base+layout.linkeditFileOffset+inserted,base+layout.linkeditFileOffset,oldSize-layout.linkeditFileOffset);memset(base+layout.linkeditFileOffset,0,inserted);memmove(base+layout.linkeditCommandOffset+extraCommands,base+layout.linkeditCommandOffset,layout.oldCommandEnd-layout.linkeditCommandOffset);memset(base+layout.linkeditCommandOffset,0,extraCommands);struct mach_header_64 *mh=(struct mach_header_64 *)base;uint64_t newSizeOfCmds=(uint64_t)mh->sizeofcmds+extraCommands;if(newSizeOfCmds>UINT32_MAX){localError=@"Runtime-only Builder：sizeofcmds 溢出";break;}mh->ncmds+=1;mh->sizeofcmds=(uint32_t)newSizeOfCmds;ZNRBOwnedDataCommand command={};command.segment.cmd=LC_SEGMENT_64;command.segment.cmdsize=sizeof(command);strncpy(command.segment.segname,"__ZNDATA",16);command.segment.vmaddr=layout.linkeditVMAddr;command.segment.vmsize=inserted;command.segment.fileoff=layout.linkeditFileOffset;command.segment.filesize=inserted;command.segment.maxprot=VM_PROT_READ|VM_PROT_WRITE;command.segment.initprot=VM_PROT_READ|VM_PROT_WRITE;command.segment.nsects=1;strncpy(command.section.sectname,"__zndata",16);strncpy(command.section.segname,"__ZNDATA",16);command.section.addr=layout.linkeditVMAddr;command.section.size=ZNGeneratedDataAlign8(sizeof(ZN44StaticHeader)+sizeof(ZN44FeatureDescriptionHeader));command.section.offset=(uint32_t)layout.linkeditFileOffset;command.section.align=3;command.section.flags=S_REGULAR;memcpy(base+layout.linkeditCommandOffset,&command,sizeof(command));if(!ZNRBShiftLinkeditReferences(base,(size_t)newSize,layout.linkeditFileOffset,inserted,&localError))break;ZN44StaticHeader *header=(ZN44StaticHeader *)(base+layout.linkeditFileOffset);memset(header,0,sizeof(*header));header->magic0=ZN44_STATIC_MAGIC0;header->magic1=ZN44_STATIC_MAGIC1;header->version=ZN44_STATIC_VERSION_V3;header->count=0;header->entrySize=sizeof(ZN44StaticEntry);header->flags|=ZN44_STATIC_HEADER_FLAG_GENERATED_LAYOUT_V1;ZN44FeatureDescriptionHeader *desc=(ZN44FeatureDescriptionHeader *)((uint8_t *)header+ZNGeneratedDataAlign8(sizeof(ZN44StaticHeader)));memset(desc,0,sizeof(*desc));desc->magic0=ZN44_FEATURE_DESC_MAGIC0;desc->magic1=ZN44_FEATURE_DESC_MAGIC1;desc->count=0;desc->entrySize=sizeof(ZN44FeatureDescriptionEntry);if(msync(base,(size_t)newSize,MS_SYNC)!=0){localError=[NSString stringWithFormat:@"Runtime-only Builder：msync 失败 errno=%d",errno];break;}ok=YES;}while(0);
    munmap(base,(size_t)newSize);close(fd);if(!ok){[fm removeItemAtPath:outputPath error:nil];if(error)*error=localError?:@"Runtime-only Builder 生成失败";return NO;}if(outPath)*outPath=outputPath;if(metadata)*metadata=@{@"target":target?:@"",@"input":inputPath,@"output":outputPath,@"builder":@"Runtime-only Builder M5.1",@"staticPatchCount":@0,@"ownedDataBytes":@(inserted),@"needsResign":@YES,@"keepsOriginalFilename":@YES};return YES;
}

BOOL ZNRuntimeOnlyBinaryBuilderBuildWorkspace(ZNBinaryPatchWorkspace *workspace, NSArray<NSString *> **outputs, NSString **report, NSString **error) {
    if (!workspace) { if (error) *error = @"Runtime-only Builder：workspace 为空"; return NO; }
    NSString *target = [[ZNModuleManager sharedManager] moduleNamed:@"UnityFramework"] ? @"UnityFramework" : workspace.defaultTarget; if (!target.length) target = @"UnityFramework";
    NSString *root=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/ZonoePatchOutput"];NSDateFormatter *formatter=[NSDateFormatter new];formatter.dateFormat=@"yyyyMMdd-HHmmss";NSString *folder=[root stringByAppendingPathComponent:[[formatter stringFromDate:[NSDate date]] stringByAppendingString:@"-runtime"]];NSError *directoryError=nil;if(![NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&directoryError]){if(error)*error=directoryError.localizedDescription?:@"Runtime-only Builder：创建目录失败";return NO;}
    NSString *path=nil;NSDictionary *metadata=nil;NSString *buildError=nil;if(!ZNRBBuildTarget(target,folder,&path,&metadata,&buildError)){[NSFileManager.defaultManager removeItemAtPath:folder error:nil];if(error)*error=buildError?:@"Runtime-only Builder：生成目标失败";return NO;}
    NSMutableArray<NSString *> *paths=[NSMutableArray arrayWithObject:path];NSDictionary *reportObject=@{@"format":@"com.zonoe.runtime-only-builder/v1",@"generatedAt":[[NSDate date]description],@"runtimeOnly":@YES,@"staticPatchCount":@0,@"target":metadata?:@{},@"notes":@[@"No Static Patch row is required",@"__ZNDATA/__zndata contains an empty Static Dispatch header followed by Runtime Method Call records",@"No executable site is modified by the runtime-only builder",@"Generated Mach-O keeps the original binary filename without .znpatched suffix"]};NSData *json=[NSJSONSerialization dataWithJSONObject:reportObject options:NSJSONWritingPrettyPrinted error:nil];NSString *reportPath=[folder stringByAppendingPathComponent:@"build_report.json"];if(json)[json writeToFile:reportPath atomically:YES];[paths addObject:reportPath];if(outputs)*outputs=paths;if(report)*report=[NSString stringWithFormat:@"Runtime-only Builder：已创建 %@ · 0 Static Patch · 输出：%@",target,folder];[[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[m5.1-runtime-only-build] target=%@ output=%@ suffixless=YES",target,path.lastPathComponent]];return YES;
}

BOOL ZNRuntimeOnlyPostProcessGeneratedOutputsM461(NSArray<NSString *> *innerOutputs, NSString *innerReport, NSArray<NSString *> **outputs, NSString **report, NSString **error) {
    NSMutableArray<NSDictionary *> *signing=[NSMutableArray array];NSUInteger targets=0;NSString *failure=nil;
    for(NSString *path in innerOutputs?:@[]){if([path.lastPathComponent isEqualToString:@"build_report.json"])continue;targets++;NSDictionary *metadata=nil;NSString *signError=nil;if(!ZNAdhocResignMachOAtPath(path,&metadata,&signError)){failure=signError?:@"Runtime-only Builder：ad-hoc CodeDirectory 重建失败";break;}NSMutableDictionary *item=[metadata mutableCopy]?:[NSMutableDictionary dictionary];item[@"output"]=path;[signing addObject:item];}
    if(!failure&&!targets)failure=@"Runtime-only Builder：没有可签名的二进制输出";if(failure){if(error)*error=failure;return NO;}
    for(NSString *path in innerOutputs?:@[]){if(![path.lastPathComponent isEqualToString:@"build_report.json"])continue;NSData *data=[NSData dataWithContentsOfFile:path];NSMutableDictionary *object=data.length?[[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] mutableCopy]:nil;if(![object isKindOfClass:NSMutableDictionary.class])continue;object[@"generatedBinaryPipeline"]=@{@"mode":@"runtime-only-m5.1",@"staticPatchStagesSkipped":@YES,@"runtimeActionEmbedded":@YES,@"fullSignatureAugmented":@YES,@"suffixlessBinaryName":@YES};object[@"generatedBinarySignature"]=@{@"mode":@"zonoe-self-contained-adhoc",@"rebuiltBeforeExport":@YES,@"outputs":signing,@"finalPackageResignRequired":@YES};NSData *updated=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];if(updated)[updated writeToFile:path atomically:YES];break;}
    if(outputs)*outputs=innerOutputs;if(report)*report=[NSString stringWithFormat:@"%@\nM5.1 Runtime-only：Runtime Method Call + Full Signature + 参数控件/Immediate Chain；生成二进制保持原始文件名，无 .znpatched 后缀，并重建 ad-hoc CodeDirectory。",innerReport?:@"Runtime-only 生成成功"];return YES;
}
