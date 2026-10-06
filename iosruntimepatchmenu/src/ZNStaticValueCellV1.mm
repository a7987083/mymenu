#import "ZNStaticValueCellV1.h"
#import "ZNFeatureControlModel.h"
#import "ZNStaticPatchFormat.h"
#import "ZNValueTypeModel.h"

#import <mach-o/loader.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#include <errno.h>
#include <string.h>
#include <vector>

static uint32_t ZNVCRead32(const uint8_t *p) { uint32_t v=0; memcpy(&v,p,4); return v; }
static void ZNVCWrite32(uint8_t *p,uint32_t v) { memcpy(p,&v,4); }
static BOOL ZNVCIsMOVZ(uint32_t i){return (i&0x7F800000u)==0x52800000u;}
static BOOL ZNVCIsMOVK(uint32_t i){return (i&0x7F800000u)==0x72800000u;}
static BOOL ZNVCIsScalarFMOVImm(uint32_t i){return (i&0xFF201FE0u)==0x1E201000u&&(((i>>22)&3u)==0u||((i>>22)&3u)==1u);}
static BOOL ZNVCDecodeBTarget(uint64_t branchRVA,uint32_t insn,uint64_t *targetRVA){
    if((insn&0x7C000000u)!=0x14000000u||(insn&0x80000000u))return NO;
    int64_t imm=(int64_t)(insn&0x03FFFFFFu);if(imm&0x02000000LL)imm|=~0x03FFFFFFLL;
    if(targetRVA)*targetRVA=(uint64_t)((int64_t)branchRVA+(imm<<2));return YES;
}
static uint32_t ZNVCExpandF32(uint8_t imm){uint32_t sign=(imm>>7)&1u,b=(imm>>6)&1u,low=(imm>>4)&3u,frac=imm&15u;uint32_t exp=((b?0u:1u)<<7)|(b?0x7Cu:0u)|low;return(sign<<31)|(exp<<23)|(frac<<19);}
static uint64_t ZNVCExpandF64(uint8_t imm){uint64_t sign=(imm>>7)&1u,b=(imm>>6)&1u,low=(imm>>4)&3u,frac=imm&15u;uint64_t exp=((b?0ULL:1ULL)<<10)|(b?0x3FCULL:0ULL)|low;return(sign<<63)|(exp<<52)|(frac<<48);}

static BOOL ZNVCEncodeLiteral(uint64_t fromRVA,uint64_t toRVA,uint32_t base,uint32_t rt,uint32_t *out){
    int64_t delta=(int64_t)toRVA-(int64_t)fromRVA;
    if((delta&3)||delta<-(1LL<<20)||delta>=(1LL<<20))return NO;
    uint32_t imm19=(uint32_t)((delta>>2)&0x7FFFFu);
    if(out)*out=base|(imm19<<5)|(rt&31u);
    return YES;
}

struct ZNVCLocation { uint64_t rva; uint64_t fileoff; uint32_t insn; };

BOOL ZNStaticValueCellAugmentAtPath(NSString *path,NSUInteger *convertedEntries,NSString **error){
    if(convertedEntries)*convertedEntries=0;
    int fd=open(path.fileSystemRepresentation,O_RDWR);if(fd<0){if(error)*error=[NSString stringWithFormat:@"value-cell 打开失败 errno=%d",errno];return NO;}
    struct stat st={};if(fstat(fd,&st)!=0||st.st_size<(off_t)sizeof(struct mach_header_64)){close(fd);if(error)*error=@"value-cell 文件无效";return NO;}
    size_t size=(size_t)st.st_size;uint8_t *base=(uint8_t *)mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(base==MAP_FAILED){close(fd);if(error)*error=@"value-cell mmap 失败";return NO;}
    BOOL ok=NO;NSString *local=nil;NSUInteger converted=0;
    do{
        struct mach_header_64 *mh=(struct mach_header_64 *)base;if(mh->magic!=MH_MAGIC_64){local=@"value-cell 仅支持 thin arm64 Mach-O";break;}
        uint64_t commandEnd=sizeof(*mh)+(uint64_t)mh->sizeofcmds;if(commandEnd>size){local=@"value-cell load commands 越界";break;}
        uint64_t imageVMBase=UINT64_MAX;struct segment_command_64 *znText=NULL,*znData=NULL;struct section_64 *znDataSec=NULL;
        uint8_t *cursor=base+sizeof(*mh),*limit=base+commandEnd;
        for(uint32_t i=0;i<mh->ncmds;i++){
            if(cursor+sizeof(struct load_command)>limit){local=@"value-cell load command 损坏";break;}
            struct load_command *lc=(struct load_command *)cursor;if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit){local=@"value-cell load command size 损坏";break;}
            if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(struct segment_command_64)){
                struct segment_command_64 *seg=(struct segment_command_64 *)cursor;
                if(strncmp(seg->segname,"__TEXT",16)==0)imageVMBase=seg->vmaddr;
                if(strncmp(seg->segname,"__ZNTEXT",16)==0)znText=seg;
                if(strncmp(seg->segname,"__ZNDATA",16)==0){znData=seg;uint64_t secBytes=(uint64_t)seg->nsects*sizeof(struct section_64);if(lc->cmdsize>=sizeof(*seg)+secBytes){struct section_64 *secs=(struct section_64 *)(seg+1);for(uint32_t j=0;j<seg->nsects;j++)if(strncmp(secs[j].sectname,"__zndata",16)==0){znDataSec=&secs[j];break;}}}
            }
            cursor+=lc->cmdsize;
        }
        if(local)break;if(imageVMBase==UINT64_MAX||!znText||!znData||!znDataSec){local=@"value-cell 缺少 __TEXT/__ZNTEXT/__ZNDATA";break;}
        if(znDataSec->offset>size||znDataSec->size>size-znDataSec->offset){local=@"value-cell __zndata 越界";break;}
        ZN44StaticHeader *header=(ZN44StaticHeader *)(base+znDataSec->offset);
        if(header->magic0!=ZN44_STATIC_MAGIC0||header->magic1!=ZN44_STATIC_MAGIC1||header->entrySize!=sizeof(ZN44StaticEntry)||!header->count||header->count>ZN44_STATIC_MAX_ENTRIES){local=@"value-cell Static Header 无效";break;}
        uint64_t tableBytes=sizeof(ZN44StaticHeader)+(uint64_t)header->count*sizeof(ZN44StaticEntry);if(tableBytes>znDataSec->size){local=@"value-cell Static Entry table 越界";break;}
        uint64_t cellBytes=(uint64_t)header->count*8u;if(cellBytes>znData->filesize){local=@"value-cell __ZNDATA 容量不足";break;}
        uint64_t cellFileBase=znData->fileoff+znData->filesize-cellBytes;
        uint64_t usedEnd=(uint64_t)znDataSec->offset+znDataSec->size;
        if(cellFileBase<usedEnd||cellFileBase+cellBytes>size){local=@"value-cell 与现有 __zndata/Runtime Action 存储冲突";break;}
        memset(base+cellFileBase,0,(size_t)cellBytes);
        uint64_t cellBaseRVA=(znData->vmaddr-imageVMBase)+znData->filesize-cellBytes;
        ZN44StaticEntry *entries=(ZN44StaticEntry *)(header+1);

        auto mapTextRVA=[&](uint64_t rva,uint64_t *fileoff)->bool{
            uint64_t va=imageVMBase+rva;if(va<znText->vmaddr||va+4>znText->vmaddr+znText->filesize)return false;uint64_t off=znText->fileoff+(va-znText->vmaddr);if(off+4>size)return false;if(fileoff)*fileoff=off;return true;
        };

        for(uint32_t e=0;e<header->count;e++){
            ZN44StaticEntry *entry=&entries[e];
            ZNFeatureControlType control=ZNFeatureControlTypeFromFlags(entry->flags);
            if(control!=ZNFeatureControlTypeNumber&&control!=ZNFeatureControlTypeSlider)continue;
            if(entry->flags&ZN44_STATIC_ENTRY_FLAG_OFFSET_HOOK_V1)continue;
            if(!entry->enabledLength||(entry->enabledLength&3u)){local=[NSString stringWithFormat:@"Patch #%u Enabled 长度无效",entry->patchID];break;}
            NSUInteger count=entry->enabledLength/4u;if(!count||count>32){local=[NSString stringWithFormat:@"Patch #%u Enabled 指令数无效",entry->patchID];break;}
            std::vector<ZNVCLocation> locations;locations.reserve(count);uint64_t fragment=entry->onRVA;
            for(NSUInteger i=0;i<count;i++){
                uint64_t src=fragment+(i==0?4u:0u),off=0;if(!mapTextRVA(src,&off)){local=[NSString stringWithFormat:@"Patch #%u source RVA 越界",entry->patchID];break;}
                uint32_t insn=ZNVCRead32(base+off);locations.push_back({src,off,insn});if(i+1>=count)break;
                uint64_t brRVA=src+4u,brOff=0,next=0;if(!mapTextRVA(brRVA,&brOff)||!ZNVCDecodeBTarget(brRVA,ZNVCRead32(base+brOff),&next)){local=[NSString stringWithFormat:@"Patch #%u Protection V2 fragment chain 无效",entry->patchID];break;}fragment=next;
            }
            if(local)break;if(locations.empty()){local=@"value-cell source 为空";break;}
            uint64_t cellRVA=cellBaseRVA+(uint64_t)e*8u;uint64_t cellOff=cellFileBase+(uint64_t)e*8u;uint32_t first=locations[0].insn;
            ZNValueType authored=ZNFeatureValueTypeFromFlags(entry->flags),resolved=authored;uint32_t replacement=0;
            if(ZNVCIsMOVZ(first)){
                BOOL is64=(first&0x80000000u)!=0;uint32_t rd=first&31u;if(resolved==ZNValueTypeAuto)resolved=is64?ZNValueTypeI64:ZNValueTypeI32;
                if((resolved==ZNValueTypeI32||resolved==ZNValueTypeU32)&&is64){local=[NSString stringWithFormat:@"Patch #%u I32/U32 与 MOV X 不匹配",entry->patchID];break;}
                if((resolved==ZNValueTypeI64||resolved==ZNValueTypeU64)&&!is64){local=[NSString stringWithFormat:@"Patch #%u I64/U64 与 MOV W 不匹配",entry->patchID];break;}
                if(resolved!=ZNValueTypeI32&&resolved!=ZNValueTypeU32&&resolved!=ZNValueTypeI64&&resolved!=ZNValueTypeU64){local=[NSString stringWithFormat:@"Patch #%u 浮点类型不能参数化 MOV",entry->patchID];break;}
                uint64_t raw=0;uint32_t hw=(first>>21)&3u;uint16_t imm=(uint16_t)((first>>5)&0xFFFFu);raw=(uint64_t)imm<<(hw*16u);uint32_t width64=is64?1u:0u;
                for(NSUInteger i=1;i<locations.size();i++){
                    uint32_t insn=locations[i].insn;if(!ZNVCIsMOVK(insn)||(((insn&0x80000000u)!=0)?1u:0u)!=width64||(insn&31u)!=rd)break;uint32_t khw=(insn>>21)&3u;if(!is64&&khw>1u)break;uint16_t kimm=(uint16_t)((insn>>5)&0xFFFFu);uint64_t mask=UINT64_C(0xFFFF)<<(khw*16u);raw=(raw&~mask)|((uint64_t)kimm<<(khw*16u));ZNVCWrite32(base+locations[i].fileoff,0xD503201Fu);
                }
                if(!ZNVCEncodeLiteral(locations[0].rva,cellRVA,is64?0x58000000u:0x18000000u,rd,&replacement)){local=[NSString stringWithFormat:@"Patch #%u value cell 超出 LDR literal ±1MB",entry->patchID];break;}
                memcpy(base+cellOff,&raw,8);
            } else if(ZNVCIsScalarFMOVImm(first)) {
                BOOL f64=((first>>22)&3u)==1u;uint32_t rd=first&31u;if(resolved==ZNValueTypeAuto)resolved=f64?ZNValueTypeF64:ZNValueTypeF32;
                if((resolved==ZNValueTypeF32&&f64)||(resolved==ZNValueTypeF64&&!f64)||(resolved!=ZNValueTypeF32&&resolved!=ZNValueTypeF64)){local=[NSString stringWithFormat:@"Patch #%u Value Type 与 FMOV S/D 不匹配",entry->patchID];break;}
                uint8_t imm8=(uint8_t)((first>>13)&0xFFu);uint64_t raw=f64?ZNVCExpandF64(imm8):(uint64_t)ZNVCExpandF32(imm8);memcpy(base+cellOff,&raw,8);
                if(!ZNVCEncodeLiteral(locations[0].rva,cellRVA,f64?0x5C000000u:0x1C000000u,rd,&replacement)){local=[NSString stringWithFormat:@"Patch #%u FP value cell 超出 LDR literal ±1MB",entry->patchID];break;}
            } else {
                local=[NSString stringWithFormat:@"Patch #%u Number/Slider 仅支持 MOVZ(+MOVK) 或 scalar FMOV #imm，当前 0x%08X",entry->patchID,first];break;
            }
            ZNVCWrite32(base+locations[0].fileoff,replacement);
            entry->flags=(entry->flags&~ZN44_STATIC_ENTRY_VALUE_CELL_TYPE_MASK)|ZN44_STATIC_ENTRY_FLAG_VALUE_CELL_V1|ZN44StaticValueCellTypeFlags((uint32_t)resolved);
            converted++;
        }
        if(local)break;if(converted)header->flags|=ZN44_STATIC_HEADER_FLAG_VALUE_CELLS_V1;
        if(msync(base,size,MS_SYNC)!=0){local=[NSString stringWithFormat:@"value-cell msync 失败 errno=%d",errno];break;}ok=YES;
    }while(0);
    munmap(base,size);close(fd);if(convertedEntries)*convertedEntries=converted;if(!ok&&error)*error=local?:@"Static value-cell 参数化失败";return ok;
}
