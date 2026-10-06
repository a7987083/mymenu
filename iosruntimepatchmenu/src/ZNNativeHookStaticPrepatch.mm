#import "ZNNativeHookStaticPrepatch.h"

#import "ZNNativeHookAction.h"
#import "ZNAdhocMachOSigner.h"

#import <mach-o/loader.h>
#import <mach/machine.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <uuid/uuid.h>
#import <mach/vm_prot.h>

#include <algorithm>
#include <vector>

typedef struct {
    uint64_t fileStart;
    uint64_t fileEnd;
    uint64_t vmStart;
} ZNM610Gap;

typedef struct {
    uint64_t fileoff;
    uint64_t filesize;
    uint64_t vmaddr;
    uint64_t vmsize;
    vm_prot_t initprot;
    char name[17];
} ZNM610Segment;

static uint64_t ZNM610AlignUp(uint64_t value,uint64_t alignment){
    if(!alignment)return value;
    uint64_t mask=alignment-1;
    return (value+mask)&~mask;
}

static BOOL ZNM610RangeZero(const uint8_t *base,uint64_t fileSize,uint64_t start,uint64_t length){
    if(!base||start>fileSize||length>fileSize-start)return NO;
    for(uint64_t i=0;i<length;i++)if(base[start+i]!=0)return NO;
    return YES;
}

static BOOL ZNM610BranchImm26(uint64_t fromVM,uint64_t toVM,uint32_t *outInsn){
    int64_t delta=(int64_t)toVM-(int64_t)fromVM;
    if((delta&3LL)!=0)return NO;
    int64_t imm=delta>>2;
    if(imm<-(1LL<<25)||imm>((1LL<<25)-1))return NO;
    if(outInsn)*outInsn=UINT32_C(0x14000000)|((uint32_t)imm&UINT32_C(0x03FFFFFF));
    return YES;
}

static BOOL ZNM610ADRP(uint64_t fromVM,uint64_t toVM,uint32_t rd,uint32_t *outInsn){
    int64_t fromPage=(int64_t)(fromVM&~UINT64_C(0xFFF));
    int64_t toPage=(int64_t)(toVM&~UINT64_C(0xFFF));
    int64_t delta=(toPage-fromPage)>>12;
    if(delta<-(1LL<<20)||delta>((1LL<<20)-1))return NO;
    uint64_t imm=(uint64_t)delta&UINT64_C(0x1FFFFF);
    uint32_t immlo=(uint32_t)(imm&3ULL);
    uint32_t immhi=(uint32_t)((imm>>2)&UINT64_C(0x7FFFF));
    if(outInsn)*outInsn=UINT32_C(0x90000000)|(immlo<<29)|(immhi<<5)|(rd&31u);
    return YES;
}

static uint32_t ZNM610LDRXUnsigned(uint32_t rt,uint32_t rn,uint32_t byteOffset){
    uint32_t imm12=(byteOffset>>3)&0xFFFu;
    return UINT32_C(0xF9400000)|(imm12<<10)|((rn&31u)<<5)|(rt&31u);
}

static uint32_t ZNM610CBZX(uint32_t rt,int32_t byteDelta){
    int32_t imm19=byteDelta>>2;
    return UINT32_C(0xB4000000)|(((uint32_t)imm19&UINT32_C(0x7FFFF))<<5)|(rt&31u);
}

static BOOL ZNM610RelocationSafeFirstInstruction(uint32_t insn,NSString **reason){
    // V1 deliberately rejects all common PC-relative and branch encodings.
    if((insn&UINT32_C(0x7C000000))==UINT32_C(0x14000000)){
        if(reason)*reason=@"首指令是 B/BL，V1 不搬移分支";
        return NO;
    }
    if((insn&UINT32_C(0xFF000010))==UINT32_C(0x54000000)){
        if(reason)*reason=@"首指令是 B.cond，V1 不搬移条件分支";
        return NO;
    }
    if((insn&UINT32_C(0x7E000000))==UINT32_C(0x34000000)){
        if(reason)*reason=@"首指令是 CBZ/CBNZ，V1 不搬移 compare-branch";
        return NO;
    }
    if((insn&UINT32_C(0x7E000000))==UINT32_C(0x36000000)){
        if(reason)*reason=@"首指令是 TBZ/TBNZ，V1 不搬移 test-branch";
        return NO;
    }
    if((insn&UINT32_C(0x1F000000))==UINT32_C(0x10000000)){
        if(reason)*reason=@"首指令是 ADR/ADRP，V1 不搬移 PC-relative address";
        return NO;
    }
    if((insn&UINT32_C(0x3B000000))==UINT32_C(0x18000000)){
        if(reason)*reason=@"首指令是 literal load/prefetch，V1 不搬移 PC-relative literal";
        return NO;
    }
    // Replacing an indirect-call BTI landing pad with a plain B would violate
    // branch-target enforcement on arm64e/BTI-enabled binaries.
    if((insn&UINT32_C(0xFFFFFC1F))==UINT32_C(0xD503241F)){
        if(reason)*reason=@"首指令是 BTI landing pad，V1 不覆盖";
        return NO;
    }
    if(insn==0||insn==UINT32_MAX){
        if(reason)*reason=@"首指令无效";
        return NO;
    }
    return YES;
}

static NSString *ZNM610UUIDForHeader(const struct mach_header_64 *mh){
    if(!mh||mh->magic!=MH_MAGIC_64)return @"";
    const uint8_t *cursor=(const uint8_t *)(mh+1),*limit=cursor+mh->sizeofcmds;
    for(uint32_t i=0;i<mh->ncmds;i++){
        if(cursor+sizeof(struct load_command)>limit)return @"";
        const struct load_command *lc=(const struct load_command *)cursor;
        if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit)return @"";
        if(lc->cmd==LC_UUID&&lc->cmdsize>=sizeof(struct uuid_command)){
            const struct uuid_command *uc=(const struct uuid_command *)cursor;
            uuid_t bytes={0}; memcpy(bytes,uc->uuid,sizeof(bytes));
            NSUUID *uuid=[[NSUUID alloc]initWithUUIDBytes:bytes];
            return uuid.UUIDString.uppercaseString?:@"";
        }
        cursor+=lc->cmdsize;
    }
    return @"";
}

static BOOL ZNM610CollectLayout(const uint8_t *base,
                                uint64_t fileSize,
                                uint64_t *outTextVM,
                                std::vector<ZNM610Segment> &segments,
                                std::vector<ZNM610Gap> &execGaps,
                                std::vector<ZNM610Gap> &writeGaps,
                                NSString **error){
    if(fileSize<sizeof(struct mach_header_64)){if(error)*error=@"UnityFramework 文件过小";return NO;}
    const struct mach_header_64 *mh=(const struct mach_header_64 *)base;
    if(mh->magic!=MH_MAGIC_64||mh->cputype!=CPU_TYPE_ARM64){
        if(error)*error=@"Static Prepared V1 仅支持 arm64 Mach-O";
        return NO;
    }
    const uint8_t *cursor=(const uint8_t *)(mh+1),*limit=base+fileSize;
    if((uint64_t)(cursor-base)+mh->sizeofcmds>fileSize){if(error)*error=@"Mach-O load commands 越界";return NO;}
    limit=cursor+mh->sizeofcmds;
    uint64_t textVM=UINT64_MAX;

    for(uint32_t i=0;i<mh->ncmds;i++){
        if(cursor+sizeof(struct load_command)>limit){if(error)*error=@"Mach-O load command 截断";return NO;}
        const struct load_command *lc=(const struct load_command *)cursor;
        if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit){if(error)*error=@"Mach-O load command 大小异常";return NO;}
        if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(struct segment_command_64)){
            const struct segment_command_64 *seg=(const struct segment_command_64 *)cursor;
            if(seg->fileoff>fileSize||seg->filesize>fileSize-seg->fileoff){if(error)*error=@"Mach-O segment 文件范围越界";return NO;}
            ZNM610Segment s={};
            s.fileoff=seg->fileoff;s.filesize=seg->filesize;s.vmaddr=seg->vmaddr;s.vmsize=seg->vmsize;s.initprot=seg->initprot;
            memcpy(s.name,seg->segname,16);s.name[16]=0;
            segments.push_back(s);
            if(strncmp(seg->segname,SEG_TEXT,16)==0)textVM=seg->vmaddr;

            BOOL executable=(seg->initprot&VM_PROT_EXECUTE)!=0;
            BOOL writable=(seg->initprot&VM_PROT_WRITE)!=0;
            if((executable||writable)&&seg->filesize){
                std::vector<std::pair<uint64_t,uint64_t>> used;
                const struct section_64 *sections=(const struct section_64 *)(seg+1);
                uint64_t sectionBytes=(uint64_t)seg->nsects*sizeof(struct section_64);
                if(sizeof(*seg)+sectionBytes>lc->cmdsize){if(error)*error=@"Mach-O section 表越界";return NO;}
                for(uint32_t j=0;j<seg->nsects;j++){
                    const struct section_64 &sec=sections[j];
                    uint32_t type=sec.flags&SECTION_TYPE;
                    BOOL zeroFill=(type==S_ZEROFILL||type==S_GB_ZEROFILL);
#ifdef S_THREAD_LOCAL_ZEROFILL
                    zeroFill=zeroFill||(type==S_THREAD_LOCAL_ZEROFILL);
#endif
                    if(zeroFill||!sec.size||!sec.offset)continue;
                    uint64_t ss=sec.offset,se=ss+sec.size;
                    uint64_t segEnd=seg->fileoff+seg->filesize;
                    if(ss<seg->fileoff||se>segEnd||se<ss)continue;
                    used.push_back({ss,se});
                }
                std::sort(used.begin(),used.end(),[](auto a,auto b){return a.first<b.first;});
                uint64_t gapStart=seg->fileoff;
                // Never reuse Mach-O headers/load commands in __TEXT.
                if(strncmp(seg->segname,SEG_TEXT,16)==0){
                    uint64_t headerEnd=sizeof(struct mach_header_64)+mh->sizeofcmds;
                    gapStart=MAX(gapStart,headerEnd);
                }
                for(const auto &u:used){
                    if(u.first>gapStart){
                        uint64_t gs=gapStart,ge=u.first;
                        uint64_t vm=seg->vmaddr+(gs-seg->fileoff);
                        ZNM610Gap g={gs,ge,vm};
                        if(executable)execGaps.push_back(g);
                        if(writable)writeGaps.push_back(g);
                    }
                    gapStart=MAX(gapStart,u.second);
                }
                uint64_t segEnd=seg->fileoff+seg->filesize;
                if(segEnd>gapStart){
                    uint64_t vm=seg->vmaddr+(gapStart-seg->fileoff);
                    ZNM610Gap g={gapStart,segEnd,vm};
                    if(executable)execGaps.push_back(g);
                    if(writable)writeGaps.push_back(g);
                }
            }
        }
        cursor+=lc->cmdsize;
    }
    if(textVM==UINT64_MAX){if(error)*error=@"UnityFramework 缺少 __TEXT";return NO;}
    if(outTextVM)*outTextVM=textVM;
    return YES;
}

static BOOL ZNM610VMToFile(const std::vector<ZNM610Segment> &segments,
                           uint64_t vm,uint64_t length,uint64_t *outFile){
    for(const auto &seg:segments){
        if(!seg.filesize)continue;
        if(vm<seg.vmaddr)continue;
        uint64_t delta=vm-seg.vmaddr;
        if(delta>seg.filesize||length>seg.filesize-delta)continue;
        if(outFile)*outFile=seg.fileoff+delta;
        return YES;
    }
    return NO;
}

static BOOL ZNM610AllocateGap(std::vector<ZNM610Gap> &gaps,
                              uint8_t *base,uint64_t fileSize,
                              uint64_t size,uint64_t alignment,
                              uint64_t nearVM,uint64_t maxDistance,
                              uint64_t *outFile,uint64_t *outVM){
    NSInteger best=-1;
    uint64_t bestDistance=UINT64_MAX,bestFile=0,bestVM=0;
    for(NSUInteger i=0;i<gaps.size();i++){
        ZNM610Gap &g=gaps[i];
        uint64_t start=ZNM610AlignUp(g.fileStart,alignment);
        if(start<g.fileStart||start>g.fileEnd||size>g.fileEnd-start)continue;
        uint64_t vm=g.vmStart+(start-g.fileStart);
        uint64_t distance=(vm>nearVM)?(vm-nearVM):(nearVM-vm);
        if(maxDistance&&distance>maxDistance)continue;
        if(!ZNM610RangeZero(base,fileSize,start,size))continue;
        if(distance<bestDistance){best=(NSInteger)i;bestDistance=distance;bestFile=start;bestVM=vm;}
    }
    if(best<0)return NO;
    ZNM610Gap &g=gaps[(NSUInteger)best];
    uint64_t consumed=(bestFile-g.fileStart)+size;
    g.fileStart+=consumed;
    g.vmStart+=consumed;
    if(outFile)*outFile=bestFile;
    if(outVM)*outVM=bestVM;
    return YES;
}

static NSString *ZNM610FindUnityOutput(NSArray<NSString *> *builderOutputs){
    for(NSString *path in builderOutputs?:@[]){
        NSString *name=path.lastPathComponent.lowercaseString;
        if([name containsString:@"unityframework"]&&
           ![name hasSuffix:@".znpatched"]&&
           [NSFileManager.defaultManager fileExistsAtPath:path])
            return path;
    }
    return nil;
}

BOOL ZNBuildInstallStaticPreparedNativeHooksV1(NSArray<NSString *> *builderOutputs,
                                                NSString **report,
                                                NSString **error){
    ZNNativeHookStore *store=[ZNNativeHookStore sharedStore];
    NSArray<ZNNativeHookAction *> *actions=[store actionsSnapshot];
    if(!actions.count){
        if(report)*report=@"Static Prepared Native Hook：无 action";
        return YES;
    }

    NSString *unity=ZNM610FindUnityOutput(builderOutputs);
    if(!unity.length){if(error)*error=@"Static Prepared Native Hook 找不到生成后的 UnityFramework";return NO;}

    int fd=open(unity.fileSystemRepresentation,O_RDWR);
    if(fd<0){if(error)*error=@"Static Prepared Native Hook 无法打开 UnityFramework";return NO;}
    struct stat st={};
    if(fstat(fd,&st)!=0||st.st_size<=0){close(fd);if(error)*error=@"Static Prepared Native Hook 无法读取 UnityFramework 大小";return NO;}
    uint64_t fileSize=(uint64_t)st.st_size;
    uint8_t *base=(uint8_t *)mmap(NULL,(size_t)fileSize,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(base==MAP_FAILED){close(fd);if(error)*error=@"Static Prepared Native Hook mmap 失败";return NO;}

    BOOL ok=NO;
    NSString *local=nil;
    NSMutableArray<NSDictionary<NSString *,id> *> *descriptors=[NSMutableArray arrayWithCapacity:actions.count];
    do{
        const struct mach_header_64 *mh=(const struct mach_header_64 *)base;
        NSString *uuid=ZNM610UUIDForHeader(mh);
        if(!uuid.length){local=@"Static Prepared Native Hook 无法读取 UnityFramework UUID";break;}

        uint64_t textVM=0;
        std::vector<ZNM610Segment> segments;
        std::vector<ZNM610Gap> execGaps,writeGaps;
        if(!ZNM610CollectLayout(base,fileSize,&textVM,segments,execGaps,writeGaps,&local))break;

        for(NSUInteger i=0;i<actions.count;i++){
            ZNNativeHookAction *action=actions[i];
            if(!action.preparedDescriptor||!action.preparedRVA||!action.preparedUUID.length){
                local=[NSString stringWithFormat:@"%@：缺少 M6.9 Prepared Descriptor",action.canonicalIdentity];
                break;
            }
            if([uuid caseInsensitiveCompare:action.preparedUUID]!=NSOrderedSame){
                local=[NSString stringWithFormat:@"%@：UnityFramework UUID 与 Prepared Descriptor 不一致",action.canonicalIdentity];
                break;
            }

            uint64_t targetVM=textVM+action.preparedRVA,targetFile=0;
            if(targetVM<textVM||!ZNM610VMToFile(segments,targetVM,4,&targetFile)){
                local=[NSString stringWithFormat:@"%@：Prepared RVA 无法映射到 UnityFramework 文件",action.canonicalIdentity];
                break;
            }
            uint32_t displaced=0;memcpy(&displaced,base+targetFile,sizeof(displaced));
            NSString *relocReason=nil;
            if(!ZNM610RelocationSafeFirstInstruction(displaced,&relocReason)){
                local=[NSString stringWithFormat:@"%@：Static Prepared V1 拒绝生成：%@",action.canonicalIdentity,relocReason?:@"首指令不可搬移"];
                break;
            }

            uint64_t caveFile=0,caveVM=0;
            if(!ZNM610AllocateGap(execGaps,base,fileSize,32,16,targetVM,UINT64_C(0x07FFFFFC),&caveFile,&caveVM)){
                local=[NSString stringWithFormat:@"%@：找不到 ±128MB 内至少 32-byte executable code cave",action.canonicalIdentity];
                break;
            }
            uint64_t slotFile=0,slotVM=0;
            if(!ZNM610AllocateGap(writeGaps,base,fileSize,8,8,caveVM,UINT64_C(0xFFFFFFFF),&slotFile,&slotVM)){
                local=[NSString stringWithFormat:@"%@：找不到 writable 8-byte hook slot",action.canonicalIdentity];
                break;
            }

            uint32_t branchToCave=0,branchBack=0,adrp=0;
            if(!ZNM610BranchImm26(targetVM,caveVM,&branchToCave)||
               !ZNM610BranchImm26(caveVM+20,targetVM+4,&branchBack)||
               !ZNM610ADRP(caveVM,slotVM,16,&adrp)){
                local=[NSString stringWithFormat:@"%@：Static Prepared branch/ADRP 超出编码范围",action.canonicalIdentity];
                break;
            }
            uint32_t slotPageOffset=(uint32_t)(slotVM&UINT64_C(0xFFF));
            if((slotPageOffset&7u)!=0){
                local=[NSString stringWithFormat:@"%@：hook slot 未按 8-byte 对齐",action.canonicalIdentity];
                break;
            }

            uint32_t stub[8]={0};
            stub[0]=adrp;
            stub[1]=ZNM610LDRXUnsigned(16,16,slotPageOffset);
            stub[2]=ZNM610CBZX(16,8); // cave+8 -> cave+16 passthrough
            stub[3]=UINT32_C(0xD61F0200); // BR X16
            stub[4]=displaced;
            stub[5]=branchBack;
            stub[6]=UINT32_C(0xD503201F); // NOP
            stub[7]=UINT32_C(0xD503201F); // NOP

            memcpy(base+caveFile,stub,sizeof(stub));
            uint64_t zero=0;memcpy(base+slotFile,&zero,sizeof(zero));
            memcpy(base+targetFile,&branchToCave,sizeof(branchToCave));

            uint64_t caveRVA=caveVM-textVM;
            uint64_t slotRVA=slotVM-textVM;
            uint64_t trampolineRVA=(caveVM+16)-textVM;
            [descriptors addObject:@{
                @"hookSlotRVA":@(slotRVA),
                @"trampolineRVA":@(trampolineRVA),
                @"codeCaveRVA":@(caveRVA),
                @"displacedInstruction":@(displaced),
            }];
        }
        if(local.length||descriptors.count!=actions.count)break;

        if(msync(base,(size_t)fileSize,MS_SYNC)!=0){local=@"Static Prepared Native Hook msync 失败";break;}
        ok=YES;
    }while(0);

    munmap(base,(size_t)fileSize);
    close(fd);
    if(!ok){if(error)*error=local?:@"Static Prepared Native Hook 生成失败";return NO;}

    // Update metadata only after the whole binary instrumentation transaction
    // succeeded, preventing half-written action descriptors.
    for(NSUInteger i=0;i<descriptors.count;i++){
        NSString *updateError=nil;
        if(![store updateStaticPrepatchDescriptor:descriptors[i] atIndex:i error:&updateError]){
            if(error)*error=updateError?:@"Static Prepared descriptor 写回失败";
            return NO;
        }
    }

    NSDictionary *signMeta=nil;NSString *signError=nil;
    if(!ZNAdhocResignMachOAtPath(unity,&signMeta,&signError)){
        if(error)*error=signError?:@"Static Prepared UnityFramework 重签失败";
        return NO;
    }

    if(report)*report=[NSString stringWithFormat:
        @"Static Prepared Native Hook：%lu actions · branch/cave/slot · UnityFramework resigned",
        (unsigned long)actions.count];
    return YES;
}
