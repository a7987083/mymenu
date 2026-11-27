// Fail-closed regression: do not silently move chained starts across inserted segments.
#include "../src/ZNChainedStartsGrowth.h"
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <vector>
static void put32(std::vector<uint8_t> &b,size_t o,uint32_t v){memcpy(b.data()+o,&v,4);}
static void put64(std::vector<uint8_t> &b,size_t o,uint64_t v){memcpy(b.data()+o,&v,8);}
static std::vector<uint8_t> fixture(bool chained){
    std::vector<uint8_t> b(0x8000,0);
    put32(b,0,0xfeedfacf);put32(b,4,0x0100000c);put32(b,12,6);
    uint32_t count=chained?3:2;put32(b,16,count);put32(b,20,count*72-(chained?56:0));
    // Two segment commands and an optional chained-fixups linkedit command.
    put32(b,32,0x19);put32(b,36,72);
    memcpy(b.data()+40,"__TEXT",6);put64(b,32+24,0x100000000);
    put64(b,32+32,0x4000);put64(b,32+40,0);put64(b,32+48,0x4000);
    put32(b,104,0x19);put32(b,108,72);
    memcpy(b.data()+112,"__LINKEDIT",10);
    put64(b,104+24,0x100004000);put64(b,104+32,0x4000);
    put64(b,104+40,0x4000);put64(b,104+48,0x4000);
    if(chained){put32(b,176,0x80000034);put32(b,180,16);put32(b,184,0x5000);put32(b,188,32);}
    return b;
}

// Original Mach-O fixtures with exactly 4 or 5 segments, 4/0 bytes of
// starts-table slack and a 2-byte gap between starts records and imports.
static std::vector<uint8_t> compactOriginal(uint32_t segments,uint32_t slack){
    const uint64_t le=uint64_t(segments-1)*0x8000;
    std::vector<uint8_t> b(le+0x4000,0);
    put32(b,0,0xfeedfacf);put32(b,4,0x0100000c);put32(b,12,6);
    put32(b,16,segments+4);put32(b,20,72*segments+16+16+24+16);
    for(uint32_t i=0;i<segments;i++){
        const size_t o=32+72*i;
        put32(b,o,0x19);put32(b,o+4,72);
        const char *name=i==0?"__TEXT":i==segments-1?"__LINKEDIT":"__DATA";
        memcpy(b.data()+o+8,name,strlen(name));
        put64(b,o+24,0x100000000ull+uint64_t(i)*0x8000);
        put64(b,o+32,i==segments-1?0x4000:0x8000);
        put64(b,o+40,uint64_t(i)*0x8000);
        put64(b,o+48,i==segments-1?0x4000:0x8000);
    }
    const size_t c=32+72*segments;
    const uint32_t at=uint32_t(le+0x100),rec=28+4+4*segments+slack;
    const uint32_t imports=rec+26+2,symbols=imports+4,len=symbols+8;
    put32(b,c,0x80000034);put32(b,c+4,16);put32(b,c+8,at);put32(b,c+12,len);
    put32(b,at+4,28);put32(b,at+8,imports);put32(b,at+12,symbols);
    put32(b,at+16,1);put32(b,at+20,1);put32(b,at+28,segments);
    put32(b,at+32,rec-28);
    put32(b,at+rec,26);
    uint16_t page=0x4000,format=6,pages=2,none=0xffff;
    memcpy(b.data()+at+rec+4,&page,2);memcpy(b.data()+at+rec+6,&format,2);
    memcpy(b.data()+at+rec+20,&pages,2);
    memcpy(b.data()+at+rec+22,&none,2);memcpy(b.data()+at+rec+24,&none,2);
    put32(b,at+imports,1);memcpy(b.data()+at+symbols,"sym",4);
    put32(b,c+16,0x26);put32(b,c+20,16);put32(b,c+24,uint32_t(le+0x200));put32(b,c+28,8);
    memset(b.data()+le+0x200,0x5a,8);
    put32(b,c+32,2);put32(b,c+36,24);
    put32(b,c+40,uint32_t(le+0x220));put32(b,c+44,1);
    put32(b,c+48,uint32_t(le+0x230));put32(b,c+52,8);
    put32(b,c+56,0x1d);put32(b,c+60,16);
    put32(b,c+64,uint32_t(le+0x400));put32(b,c+68,0x3c00);
    b.back()=0xa5;
    return b;
}
static bool checkCompactGrowth(uint32_t count,uint32_t slack,uint32_t inserted){
    auto b=compactOriginal(count,slack);
    const auto original=b;
    const uint64_t le=uint64_t(count-1)*0x8000,at=le+0x100;
    const size_t leCommand=32+72*(count-1),chainCommand=leCommand+72;
    const char *why=nullptr;
    znmacho::ChainedStartsGrowth plan;
    if(!znmacho::planChainedStartsGrowth(b.data(),b.size(),inserted,plan,&why)){
        fprintf(stderr,"compact plan: %s\n",why?why:"?");return false;
    }
    const uint64_t expected=slack>=4*inserted?0:16;
    if(plan.bytes!=expected||b!=original)return false;
    if(expected){
        if(znmacho::applyChainedStartsGrowth(b.data(),b.size(),plan,&why)||b!=original)return false;
        b.resize(b.size()+expected);
        if(!znmacho::applyChainedStartsGrowth(b.data(),b.size(),plan,&why))return false;
        if(!std::equal(original.begin()+plan.cut,original.end(),b.begin()+plan.cut+expected))return false;
        if(znmacho::read<uint32_t>(b.data(),chainCommand+12)!=
           znmacho::read<uint32_t>(original.data(),chainCommand+12)+expected||
           znmacho::read<uint32_t>(b.data(),at+8)!=znmacho::read<uint32_t>(original.data(),at+8)+expected||
           znmacho::read<uint32_t>(b.data(),at+12)!=znmacho::read<uint32_t>(original.data(),at+12)+expected||
           znmacho::read<uint32_t>(b.data(),at+32)!=znmacho::read<uint32_t>(original.data(),at+32)+expected||
           znmacho::read<uint32_t>(b.data(),chainCommand+24)!=le+0x200+expected||
           znmacho::read<uint32_t>(b.data(),chainCommand+40)!=le+0x220+expected||
           znmacho::read<uint32_t>(b.data(),chainCommand+48)!=le+0x230+expected||
           znmacho::read<uint32_t>(b.data(),chainCommand+64)!=le+0x400+expected||
           znmacho::read<uint64_t>(b.data(),leCommand+48)!=0x4000+expected||
           znmacho::read<uint64_t>(b.data(),leCommand+32)!=0x8000)return false;
    }
    znmacho::ChainedStartsGrowth verify;
    if(!znmacho::planChainedStartsGrowth(b.data(),b.size(),inserted,verify,&why)||verify.bytes)return false;
    // Exercise the real shared post-insertion routine after the preflight.
    const uint64_t oldSize=b.size(),delta=uint64_t(inserted)*0x4000;
    const uint32_t cmdBytes=72*inserted,oldCmdBytes=znmacho::read<uint32_t>(b.data(),20);
    b.resize(oldSize+delta);
    memmove(b.data()+le+delta,b.data()+le,size_t(oldSize-le));
    memset(b.data()+le,0,size_t(delta));
    memmove(b.data()+leCommand+cmdBytes,b.data()+leCommand,32+oldCmdBytes-leCommand);
    memset(b.data()+leCommand,0,cmdBytes);
    for(uint32_t i=0;i<inserted;i++){
        const uint64_t o=leCommand+72*i;
        put32(b,o,0x19);put32(b,o+4,72);memcpy(b.data()+o+8,"__ZNTEST",8);
        put64(b,o+24,0x100000000ull+le+0x4000ull*i);put64(b,o+32,0x4000);
        put64(b,o+40,le+0x4000ull*i);put64(b,o+48,0x4000);
    }
    put32(b,16,count+4+inserted);put32(b,20,oldCmdBytes+cmdBytes);
    if(!znmacho::shiftLinkedit(b.data(),b.size(),le,delta,&why,inserted)){
        fprintf(stderr,"compact post-insertion: %s\n",why?why:"?");return false;
    }
    const uint64_t moved=at+delta,cmd=chainCommand+cmdBytes;
    if(znmacho::read<uint32_t>(b.data(),cmd+8)!=moved||
       znmacho::read<uint32_t>(b.data(),moved+28)!=count+inserted||
       znmacho::read<uint32_t>(b.data(),cmd+64)!=le+0x400+expected+delta||
       znmacho::read<uint32_t>(b.data(),moved+32)!=znmacho::read<uint32_t>(original.data(),at+32)+expected||
       b.back()!=0xa5)return false;
    for(uint32_t i=1;i<count+inserted;i++)
        if(znmacho::read<uint32_t>(b.data(),moved+32+4ull*i)!=0)return false;
    const uint64_t imp=znmacho::read<uint32_t>(b.data(),moved+8),sym=znmacho::read<uint32_t>(b.data(),moved+12);
    znmacho::File file;
    return znmacho::read<uint32_t>(b.data(),moved+imp)==1&&
           !memcmp(b.data()+moved+sym,"sym",4)&&
           znmacho::parse(b.data(),b.size(),file,&why);
}
static bool testCompactGrowth(){
    for(uint32_t inserted:{1u,2u}){
        if(!checkCompactGrowth(4,4,inserted)||!checkCompactGrowth(5,0,inserted)||
           !checkCompactGrowth(4,8,inserted))return false;
    }
    auto invalid=compactOriginal(5,0);
    const uint64_t at=4*0x8000+0x100;
    put32(invalid,at+8,53); // overlaps the 26-byte segment record
    const auto saved=invalid;
    znmacho::ChainedStartsGrowth plan;
    const char *why=nullptr;
    if(znmacho::planChainedStartsGrowth(invalid.data(),invalid.size(),2,plan,&why)||
       invalid!=saved||plan.bytes)return false;
    auto overlap=compactOriginal(5,0);
    const size_t cmd=32+72*5;
    put32(overlap,cmd+24,uint32_t(at+64)); // function-starts aliases fixups
    const auto overlapSaved=overlap;
    if(znmacho::planChainedStartsGrowth(overlap.data(),overlap.size(),2,plan,&why)||
       overlap!=overlapSaved||plan.bytes)return false;
    // Exercise the actual disposable-file mmap/ftruncate adapter as well.
    auto disk=compactOriginal(5,0);
    FILE *fp=tmpfile();
    if(!fp)return false;
    bool ok=fwrite(disk.data(),1,disk.size(),fp)==disk.size()&&fflush(fp)==0;
    if(ok)ok=znmacho::reserveChainedStartsInCopy(fileno(fp),2,&why);
    if(ok){
        struct stat st={};
        ok=fstat(fileno(fp),&st)==0&&uint64_t(st.st_size)==disk.size()+16;
    }
    if(ok){
        const auto before=disk.size();
        disk.resize(before+16);
        rewind(fp);
        ok=fread(disk.data(),1,disk.size(),fp)==disk.size()&&
           znmacho::planChainedStartsGrowth(disk.data(),disk.size(),2,plan,&why)&&!plan.bytes;
    }
    fclose(fp);
    if(!ok)fprintf(stderr,"compact fd preflight: %s\n",why?why:"?");
    return ok;
}

int main(){
    const char *why=nullptr;
    auto regular=fixture(false);
    if(!znmacho::shiftLinkedit(regular.data(),regular.size(),0x4000,0x4000,&why)){fprintf(stderr,"ordinary: %s\n",why?why:"?");return 1;}
    if(znmacho::read<uint64_t>(regular.data(),104+40)!=0x8000)return 2;
    auto chained=fixture(true),original=chained;
    why=nullptr;
    if(znmacho::shiftLinkedit(chained.data(),chained.size(),0x4000,0x4000,&why))return 3;
    if(chained!=original)return 4;
    if(!why||!strstr(why,"CHAINED_FIXUPS"))return 5;
    // Simulate a builder that inserted one segment before __LINKEDIT and
    // moved the original LINKEDIT payload by one page.
    auto padded=fixture(false);
    padded.resize(0x10000);
    put32(padded,16,4);put32(padded,20,232);
    // Rewrite commands: __TEXT, __ZNTYPE, __LINKEDIT, CHAINED_FIXUPS.
    put32(padded,104,0x19);put32(padded,108,72);
    memcpy(padded.data()+112,"__ZNTYPE",8);
    put64(padded,104+24,0x100004000);put64(padded,104+32,0x4000);
    put64(padded,104+40,0x4000);put64(padded,104+48,0x4000);
    put32(padded,176,0x19);put32(padded,180,72);
    memcpy(padded.data()+184,"__LINKEDIT",10);
    put64(padded,176+24,0x100004000);put64(padded,176+32,0x4000);
    put64(padded,176+40,0x4000);put64(padded,176+48,0x4000);
    put32(padded,248,0x80000034);put32(padded,252,16);
    put32(padded,256,0x5000);put32(padded,260,0x80);
    const size_t blob=0x9000;
    put32(padded,blob,0);put32(padded,blob+4,28);
    put32(padded,blob+8,0x70);put32(padded,blob+12,0x70);
    put32(padded,blob+28,2);put32(padded,blob+32,0x20);
    put32(padded,blob+36,0);
    put32(padded,blob+28+0x20,22); // one valid segment record, zero pages
    if(!znmacho::shiftLinkedit(padded.data(),padded.size(),0x4000,0x4000,&why,1)){
        fprintf(stderr,"padded chained rebuild: %s\\n",why?why:"?");
        return 6;
    }
    if(znmacho::read<uint32_t>(padded.data(),blob+28)!=3||
       znmacho::read<uint32_t>(padded.data(),blob+32)!=0x20||
       znmacho::read<uint32_t>(padded.data(),blob+36)!=0||
       znmacho::read<uint32_t>(padded.data(),blob+40)!=0||
       znmacho::read<uint32_t>(padded.data(),256)!=0x9000)return 7;
    // Main Static Builder inserts TWO segments, unlike Typed Builder's one.
    auto two=padded;
    // Restore original starts count and old dataoff before the second build.
    put32(two,blob+28,2);
    // Move __LINKEDIT and chain load commands up by one segment slot.
    memmove(two.data()+320,two.data()+248,16);
    put32(two,328,0x5000);
    memmove(two.data()+248,two.data()+176,72);
    put32(two,176,0x19);put32(two,180,72);
    memset(two.data()+184,0,64);
    memcpy(two.data()+184,"__ZNDATA",8);
    put64(two,176+24,0x100004000);put64(two,176+32,0x4000);
    put64(two,176+40,0x4000);put64(two,176+48,0x4000);
    put32(two,16,5);put32(two,20,304);
    why=nullptr;
    if(!znmacho::shiftLinkedit(two.data(),two.size(),0x4000,0x4000,&why,2)){
        fprintf(stderr,"two segment rebuild: %s\\n",why?why:"?");
        return 10;
    }
    if(znmacho::read<uint32_t>(two.data(),blob+28)!=4||
       znmacho::read<uint32_t>(two.data(),blob+32)!=0x20||
       znmacho::read<uint32_t>(two.data(),blob+36)!=0||
       znmacho::read<uint32_t>(two.data(),blob+40)!=0||
       znmacho::read<uint32_t>(two.data(),blob+44)!=0||
       znmacho::read<uint32_t>(two.data(),320+8)!=0x9000)return 11;
    auto compact=fixture(false);
    compact.resize(0x10000);
    memcpy(compact.data(),padded.data(),0x400);
    memcpy(compact.data()+blob,padded.data()+blob,0x80);
    put32(compact,256,0x5000);
    put32(compact,blob+28,2);
    put32(compact,blob+8,0x28); // next payload begins before expanded table ends
    auto saved=compact;
    why=nullptr;
    if(znmacho::shiftLinkedit(compact.data(),compact.size(),0x4000,0x4000,&why,1))return 8;
    if(compact!=saved)return 9;
    // A compact starts table with a structurally bounded segment record immediately
    // following the offset array. Do not simulate tight packing by overlapping
    // the import payload with a segment record.
    auto packed = compact;
    memset(packed.data()+blob, 0, 0x80);
    put32(packed,256,0x5000);
    put32(packed,blob+4,28);   // starts_offset
    put32(packed,blob+8,64);   // imports_offset; zero imports
    put32(packed,blob+12,64);  // symbols_offset
    put32(packed,blob+20,1);   // DYLD_CHAINED_IMPORT
    put32(packed,blob+28,2);   // original segment count
    put32(packed,blob+32,12);  // record begins exactly at end of offset array
    const size_t rec = blob+40;
    put32(packed,rec,24);      // fixed record plus one page_start
    const uint16_t pageSize=0x4000, pointerFormat=6, pageCount=1, noStart=0xffff;
    memcpy(packed.data()+rec+4,&pageSize,2);
    memcpy(packed.data()+rec+6,&pointerFormat,2);
    memcpy(packed.data()+rec+20,&pageCount,2);
    memcpy(packed.data()+rec+22,&noStart,2);
    const auto packedOriginal=packed;
    why=nullptr;
    if(znmacho::shiftLinkedit(packed.data(),packed.size(),0x4000,0x4000,&why,1)){
        fprintf(stderr,"compact record unexpectedly accepted by fixed-capacity relocation\n");
        return 12;
    }
    if(!why||strcmp(why,"LC_DYLD_CHAINED_FIXUPS starts table lacks insertion slack")){
        fprintf(stderr,"compact record: unexpected rejection: %s\n",why?why:"?");
        return 13;
    }
    if(packed!=packedOriginal)return 14;
    // Bounds of the existing array must be checked independently of the proposed growth.
    auto truncated = packedOriginal;
    put32(truncated,260,36); // starts_offset=28; only one of two offsets fits
    auto truncatedOriginal=truncated;
    why=nullptr;
    if(znmacho::shiftLinkedit(truncated.data(),truncated.size(),0x4000,0x4000,&why,1))return 15;
    if(!why||strcmp(why,"LC_DYLD_CHAINED_FIXUPS segment table mismatch")||
       truncated!=truncatedOriginal)return 16;
    for(size_t field : {size_t(8),size_t(12)}){
        auto invalid = packedOriginal;
        put32(invalid,blob+field,0x81); // payload length is 0x80
        auto invalidOriginal=invalid;
        why=nullptr;
        if(znmacho::shiftLinkedit(invalid.data(),invalid.size(),0x4000,0x4000,&why,1))return 17;
        if(!why||strcmp(why,"LC_DYLD_CHAINED_FIXUPS imports/symbols offset outside payload")||
           invalid!=invalidOriginal)return 18;
    }
    if(!testCompactGrowth()){fprintf(stderr,"compact starts growth regression failed\n");return 19;}
    std::puts("PASS compact starts growth: 4/5 segments, 4/0 byte slack, one/two insertions and file-copy adapter");
    std::puts("PASS chained-fixups existing array and payload offsets are bounded");
    std::puts("PASS compact starts record: exact rejection and byte-for-byte atomicity");
    std::puts("PASS chained-fixups padded starts reconstruction and compact rejection");
    std::puts("PASS chained-fixups rejection is atomic; ordinary relocation unchanged");
    return 0;
}
