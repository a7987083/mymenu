#pragma once
// Thin little-endian 64-bit FILE view. Never use file ranges for a dyld mapping.
#include "ZNCheckedByteView.h"
#include <vector>
#include <array>
#include <limits>
namespace znmacho {
struct Command { uint64_t offset; uint32_t kind, size; };
struct File {
    const uint8_t *bytes = nullptr; uint64_t size = 0, commandEnd = 0;
    std::vector<Command> commands;
};
template<class T> inline T read(const uint8_t *p, uint64_t o) { T v; memcpy(&v,p+o,sizeof(v)); return v; }
inline uint32_t minimum(uint32_t c) {
    switch(c) {
    case 0x1b: return 24;
    case 0x19: return 72; // segment_command_64
    case 2: return 24; case 0xb: return 80; // symtab/dysymtab
    case 0x22: case 0x80000022: return 48; // dyld_info
    case 0x16: return 16; case 0x31: return 40; // hints/note
    case 0x1d: case 0x1e: case 0x26: case 0x29: case 0x2b: case 0x2e:
    case 0x80000033: case 0x80000034: return 16;
    default: return 8;
    }
}
inline bool parse(const uint8_t *p,uint64_t size,File &out,const char **error=nullptr,bool arm64=true,bool fileRanges=true) {
    File f; const char *why=nullptr;
    auto fail=[&](const char *s){ if(error)*error=s; out=File{}; return false; };
    if(!ZNByteViewSlice(p,size,0,32))return fail("truncated Mach-O header");
    if(read<uint32_t>(p,0)!=0xfeedfacf)return fail("expected thin little-endian Mach-O64");
    if(arm64 && read<uint32_t>(p,4)!=0x100000c)return fail("expected arm64");
    f.commandEnd=32+uint64_t(read<uint32_t>(p,20));
    if(f.commandEnd>size)return fail("load commands outside file");
    uint32_t n=read<uint32_t>(p,16); uint64_t o=32;
    if(n>(f.commandEnd-32)/8)return fail("impossible command count");
    for(uint32_t i=0;i<n;i++) {
        if(!ZNCheckedRange64(f.commandEnd,o,8))return fail("truncated load command");
        uint32_t c=read<uint32_t>(p,o),len=read<uint32_t>(p,o+4);
        if(len<minimum(c)||!ZNCheckedRange64(f.commandEnd,o,len))return fail("invalid command size");
        // Existing typed consumers require 8-byte alignment in a 64-bit image.
        if((o&7)||(len&7))return fail("unaligned load command");
        if(c==0x19) {
            uint64_t vm=read<uint64_t>(p,o+24),vs=read<uint64_t>(p,o+32);
            uint64_t fo=read<uint64_t>(p,o+40),fs=read<uint64_t>(p,o+48),end;
            if(!ZNCheckedAdd64(vm,vs,&end)||!ZNCheckedAdd64(vm,fs,&end)||!ZNCheckedAdd64(fo,fs,&end)||(fileRanges&&!ZNCheckedRange64(size,fo,fs)))return fail("invalid segment range");
            uint32_t ns=read<uint32_t>(p,o+64);
            if(uint64_t(ns)>(len-72)/80)return fail("truncated section table");
            for(uint32_t j=0;j<ns;j++) {
                uint64_t s=o+72+uint64_t(j)*80,sz=read<uint64_t>(p,s+40);
                uint32_t type=read<uint32_t>(p,s+64)&0xff;
                if(!ZNCheckedAdd64(read<uint64_t>(p,s+32),sz,&end))return fail("section VM overflow");
                if(fileRanges && type!=1&&type!=0xc&&type!=0x12 && sz && !ZNCheckedRange64(size,read<uint32_t>(p,s+48),sz))return fail("section outside file");
            }
        }
        if(fileRanges){
        auto range=[&](unsigned offset,unsigned length,unsigned stride=1){
            uint64_t count=read<uint32_t>(p,o+length);
            return !count || ZNCheckedRange64(size,read<uint32_t>(p,o+offset),count*stride);
        };
        if(c==2 && (!range(8,12,16)||!range(16,20)))return fail("symbol table outside file");
        if(c==0xb)for(auto pair:{std::array<unsigned,3>{32,36,8},{40,44,56},{48,52,4},{56,60,4},{64,68,8},{72,76,8}})
            if(!range(pair[0],pair[1],pair[2]))return fail("dynamic symbol table outside file");
        if(c==0x22||c==0x80000022)for(unsigned x:{8u,16u,24u,32u,40u})if(!range(x,x+4))return fail("dyld data outside file");
        if(c==0x1d||c==0x1e||c==0x26||c==0x29||c==0x2b||c==0x2e||c==0x80000033||c==0x80000034)
            if(!range(8,12))return fail("LINKEDIT data outside file");
        if(c==0x16&&!range(8,12,4))return fail("hints outside file");
        if(c==0x31 && read<uint64_t>(p,o+32) && !ZNCheckedRange64(size,read<uint64_t>(p,o+24),read<uint64_t>(p,o+32)))return fail("note outside file");
        }
        f.commands.push_back({o,c,len}); o+=len;
    }
    f.bytes=p; f.size=size; out=std::move(f); if(error)*error=why; return true;
}
struct SectionLocation { uint64_t segmentOffset=0,sectionOffset=0; };
inline bool findSection(const File &f,const char *segment,const char *section,SectionLocation &out,const char **error=nullptr) {
    SectionLocation found; unsigned segmentCount=0,sectionCount=0;
    for(const auto &c:f.commands)if(c.kind==0x19 && strncmp((const char*)f.bytes+c.offset+8,segment,16)==0) {
        ++segmentCount;
        for(uint32_t i=0;i<read<uint32_t>(f.bytes,c.offset+64);i++) {
            uint64_t o=c.offset+72+uint64_t(i)*80;
            if(strncmp((const char*)f.bytes+o,section,16))continue;
            ++sectionCount;found={c.offset,o};
            uint64_t start=read<uint32_t>(f.bytes,o+48),size=read<uint64_t>(f.bytes,o+40);
            uint64_t segStart=read<uint64_t>(f.bytes,c.offset+40),segSize=read<uint64_t>(f.bytes,c.offset+48);
            if(start<segStart||!ZNCheckedRange64(segSize,start-segStart,size)) {if(error)*error="section outside owner segment";return false;}
        }
    }
    if(segmentCount!=1||sectionCount!=1){if(error)*error="missing or ambiguous owner section";return false;}
    out=found;return true;
}
struct Patch { uint64_t offset,value; unsigned width; };
// Preflight every field before writing any byte: overflow never leaves a partial edit.
// Consumes a provably padded chained-starts table. Compact payloads are first
// expanded in the disposable file copy by ZNChainedStartsGrowth.h.
inline bool shiftLinkedit(uint8_t *p,uint64_t size,uint64_t threshold,uint64_t delta,
                          const char **error=nullptr,uint32_t insertedSegments=0) {
    File f; if(!parse(p,size,f,error))return false;
    std::vector<Patch> patches;
    uint32_t segmentCount=0;
    for(const auto &c:f.commands)if(c.kind==0x19)++segmentCount;
    for(const auto &c:f.commands)if(c.kind==0x80000034u) {
        if(!insertedSegments||segmentCount<=insertedSegments){
            if(error)*error="LC_DYLD_CHAINED_FIXUPS requires inserted-segment count";
            return false;
        }
        uint64_t oldData=read<uint32_t>(p,c.offset+8),length=read<uint32_t>(p,c.offset+12),at=0;
        if(oldData<threshold||!ZNCheckedAdd64(oldData,delta,&at)||
           !ZNCheckedRange64(size,at,length)||length<32){
            if(error)*error="LC_DYLD_CHAINED_FIXUPS relocated payload invalid";
            return false;
        }
        uint32_t startsOffset=read<uint32_t>(p,at+4);
        if(read<uint32_t>(p,at)!=0||startsOffset<28||
           !ZNCheckedRange64(length,startsOffset,4)){
            if(error)*error="LC_DYLD_CHAINED_FIXUPS header unsupported";
            return false;
        }
        uint64_t starts=at+startsOffset;
        uint32_t oldCount=read<uint32_t>(p,starts);
        if(oldCount!=segmentCount-insertedSegments||oldCount<1||
           !ZNCheckedRange64(length,startsOffset,4ull+4ull*oldCount)||
           read<uint32_t>(p,starts+4ull*oldCount)!=0){
            if(error)*error="LC_DYLD_CHAINED_FIXUPS segment table mismatch";
            return false;
        }
        uint64_t oldEnd=startsOffset+4ull+4ull*oldCount;
        uint64_t newEnd=startsOffset+4ull+4ull*segmentCount;
        uint64_t first=length;
        for(uint32_t i=0;i<oldCount;i++){
            uint32_t off=read<uint32_t>(p,starts+4ull+4ull*i);
            if(!off)continue;
            uint64_t rec=startsOffset+(uint64_t)off;
            if(off<4ull+4ull*oldCount||!ZNCheckedRange64(length,rec,22)){
                if(error)*error="LC_DYLD_CHAINED_FIXUPS segment record invalid";
                return false;
            }
            uint32_t span=read<uint32_t>(p,at+rec);
            uint16_t pages=read<uint16_t>(p,at+rec+20);
            if(span<22ull+2ull*pages||!ZNCheckedRange64(length,rec,span)){
                if(error)*error="LC_DYLD_CHAINED_FIXUPS page-start span invalid";
                return false;
            }
            if(rec<first)first=rec;
        }
        for(unsigned field:{8u,12u}){
            uint32_t off=read<uint32_t>(p,at+field);
            if(off>length){
                if(error)*error="LC_DYLD_CHAINED_FIXUPS imports/symbols offset outside payload";
                return false;
            }
            if(off&&off<first)first=off;
        }
        if(newEnd>first){
            if(error)*error="LC_DYLD_CHAINED_FIXUPS starts table lacks insertion slack";
            return false;
        }
        for(uint64_t off=oldEnd;off<newEnd;off+=4)if(read<uint32_t>(p,at+off)){
            if(error)*error="LC_DYLD_CHAINED_FIXUPS slack not zero";
            return false;
        }
        patches.push_back({starts,segmentCount,4});
        for(uint32_t i=oldCount;i<segmentCount;i++)
            patches.push_back({starts+4ull+4ull*i,0,4});
    }
    auto add=[&](uint64_t o,unsigned width,bool conditional) {
        uint64_t old=width==4?read<uint32_t>(p,o):read<uint64_t>(p,o),v;
        if(conditional&&(!old||old<threshold))return true;
        if(!ZNCheckedAdd64(old,delta,&v)||(width==4&&v>UINT32_MAX))return false;
        patches.push_back({o,v,width}); return true;
    };
    for(const auto &c:f.commands) {
        bool ok=true; uint64_t o=c.offset;
        switch(c.kind) {
        case 0x19: if(strncmp((const char*)p+o+8,"__LINKEDIT",16)==0)ok=add(o+40,8,false)&&add(o+24,8,false); break;
        case 0x22: case 0x80000022: for(unsigned x:{8u,16u,24u,32u,40u})ok=ok&&add(o+x,4,true); break;
        case 2: ok=add(o+8,4,true)&&add(o+16,4,true); break;
        case 0xb: for(unsigned x:{32u,40u,48u,56u,64u,72u})ok=ok&&add(o+x,4,true); break;
        case 0x16: ok=add(o+8,4,true); break;
        case 0x31: ok=add(o+24,8,true); break;
        case 0x1d: case 0x1e: case 0x26: case 0x29: case 0x2b: case 0x2e: case 0x80000033: case 0x80000034: ok=add(o+8,4,true); break;
        default: break; // Same preserved-command policy as both existing builders.
        }
        if(!ok){if(error)*error="LINKEDIT field overflow";return false;}
    }
    for(const auto &q:patches) { if(q.width==4){uint32_t v=(uint32_t)q.value;memcpy(p+q.offset,&v,4);}else memcpy(p+q.offset,&q.value,8); }
    return true;
}
inline bool align(uint64_t value,uint64_t alignment,uint64_t *out) {
    uint64_t sum; if(!alignment||(alignment&(alignment-1))||!ZNCheckedAdd64(value,alignment-1,&sum))return false;
    *out=sum&~(alignment-1); return true;
}
}
