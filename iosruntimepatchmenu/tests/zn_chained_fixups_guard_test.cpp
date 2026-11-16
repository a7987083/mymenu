// Fail-closed regression: do not silently move chained starts across inserted segments.
#include "../src/ZNMachOFile.h"
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
    std::puts("PASS chained-fixups padded starts reconstruction and compact rejection");
    std::puts("PASS chained-fixups rejection is atomic; ordinary relocation unchanged");
    return 0;
}
