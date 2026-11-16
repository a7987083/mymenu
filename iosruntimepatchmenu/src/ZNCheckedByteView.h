#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>
static inline int ZNCheckedRange64(uint64_t size,uint64_t offset,uint64_t length) {
    return offset<=size && length<=size-offset;
}
static inline int ZNCheckedAdd64(uint64_t a,uint64_t b,uint64_t *out) {
    if(b>UINT64_MAX-a)return 0;
    if(out)*out=a+b;
    return 1;
}
static inline int ZNCheckedAlign8(uint64_t value,uint64_t *out) {
    uint64_t sum=0;
    if(!ZNCheckedAdd64(value,7,&sum))return 0;
    if(out)*out=sum&~UINT64_C(7);
    return 1;
}
static inline const uint8_t *ZNByteViewSlice(const uint8_t *base,uint64_t size,uint64_t offset,uint64_t length) {
    if(!base || !ZNCheckedRange64(size,offset,length) || offset>UINTPTR_MAX-(uintptr_t)base)return NULL;
    return base+(uintptr_t)offset;
}
static inline int ZNByteViewRead(const uint8_t *base,uint64_t size,uint64_t offset,void *out,size_t length) {
    const uint8_t *slice=ZNByteViewSlice(base,size,offset,length);
    if(!slice || !out)return 0;
    memcpy(out,slice,length);
    return 1;
}
