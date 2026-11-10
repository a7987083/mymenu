#import "ZNCustomerCatalog.h"
#import "../iosruntimepatchmenu/src/ZNStaticPatchFormat.h"
#import "../iosruntimepatchmenu/src/ZNRuntimeActionFormat.h"
#import "../iosruntimepatchmenu/src/ZNGeneratedDataLayout.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>

static NSString *ZNText(const char *p, size_t limit) {
    size_t n=strnlen(p,limit);
    NSString *s=[[NSString alloc]initWithBytes:p length:n encoding:NSUTF8StringEncoding];
    return s?:@"";
}
static NSString *ZNPoolText(const uint8_t *base, const ZNRuntimeActionHeader *h, uint32_t off) {
    if(off>=h->stringPoolSize)return @"";
    const char *p=(const char *)(base+h->stringPoolOffset+off);
    return ZNText(p,h->stringPoolSize-off);
}
static ZNCustomerItem *ZNItem(NSString *key, NSString *title, NSString *detail, ZNCustomerControlKind kind) {
    ZNCustomerItem *i=[ZNCustomerItem new];
    i.identifier=key;i.title=title.length?title:@"未命名功能";i.detail=detail?:@"";
    i.kind=kind;i.enabled=NO;i.minimum=0;i.maximum=1;i.value=0;
    return i;
}
@implementation ZNCustomerCatalog
+ (NSArray<ZNCustomerItem *> *)discover {
    NSMutableArray<ZNCustomerItem *> *result=[NSMutableArray array];
    NSMutableSet<NSString *> *keys=[NSMutableSet set];
    for(uint32_t imageIndex=0;imageIndex<_dyld_image_count();imageIndex++){
        const struct mach_header *mh=_dyld_get_image_header(imageIndex);
        if(!mh || mh->magic!=MH_MAGIC_64)continue;
        const struct mach_header_64 *header=(const struct mach_header_64 *)mh;
        const uint8_t *cmd=(const uint8_t *)(header+1);
        const uint8_t *cmdEnd=cmd+header->sizeofcmds;
        for(uint32_t j=0;j<header->ncmds;j++){
            if(cmd+sizeof(struct load_command)>cmdEnd)break;
            const struct load_command *lc=(const struct load_command *)cmd;
            if(lc->cmdsize<sizeof(*lc) || lc->cmdsize>(size_t)(cmdEnd-cmd))break;
            if(lc->cmd==LC_SEGMENT_64 && lc->cmdsize>=sizeof(struct segment_command_64)){
                const struct segment_command_64 *seg=(const struct segment_command_64 *)cmd;
                if(strncmp(seg->segname,"__ZNDATA",16)==0 &&
                   seg->nsects <= (lc->cmdsize-sizeof(*seg))/sizeof(struct section_64) &&
                   lc->cmdsize>=sizeof(*seg)+(uint64_t)seg->nsects*sizeof(struct section_64)){
                    const struct section_64 *sections=(const struct section_64 *)(seg+1);
                    for(uint32_t k=0;k<seg->nsects;k++){
                        const struct section_64 *sect=&sections[k];
                        if(strncmp(sect->sectname,"__zndata",16)!=0)continue;
                        if(sect->size<sizeof(ZN44StaticHeader) || sect->size>1024*1024)continue;
                        uintptr_t address=(uintptr_t)((intptr_t)sect->addr+_dyld_get_image_vmaddr_slide(imageIndex));
                        if(!address || address+sect->size<address)continue;
                        const uint8_t *data=(const uint8_t *)address;
                        const ZN44StaticHeader *h=(const ZN44StaticHeader *)data;
                        if(h->magic0!=ZN44_STATIC_MAGIC0 || h->magic1!=ZN44_STATIC_MAGIC1 ||
                           h->version!=ZN44_STATIC_VERSION_V2 || h->entrySize!=sizeof(ZN44StaticEntry) ||
                           h->count>ZN44_STATIC_MAX_ENTRIES ||
                           h->count>(sect->size-sizeof(*h))/sizeof(ZN44StaticEntry))continue;
                        const ZN44StaticEntry *entries=(const ZN44StaticEntry *)(h+1);
                        for(uint32_t n=0;n<h->count;n++){
                            const ZN44StaticEntry *e=&entries[n];
                            NSString *key=[NSString stringWithFormat:@"static:%u:%u",imageIndex,e->patchID];
                            if([keys containsObject:key])continue;
                            [keys addObject:key];
                            NSString *title=ZNText(e->title,sizeof(e->title));
                            [result addObject:ZNItem(key,title,ZNText(e->group,sizeof(e->group)),ZNCustomerControlSwitch)];
                        }
                        uint64_t actionOffset=0;
                        if(!ZNGeneratedDataLayoutV1LocateRuntimeAction(data,sect->size,&actionOffset))continue;
                        if(actionOffset>sect->size || sect->size-actionOffset<sizeof(ZNRuntimeActionHeader))continue;
                        const uint8_t *actionData=data+actionOffset;
                        const ZNRuntimeActionHeader *a=(const ZNRuntimeActionHeader *)actionData;
                        if(a->magic!=ZN_RUNTIME_ACTION_MAGIC || a->version!=ZN_RUNTIME_ACTION_VERSION ||
                           a->entrySize!=sizeof(ZNRuntimeMethodCallEntry) || a->count>ZN_RUNTIME_ACTION_MAX_ENTRIES ||
                           a->totalSize>sect->size-actionOffset || a->totalSize<sizeof(*a) ||
                           a->count>(a->totalSize-sizeof(*a))/sizeof(ZNRuntimeMethodCallEntry) ||
                           a->stringPoolOffset<a->count*sizeof(ZNRuntimeMethodCallEntry)+sizeof(*a) ||
                           a->stringPoolOffset>a->totalSize || a->stringPoolSize>a->totalSize-a->stringPoolOffset)continue;
                        const ZNRuntimeMethodCallEntry *actions=(const ZNRuntimeMethodCallEntry *)(a+1);
                        for(uint32_t n=0;n<a->count;n++){
                            const ZNRuntimeMethodCallEntry *e=&actions[n];
                            if(e->kind!=ZNRuntimeActionKindIL2CPPMethodCall &&
                               e->kind!=ZNRuntimeActionKindIL2CPPNativeHook &&
                               e->kind!=ZNRuntimeActionKindDirectNativeCall)continue;
                            NSString *key=[NSString stringWithFormat:@"action:%u:%u:%u",imageIndex,e->kind,e->actionID];
                            if([keys containsObject:key])continue;
                            [keys addObject:key];
                            NSString *title=ZNPoolText(actionData,a,e->titleOffset);
                            NSString *group=ZNPoolText(actionData,a,e->groupOffset);
                            ZNCustomerControlKind kind=e->kind==ZNRuntimeActionKindIL2CPPNativeHook?
                                ZNCustomerControlSwitch:ZNCustomerControlButton;
                            [result addObject:ZNItem(key,title,group,kind)];
                        }
                    }
                }
            }
            cmd+=lc->cmdsize;
        }
    }
    return result;
}
@end
