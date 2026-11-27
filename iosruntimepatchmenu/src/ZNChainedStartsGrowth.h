#pragma once
// File-copy preflight: reserve starts slots without moving any original mapped
// code/data. The existing segment insertion pass consumes the zeroed slots.
#include "ZNMachOFile.h"
#include <algorithm>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace znmacho {
struct ChainedStartsGrowth {
    uint64_t oldSize=0, cut=0, bytes=0;
    std::vector<Patch> patches;
};

inline bool planChainedStartsGrowth(const uint8_t *p,uint64_t size,uint32_t inserted,
                                    ChainedStartsGrowth &out,const char **error=nullptr) {
    out=ChainedStartsGrowth{};
    auto fail=[&](const char *s){if(error)*error=s;return false;};
    File f;
    if(!parse(p,size,f,error))return false;
    if(!inserted||inserted>2)return fail("unsupported starts growth segment count");
    const Command *chain=nullptr,*linkedit=nullptr,*lastSegment=nullptr;
    uint32_t segmentCount=0;
    for(const auto &c:f.commands){
        if(c.kind==0x19){
            ++segmentCount;lastSegment=&c;
            if(!strncmp((const char*)p+c.offset+8,"__LINKEDIT",16)){
                if(linkedit)return fail("ambiguous LINKEDIT segment");
                linkedit=&c;
            }
        }
        if(c.kind==0x80000034u){
            if(chain)return fail("duplicate LC_DYLD_CHAINED_FIXUPS");
            chain=&c;
        }
    }
    if(!chain)return true;
    if(!linkedit||lastSegment!=linkedit||!segmentCount)
        return fail("LC_DYLD_CHAINED_FIXUPS requires terminal LINKEDIT segment");
    const uint64_t at=read<uint32_t>(p,chain->offset+8);
    const uint64_t len=read<uint32_t>(p,chain->offset+12);
    const uint64_t le=linkedit->offset;
    const uint64_t leStart=read<uint64_t>(p,le+40),leSize=read<uint64_t>(p,le+48);
    if(at<leStart||!ZNCheckedRange64(leSize,at-leStart,len)||
       !ZNCheckedRange64(size,at,len)||len<32)
        return fail("LC_DYLD_CHAINED_FIXUPS payload outside LINKEDIT");
    const uint8_t *blob=p+at;
    const uint64_t starts=read<uint32_t>(blob,4);
    if(read<uint32_t>(blob,0)!=0||starts<28||!ZNCheckedRange64(len,starts,4))
        return fail("LC_DYLD_CHAINED_FIXUPS header unsupported");
    const uint32_t oldCount=read<uint32_t>(blob,starts);
    const uint64_t tableBytes=4ull+4ull*oldCount;
    if(oldCount!=segmentCount||!oldCount||!ZNCheckedRange64(len,starts,tableBytes)||
       read<uint32_t>(blob,starts+4ull*oldCount)!=0)
        return fail("LC_DYLD_CHAINED_FIXUPS segment table mismatch");
    const uint64_t oldEnd=starts+tableBytes;
    const uint64_t required=4ull*inserted;
    uint64_t first=len,recordEnd=oldEnd;
    std::vector<std::pair<uint64_t,uint64_t>> ranges;
    ChainedStartsGrowth plan;
    plan.oldSize=size;
    // A 16-byte insertion preserves the alignment of all subsequent payloads,
    // including the existing code signature. No original bytes are discarded.
    constexpr uint64_t growth=16;
    for(uint32_t i=0;i<oldCount;i++){
        const uint64_t field=starts+4ull+4ull*i;
        const uint64_t off=read<uint32_t>(blob,field);
        if(!off)continue;
        const uint64_t rec=starts+off;
        if(off<tableBytes||!ZNCheckedRange64(len,rec,22))
            return fail("LC_DYLD_CHAINED_FIXUPS segment record invalid");
        const uint64_t span=read<uint32_t>(blob,rec);
        const uint64_t pages=read<uint16_t>(blob,rec+20);
        if(span<22ull+2ull*pages||!ZNCheckedRange64(len,rec,span))
            return fail("LC_DYLD_CHAINED_FIXUPS page-start span invalid");
        ranges.push_back({rec,rec+span});
        first=std::min(first,rec);
        recordEnd=std::max(recordEnd,rec+span);
        plan.patches.push_back({at+field,off+growth,4});
    }
    std::sort(ranges.begin(),ranges.end());
    for(size_t i=1;i<ranges.size();i++)
        if(ranges[i-1].second>ranges[i].first)
            return fail("LC_DYLD_CHAINED_FIXUPS overlapping segment records");
    const uint64_t imports=read<uint32_t>(blob,8),symbols=read<uint32_t>(blob,12);
    for(uint64_t off:{imports,symbols}){
        if(off>len)return fail("LC_DYLD_CHAINED_FIXUPS imports/symbols offset outside payload");
        if(off&&off<recordEnd)return fail("LC_DYLD_CHAINED_FIXUPS imports/symbols overlap starts");
        if(off)first=std::min(first,off);
    }
    if(imports&&symbols&&symbols<imports)
        return fail("LC_DYLD_CHAINED_FIXUPS imports/symbols order invalid");
    const uint32_t importCount=read<uint32_t>(blob,16),format=read<uint32_t>(blob,20);
    if(importCount){
        const uint64_t stride=format==1?4:format==2?8:format==3?16:0;
        if(!stride||!imports||!symbols||
           !ZNCheckedRange64(symbols,imports,uint64_t(importCount)*stride))
            return fail("LC_DYLD_CHAINED_FIXUPS import table invalid");
    }
    bool padded=required<=first-oldEnd;
    if(padded){
        for(uint64_t i=0;i<required;i++)if(blob[oldEnd+i]){padded=false;break;}
    }
    if(padded)return true;
    // Only grow a terminal, sectionless LINKEDIT; unknown file-offset-bearing
    // commands are rejected rather than silently leaving stale references.
    if(leStart<f.commandEnd||leSize!=size-leStart||read<uint32_t>(p,le+64)!=0||
       read<uint64_t>(p,le+32)<leSize)
        return fail("compact starts requires terminal sectionless LINKEDIT");
    uint64_t newSize=0,newLESize=0,newVMSize=0,vmEnd=0;
    const uint64_t leVM=read<uint64_t>(p,le+24);
    if(!ZNCheckedAdd64(size,growth,&newSize)||newSize>SIZE_MAX||
       len>UINT32_MAX-growth||!ZNCheckedAdd64(leSize,growth,&newLESize)||
       !align(newLESize,0x4000,&newVMSize))
        return fail("compact starts growth overflow");
    newVMSize=std::max(newVMSize,read<uint64_t>(p,le+32));
    if(!ZNCheckedAdd64(leVM,newVMSize,&vmEnd))
        return fail("compact starts LINKEDIT VM overflow");
    const uint64_t end=at+len;
    plan.cut=at+oldEnd;plan.bytes=growth;
    if(imports)plan.patches.push_back({at+8,imports+growth,4});
    if(symbols)plan.patches.push_back({at+12,symbols+growth,4});
    plan.patches.push_back({chain->offset+12,len+growth,4});
    plan.patches.push_back({le+48,newLESize,8});
    plan.patches.push_back({le+32,newVMSize,8});
    auto relocate=[&](uint64_t field,unsigned width,uint64_t span){
        const uint64_t old=width==4?read<uint32_t>(p,field):read<uint64_t>(p,field);
        if(!old)return span==0;
        if(!ZNCheckedRange64(size,old,span))return false;
        if(old<at)return span<=at-old;
        if(old<end)return false; // another command aliases the fixups payload
        uint64_t value=0;
        if(!ZNCheckedAdd64(old,growth,&value)||(width==4&&value>UINT32_MAX))return false;
        plan.patches.push_back({field,value,width});return true;
    };
    for(const auto &c:f.commands){
        const uint64_t o=c.offset;
        bool ok=true;
        switch(c.kind){
        case 0x19:
            if(&c!=linkedit){
                const uint64_t fo=read<uint64_t>(p,o+40),fs=read<uint64_t>(p,o+48);
                const uint64_t vm=read<uint64_t>(p,o+24),vs=read<uint64_t>(p,o+32);
                if((fs&&!ZNCheckedRange64(leStart,fo,fs))||
                   (vs&&!ZNCheckedRange64(leVM,vm,vs)))
                    return fail("compact starts requires original segments before LINKEDIT");
                for(uint32_t i=0;i<read<uint32_t>(p,o+64);i++){
                    const uint64_t s=o+72ull+80ull*i;
                    const uint64_t rel=read<uint32_t>(p,s+56),n=read<uint32_t>(p,s+60);
                    // The existing segment insertion pass does not relocate section
                    // relocation offsets; fail closed for such LINKEDIT layouts.
                    if((rel||n)&&(!rel||rel>=leStart||!ZNCheckedRange64(leStart,rel,n*8ull)))
                        return fail("compact starts section relocation unsupported");
                }
            }
            break;
        case 2:
            ok=relocate(o+8,4,uint64_t(read<uint32_t>(p,o+12))*16)&&
               relocate(o+16,4,read<uint32_t>(p,o+20));break;
        case 0xb:
            for(auto t:{std::array<unsigned,3>{32,36,8},{40,44,56},{48,52,4},
                        {56,60,4},{64,68,8},{72,76,8}})
                ok=ok&&relocate(o+t[0],4,uint64_t(read<uint32_t>(p,o+t[1]))*t[2]);
            break;
        case 0x22:case 0x80000022u:
            for(unsigned x:{8u,16u,24u,32u,40u})
                ok=ok&&relocate(o+x,4,read<uint32_t>(p,o+x+4));
            break;
        case 0x16:ok=relocate(o+8,4,uint64_t(read<uint32_t>(p,o+12))*4);break;
        case 0x31:ok=relocate(o+24,8,read<uint64_t>(p,o+32));break;
        case 0x1d:case 0x1e:case 0x26:case 0x29:case 0x2b:case 0x2e:case 0x80000033u:
            ok=relocate(o+8,4,read<uint32_t>(p,o+12));break;
        case 0x80000034u:break;
        case 0x21:case 0x2c:
            if(c.size<(c.kind==0x21?20u:24u)||
               !ZNCheckedRange64(leStart,read<uint32_t>(p,o+8),read<uint32_t>(p,o+12)))
                return fail("compact starts encryption range unsupported");
            break;
        // Common commands without absolute file offsets into LINKEDIT.
        case 0x4:case 0x5:case 0xc:case 0xd:case 0xe:case 0xf:case 0x10:
        case 0x12:case 0x13:case 0x14:case 0x15:case 0x17:case 0x80000018u:
        case 0x1a:case 0x1b:case 0x8000001cu:case 0x8000001fu:case 0x20:
        case 0x80000023u:case 0x24:case 0x25:case 0x27:case 0x80000028u:
        case 0x2a:case 0x2d:case 0x2f:case 0x30:case 0x32:case 0x39:
            break;
        default:return fail("compact starts unsupported load command");
        }
        if(!ok)return fail("compact starts overlapping or overflowing LINKEDIT reference");
    }
    out=std::move(plan);return true;
}

inline bool applyChainedStartsGrowth(uint8_t *p,uint64_t capacity,
                                     const ChainedStartsGrowth &plan,const char **error=nullptr){
    if(!plan.bytes)return true;
    if(!p||plan.cut>plan.oldSize||!ZNCheckedRange64(capacity,plan.oldSize,plan.bytes)){
        if(error)*error="compact starts output capacity insufficient";return false;
    }
    for(const auto &q:plan.patches)
        if((q.width!=4&&q.width!=8)||!ZNCheckedRange64(plan.cut,q.offset,q.width)||
           (q.width==4&&q.value>UINT32_MAX)){
            if(error)*error="compact starts invalid planned write";return false;
        }
    memmove(p+plan.cut+plan.bytes,p+plan.cut,size_t(plan.oldSize-plan.cut));
    memset(p+plan.cut,0,size_t(plan.bytes));
    for(const auto &q:plan.patches){
        if(q.width==4){const uint32_t v=uint32_t(q.value);memcpy(p+q.offset,&v,4);}
        else memcpy(p+q.offset,&q.value,8);
    }
    return true;
}

// The fd must belong to the disposable output copy, never the original input.
// On any failure the caller removes that copy, including after ftruncate.
inline bool reserveChainedStartsInCopy(int fd,uint32_t inserted,const char **error=nullptr){
    auto fail=[&](const char *s){if(error)*error=s;return false;};
    struct stat st={};
    if(fstat(fd,&st)!=0||st.st_size<=0||uint64_t(st.st_size)>SIZE_MAX)
        return fail("compact starts invalid output file size");
    const uint64_t oldSize=uint64_t(st.st_size);
    void *map=mmap(nullptr,size_t(oldSize),PROT_READ,MAP_PRIVATE,fd,0);
    if(map==MAP_FAILED)return fail("compact starts preflight mmap failed");
    ChainedStartsGrowth plan;
    const bool planned=planChainedStartsGrowth(static_cast<const uint8_t*>(map),oldSize,inserted,plan,error);
    munmap(map,size_t(oldSize));
    if(!planned||!plan.bytes)return planned;
    const uint64_t newSize=oldSize+plan.bytes;
    if(newSize>uint64_t(std::numeric_limits<off_t>::max())||
       ftruncate(fd,off_t(newSize))!=0)
        return fail("compact starts ftruncate failed");
    map=mmap(nullptr,size_t(newSize),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(map==MAP_FAILED)return fail("compact starts expanded mmap failed");
    auto *p=static_cast<uint8_t*>(map);
    bool ok=applyChainedStartsGrowth(p,newSize,plan,error);
    if(ok){
        ChainedStartsGrowth verify;
        ok=planChainedStartsGrowth(p,newSize,inserted,verify,error);
        if(ok&&verify.bytes)ok=fail("compact starts postflight still lacks capacity");
    }
    if(ok&&msync(map,size_t(newSize),MS_SYNC)!=0)ok=fail("compact starts msync failed");
    munmap(map,size_t(newSize));
    return ok;
}
} // namespace znmacho
