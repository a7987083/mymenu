#import "ZNSharedSiteExecutionProbeV3.h"
#import "ZNPatchCore.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <stdlib.h>
#import <string.h>

static NSString * const kZNSSP3LogName = @"ZonoePatch_SharedSiteProbe.log";

typedef struct {
    Class owner;
    SEL sel;
    IMP original;
    unsigned stage;
    char image[256];
    uintptr_t rva;
} ZNSSP3DynamicApplyHook;

typedef struct {
    Class owner;
    SEL sel;
    IMP original;
    char image[256];
    uintptr_t rva;
} ZNSSP3NativeHookAPI;

typedef struct {
    const struct mach_header_64 *header;
    intptr_t slide;
    uintptr_t base;
    uintptr_t textStart;
    uintptr_t textEnd;
    char path[1024];
    char image[256];
} ZNSSP3ImageInfo;

static ZNSSP3DynamicApplyHook gApplyHooks[64];
static unsigned gApplyHookCount;
static ZNSSP3NativeHookAPI gNativeHooks[32];
static unsigned gNativeHookCount;
static unsigned gDescriptorSecretCount;
static unsigned gStaticNativeCandidateCount;
static unsigned gStaticNativeRecoveredCount;
static BOOL gInstalled;
static char gAnchorImage[256];
static __thread unsigned gFeatureDepth;
static __thread char gCurrentIdentifier[96];
static __thread BOOL gCurrentRequested;
static char gLastIdentifier[96];

static NSString *ZNSSP3LogPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:kZNSSP3LogName];
}

static void ZNSSP3Log(NSString *line) {
    if (!line.length) return;
    @synchronized (NSFileManager.class) {
        NSString *path=ZNSSP3LogPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSData data] writeToFile:path atomically:YES];
        NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    [[ZNRuntimeLogger sharedLogger] log:line];
}

static BOOL ZNSSP3Readable(uintptr_t address, size_t length) {
    if (!address || !length) return NO;
    mach_vm_address_t region=(mach_vm_address_t)address;
    mach_vm_size_t regionSize=0;
    vm_region_basic_info_data_64_t info={0};
    mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object=0;
    kern_return_t kr=mach_vm_region(mach_task_self(),&region,&regionSize,VM_REGION_BASIC_INFO_64,
                                    (vm_region_info_t)&info,&count,&object);
    if (kr!=KERN_SUCCESS || !(info.protection & VM_PROT_READ)) return NO;
    uintptr_t end=address+length;
    return region<=address && end>=address && end<=region+(uintptr_t)regionSize;
}

static NSString *ZNSSP3Hex(uintptr_t address, size_t length) {
    if (!ZNSSP3Readable(address,length)) return @"?";
    const uint8_t *bytes=(const uint8_t *)address;
    NSMutableString *s=[NSMutableString stringWithCapacity:length*2];
    for (size_t i=0;i<length;i++) [s appendFormat:@"%02X",bytes[i]];
    return s;
}

static const char *ZNSSP3Base(const char *path) {
    if (!path) return "?";
    const char *slash=strrchr(path,'/');
    return slash?slash+1:path;
}

static void ZNSSP3Describe(uintptr_t value, char *image, size_t cap, uintptr_t *rva) {
    if (image&&cap) image[0]=0;
    if (rva) *rva=0;
    if (!value) return;
    Dl_info info={0};
    if (!dladdr((void *)value,&info) || !info.dli_fbase) return;
    if (image&&cap) snprintf(image,cap,"%s",ZNSSP3Base(info.dli_fname));
    if (rva) *rva=value-(uintptr_t)info.dli_fbase;
}

static NSString *ZNSSP3StringValue(id obj, NSString *key) {
    if (!obj || !key.length) return @"";
    @try {
        id value=[obj valueForKey:key];
        if ([value isKindOfClass:NSString.class]) return value;
        if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue]?:@"";
        return value?[value description]:@"";
    } @catch (__unused NSException *e) { return @""; }
}

static const char *ZNSSP3FeatureIdentifier(id object) {
    static __thread char value[96];
    value[0]=0;
    NSString *identifier=ZNSSP3StringValue(object,@"identifier");
    NSString *key=ZNSSP3StringValue(object,@"HlkuHDyxft");
    NSString *source=identifier.length?identifier:key;
    if ([source hasSuffix:@"-switch"]) source=[source substringToIndex:source.length-7];
    if (source.length) snprintf(value,sizeof(value),"%s",source.UTF8String);
    return value[0]?value:"?";
}

static uintptr_t ZNSSP3SecretPointer(id wrapper) {
    if (!wrapper) return 0;
    SEL secret=sel_registerName("secret");
    if (![wrapper respondsToSelector:secret]) return 0;
    return ((uintptr_t(*)(id,SEL))objc_msgSend)(wrapper,secret);
}

static void ZNSSP3LogSecretCandidate(id owner, const char *field, id value) {
    if (!value || ![value respondsToSelector:sel_registerName("secret")]) return;
    Method getter=class_getInstanceMethod([value class],sel_registerName("secret"));
    if (!getter) getter=class_getInstanceMethod(object_getClass(value),sel_registerName("secret"));
    IMP imp=getter?method_getImplementation(getter):NULL;
    char image[256]={0}; uintptr_t getterRVA=0;
    ZNSSP3Describe((uintptr_t)imp,image,sizeof(image),&getterRVA);
    uintptr_t secret=ZNSSP3SecretPointer(value);
    gDescriptorSecretCount++;
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-DESCRIPTOR-SECRET] owner=%p ownerClass=%@ field=%s wrapper=%p wrapperClass=%@ getterImage=%s getterRVA=0x%llX secret=%p secretBytes=%@",
               owner,NSStringFromClass([owner class])?:@"?",field?field:"?",value,
               NSStringFromClass([value class])?:@"?",image[0]?image:"?",
               (unsigned long long)getterRVA,(void *)secret,ZNSSP3Hex(secret,16)]);
}

static void ZNSSP3CaptureObjectSecrets(id object) {
    if (!object) return;
    for (Class cls=[object class]; cls && cls!=NSObject.class; cls=class_getSuperclass(cls)) {
        unsigned count=0;
        Ivar *ivars=class_copyIvarList(cls,&count);
        for (unsigned i=0;ivars&&i<count;i++) {
            Ivar iv=ivars[i];
            const char *type=ivar_getTypeEncoding(iv);
            if (!type || type[0]!='@') continue;
            id value=object_getIvar(object,iv);
            const char *name=ivar_getName(iv);
            ZNSSP3LogSecretCandidate(object,name,value);
            if ([value isKindOfClass:NSArray.class]) {
                NSUInteger n=MIN((NSUInteger)16,[(NSArray *)value count]);
                for (NSUInteger j=0;j<n;j++) ZNSSP3LogSecretCandidate(object,[[NSString stringWithFormat:@"%s[%lu]",name?name:"?",(unsigned long)j] UTF8String],[(NSArray *)value objectAtIndex:j]);
            } else if ([value isKindOfClass:NSDictionary.class]) {
                NSUInteger n=0;
                for (id key in (NSDictionary *)value) {
                    if (n++>=16) break;
                    id v=[(NSDictionary *)value objectForKey:key];
                    NSString *field=[NSString stringWithFormat:@"%s[%@]",name?name:"?",key];
                    ZNSSP3LogSecretCandidate(object,field.UTF8String,v);
                }
            }
        }
        free(ivars);
    }
}

static const char *ZNSSP3SkipQualifiers(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV",*type)) type++;
    return type;
}

static ZNSSP3DynamicApplyHook *ZNSSP3ApplyHookFor(Class owner, SEL sel) {
    for (Class cls=owner;cls;cls=class_getSuperclass(cls)) {
        for (unsigned i=0;i<gApplyHookCount;i++) if (gApplyHooks[i].owner==cls && gApplyHooks[i].sel==sel) return &gApplyHooks[i];
    }
    return NULL;
}

static int ZNSSP3ApplyStage(Method method) {
    if (!method || method_getNumberOfArguments(method)!=6) return 0;
    char ret[32]={0},a1[32]={0},a2[32]={0},a3[32]={0},a4[32]={0};
    method_getReturnType(method,ret,sizeof(ret));
    method_getArgumentType(method,2,a1,sizeof(a1));
    method_getArgumentType(method,3,a2,sizeof(a2));
    method_getArgumentType(method,4,a3,sizeof(a3));
    method_getArgumentType(method,5,a4,sizeof(a4));
    const char *r=ZNSSP3SkipQualifiers(ret),*t1=ZNSSP3SkipQualifiers(a1),*t2=ZNSSP3SkipQualifiers(a2),*t3=ZNSSP3SkipQualifiers(a3),*t4=ZNSSP3SkipQualifiers(a4);
    if (*r!='v' || (*t1!='B'&&*t1!='c') || strcmp(t4,"^^v")!=0) return 0;
    if ((*t2=='q'||*t2=='Q'||*t2=='i'||*t2=='I') && strcmp(t3,"^v")==0) return 1;
    if (strcmp(t2,"^v")==0 && strcmp(t3,"^v")==0) return 2;
    return 0;
}

static const char *ZNSSP3CurrentIdentifier(void) {
    if (gCurrentIdentifier[0]) return gCurrentIdentifier;
    if (gLastIdentifier[0]) return gLastIdentifier;
    return "?";
}

static void ZNSSP3ApplyOffset(id self, SEL _cmd, BOOL enabled, long long q, void *target, void **context) {
    ZNSSP3DynamicApplyHook *hook=ZNSSP3ApplyHookFor(object_getClass(self),_cmd);
    if (!hook||!hook->original) return;
    uintptr_t contextValue=(context&&ZNSSP3Readable((uintptr_t)context,sizeof(void *)))?(uintptr_t)*context:0;
    const char *identifier=ZNSSP3CurrentIdentifier();
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-DYNAMIC-APPLY] phase=begin stage=offset identifier=%s enabled=%u q=%lld qHex=0x%llX class=%s selector=%s image=%s rva=0x%llX target=%p targetBytes=%@ context=%p contextValue=%p contextBytes=%@",
               identifier,enabled?1:0,q,(unsigned long long)q,class_getName((Class)self),sel_getName(_cmd),hook->image,
               (unsigned long long)hook->rva,target,ZNSSP3Hex((uintptr_t)target,16),context,(void *)contextValue,ZNSSP3Hex(contextValue,16)]);
    ((void(*)(id,SEL,BOOL,long long,void *,void **))hook->original)(self,_cmd,enabled,q,target,context);
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-DYNAMIC-APPLY] phase=end stage=offset identifier=%s enabled=%u q=0x%llX target=%p context=%p",
               identifier,enabled?1:0,(unsigned long long)q,target,context]);
}

static void ZNSSP3ApplyResolved(id self, SEL _cmd, BOOL enabled, void *resolvedAddress, void *target, void **context) {
    ZNSSP3DynamicApplyHook *hook=ZNSSP3ApplyHookFor(object_getClass(self),_cmd);
    if (!hook||!hook->original) return;
    const char *identifier=ZNSSP3CurrentIdentifier();
    uintptr_t resolved=(uintptr_t)resolvedAddress;
    char resolvedImage[256]={0}; uintptr_t resolvedRVA=0;
    ZNSSP3Describe(resolved,resolvedImage,sizeof(resolvedImage),&resolvedRVA);
    NSString *before=ZNSSP3Hex(resolved,32);
    uintptr_t contextValue=(context&&ZNSSP3Readable((uintptr_t)context,sizeof(void *)))?(uintptr_t)*context:0;
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-DYNAMIC-APPLY] phase=begin stage=resolved identifier=%s enabled=%u class=%s selector=%s image=%s rva=0x%llX resolved=%p resolvedImage=%s resolvedRVA=0x%llX before=%@ target=%p targetBytes=%@ context=%p contextValue=%p contextBytes=%@",
               identifier,enabled?1:0,class_getName((Class)self),sel_getName(_cmd),hook->image,(unsigned long long)hook->rva,
               resolvedAddress,resolvedImage[0]?resolvedImage:"?",(unsigned long long)resolvedRVA,before,target,ZNSSP3Hex((uintptr_t)target,16),context,(void *)contextValue,ZNSSP3Hex(contextValue,16)]);
    ((void(*)(id,SEL,BOOL,void *,void *,void **))hook->original)(self,_cmd,enabled,resolvedAddress,target,context);
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-DYNAMIC-APPLY] phase=end stage=resolved identifier=%s enabled=%u resolved=%p resolvedImage=%s resolvedRVA=0x%llX after=%@",
               identifier,enabled?1:0,resolvedAddress,resolvedImage[0]?resolvedImage:"?",(unsigned long long)resolvedRVA,ZNSSP3Hex(resolved,32)]);
}

static unsigned ZNSSP3InstallDynamicApplyHooks(const char *image) {
    if (!image||!*image) return 0;
    int classCount=objc_getClassList(NULL,0);
    if (classCount<=0) return 0;
    Class *classes=(Class *)calloc((size_t)classCount,sizeof(Class));
    if (!classes) return 0;
    classCount=objc_getClassList(classes,classCount);
    unsigned candidates=0,installed=0;
    for (int ci=0;ci<classCount&&gApplyHookCount<64;ci++) {
        Class cls=classes[ci];
        if (!cls) continue;
        Class meta=object_getClass(cls);
        unsigned count=0;
        Method *methods=meta?class_copyMethodList(meta,&count):NULL;
        for (unsigned mi=0;methods&&mi<count&&gApplyHookCount<64;mi++) {
            Method method=methods[mi];
            int stage=ZNSSP3ApplyStage(method);
            if (!stage) continue;
            IMP imp=method_getImplementation(method);
            Dl_info info={0};
            if (!imp||!dladdr((void *)imp,&info)||!info.dli_fname||strcmp(ZNSSP3Base(info.dli_fname),image)!=0) continue;
            candidates++;
            SEL sel=method_getName(method);
            if (!sel||ZNSSP3ApplyHookFor(meta,sel)) continue;
            ZNSSP3DynamicApplyHook *hook=&gApplyHooks[gApplyHookCount++];
            memset(hook,0,sizeof(*hook));
            hook->owner=meta; hook->sel=sel; hook->original=imp; hook->stage=(unsigned)stage;
            hook->rva=(uintptr_t)imp-(uintptr_t)info.dli_fbase; snprintf(hook->image,sizeof(hook->image),"%s",image);
            method_setImplementation(method,stage==1?(IMP)ZNSSP3ApplyOffset:(IMP)ZNSSP3ApplyResolved);
            installed++;
            ZNSSP3Log([NSString stringWithFormat:@"[SSP3-DYNAMIC-APPLY-HOOK] image=%s class=%s selector=%s stage=%s rva=0x%llX installed=1",
                       image,class_getName(cls),sel_getName(sel),stage==1?"offset":"resolved",(unsigned long long)hook->rva]);
        }
        free(methods);
    }
    free(classes);
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-DYNAMIC-APPLY-SCAN] image=%s classes=%d candidates=%u installed=%u",image,classCount,candidates,installed]);
    return installed;
}

static ZNSSP3NativeHookAPI *ZNSSP3NativeHookFor(Class owner, SEL sel) {
    for (Class cls=owner;cls;cls=class_getSuperclass(cls)) {
        for (unsigned i=0;i<gNativeHookCount;i++) if (gNativeHooks[i].owner==cls&&gNativeHooks[i].sel==sel) return &gNativeHooks[i];
    }
    return NULL;
}

static BOOL ZNSSP3TypeObject(const char *type) { return *ZNSSP3SkipQualifiers(type)=='@'; }
static BOOL ZNSSP3TypeVoidPtr(const char *type) { return strcmp(ZNSSP3SkipQualifiers(type),"^v")==0; }
static BOOL ZNSSP3TypeVoidPtrPtr(const char *type) { return strcmp(ZNSSP3SkipQualifiers(type),"^^v")==0; }

static void ZNSSP3NativeHookWrapper(id self, SEL _cmd, id targetWrapper, void *replacement, void **originalOut) {
    ZNSSP3NativeHookAPI *hook=ZNSSP3NativeHookFor(object_getClass(self),_cmd);
    if (!hook||!hook->original) return;
    uintptr_t secret=ZNSSP3SecretPointer(targetWrapper);
    char replacementImage[256]={0}; uintptr_t replacementRVA=0;
    ZNSSP3Describe((uintptr_t)replacement,replacementImage,sizeof(replacementImage),&replacementRVA);
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-NATIVE-HOOK-REGISTER] phase=begin class=%s selector=%s apiImage=%s apiRVA=0x%llX wrapper=%p wrapperClass=%@ secret=%p secretBytes=%@ replacement=%p replacementImage=%s replacementRVA=0x%llX originalSlot=%p",
               class_getName(object_getClass(self)),sel_getName(_cmd),hook->image,(unsigned long long)hook->rva,
               targetWrapper,NSStringFromClass([targetWrapper class])?:@"?",(void *)secret,ZNSSP3Hex(secret,16),replacement,
               replacementImage[0]?replacementImage:"?",(unsigned long long)replacementRVA,originalOut]);
    ((void(*)(id,SEL,id,void *,void **))hook->original)(self,_cmd,targetWrapper,replacement,originalOut);
    uintptr_t original=(originalOut&&ZNSSP3Readable((uintptr_t)originalOut,sizeof(void *)))?(uintptr_t)*originalOut:0;
    char originalImage[256]={0}; uintptr_t originalRVA=0;
    ZNSSP3Describe(original,originalImage,sizeof(originalImage),&originalRVA);
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-NATIVE-HOOK-REGISTER] phase=end original=%p originalImage=%s originalRVA=0x%llX",
               (void *)original,originalImage[0]?originalImage:"?",(unsigned long long)originalRVA]);
}

static unsigned ZNSSP3InstallNativeHookAPIsOnOwner(Class owner, const char *image) {
    if (!owner||!image||!*image) return 0;
    unsigned count=0,installed=0;
    Method *methods=class_copyMethodList(owner,&count);
    for (unsigned i=0;methods&&i<count&&gNativeHookCount<32;i++) {
        Method method=methods[i];
        if (method_getNumberOfArguments(method)!=5) continue;
        char ret[16]={0},a2[32]={0},a3[32]={0},a4[32]={0};
        method_getReturnType(method,ret,sizeof(ret)); method_getArgumentType(method,2,a2,sizeof(a2));
        method_getArgumentType(method,3,a3,sizeof(a3)); method_getArgumentType(method,4,a4,sizeof(a4));
        if (*ZNSSP3SkipQualifiers(ret)!='v'||!ZNSSP3TypeObject(a2)||!ZNSSP3TypeVoidPtr(a3)||!ZNSSP3TypeVoidPtrPtr(a4)) continue;
        IMP imp=method_getImplementation(method); Dl_info info={0};
        if (!imp||!dladdr((void *)imp,&info)||!info.dli_fname||strcmp(ZNSSP3Base(info.dli_fname),image)!=0) continue;
        SEL sel=method_getName(method);
        if (!sel||ZNSSP3NativeHookFor(owner,sel)) continue;
        ZNSSP3NativeHookAPI *hook=&gNativeHooks[gNativeHookCount++];
        memset(hook,0,sizeof(*hook)); hook->owner=owner; hook->sel=sel; hook->original=imp;
        hook->rva=(uintptr_t)imp-(uintptr_t)info.dli_fbase; snprintf(hook->image,sizeof(hook->image),"%s",image);
        method_setImplementation(method,(IMP)ZNSSP3NativeHookWrapper);
        installed++;
        ZNSSP3Log([NSString stringWithFormat:@"[SSP3-NATIVE-HOOK-API] image=%s owner=%s selector=%s rva=0x%llX installed=1",
                   image,class_getName(owner),sel_getName(sel),(unsigned long long)hook->rva]);
    }
    free(methods);
    return installed;
}

static unsigned ZNSSP3InstallNativeHookAPIs(const char *image) {
    int classCount=objc_getClassList(NULL,0);
    if (classCount<=0) return 0;
    Class *classes=(Class *)calloc((size_t)classCount,sizeof(Class));
    if (!classes) return 0;
    classCount=objc_getClassList(classes,classCount);
    unsigned installed=0;
    for (int i=0;i<classCount&&gNativeHookCount<32;i++) {
        Class cls=classes[i]; if (!cls) continue;
        installed+=ZNSSP3InstallNativeHookAPIsOnOwner(cls,image);
        Class meta=object_getClass(cls); if (meta) installed+=ZNSSP3InstallNativeHookAPIsOnOwner(meta,image);
    }
    free(classes);
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-NATIVE-HOOK-SCAN] image=%s classes=%d installed=%u",image,classCount,installed]);
    return installed;
}

static int64_t ZNSSP3SignExtend(uint64_t value, unsigned bits) {
    return (int64_t)(value << (64u-bits)) >> (64u-bits);
}

static uintptr_t ZNSSP3ADR(uintptr_t pc, uint32_t word, unsigned reg) {
    if ((word&0x9F000000u)!=0x10000000u||(word&31u)!=reg) return 0;
    uint64_t imm=(((uint64_t)(word>>5)&0x7FFFFu)<<2)|((word>>29)&3u);
    return (uintptr_t)((intptr_t)pc+ZNSSP3SignExtend(imm,21));
}

static uintptr_t ZNSSP3ADRP(uintptr_t pc, uint32_t word, unsigned reg) {
    if ((word&0x9F000000u)!=0x90000000u||(word&31u)!=reg) return 0;
    uint64_t imm=(((uint64_t)(word>>5)&0x7FFFFu)<<2)|((word>>29)&3u);
    return (uintptr_t)((intptr_t)(pc&~(uintptr_t)0xFFFu)+(ZNSSP3SignExtend(imm,21)<<12));
}

static BOOL ZNSSP3ADDX4(uint32_t word, uintptr_t *offset) {
    if ((word&0xFF000000u)!=0x91000000u||(word&31u)!=4u||((word>>5)&31u)!=4u) return NO;
    uintptr_t imm=(uintptr_t)((word>>10)&0xFFFu); if ((word>>22)&1u) imm<<=12;
    if (offset) *offset=imm; return YES;
}

static BOOL ZNSSP3LooksLikeIntSecret(uintptr_t address, uint32_t *lenOut, uint32_t *flagsOut) {
    if (!ZNSSP3Readable(address,8)) return NO;
    uint32_t len=0,flags=0; memcpy(&len,(void *)address,4); memcpy(&flags,(void *)(address+4),4);
    if (!len||len>0x100u||(flags>>24)!=2u||((flags>>16)&0xFFu)!=3u) return NO;
    size_t blob=(size_t)(len&~0xFu)+0x28u; if (blob<0x28u||blob>0x200u||!ZNSSP3Readable(address,blob)) return NO;
    if (lenOut) *lenOut=len; if (flagsOut) *flagsOut=flags; return YES;
}

static BOOL ZNSSP3ImageForName(const char *image, ZNSSP3ImageInfo *outInfo) {
    if (!image||!*image||!outInfo) return NO;
    uint32_t count=_dyld_image_count();
    for (uint32_t i=0;i<count;i++) {
        const char *path=_dyld_get_image_name(i); const struct mach_header *mh=_dyld_get_image_header(i);
        if (!path||!mh||strcmp(ZNSSP3Base(path),image)!=0||mh->magic!=MH_MAGIC_64) continue;
        ZNSSP3ImageInfo info={0}; info.header=(const struct mach_header_64 *)mh; info.slide=_dyld_get_image_vmaddr_slide(i); info.base=(uintptr_t)mh;
        strlcpy(info.path,path,sizeof(info.path)); snprintf(info.image,sizeof(info.image),"%s",image);
        const uint8_t *cursor=(const uint8_t *)(info.header+1);
        for (uint32_t c=0;c<info.header->ncmds;c++) {
            const struct load_command *lc=(const struct load_command *)cursor;
            if (!lc->cmdsize) break;
            if (lc->cmd==LC_SEGMENT_64) {
                const struct segment_command_64 *seg=(const struct segment_command_64 *)cursor;
                const struct section_64 *sec=(const struct section_64 *)(seg+1);
                for (uint32_t j=0;j<seg->nsects;j++,sec++) if (strncmp(sec->sectname,"__text",16)==0) {
                    info.textStart=(uintptr_t)(sec->addr+info.slide); info.textEnd=info.textStart+(uintptr_t)sec->size;
                }
            }
            cursor+=lc->cmdsize;
        }
        if (!info.textStart||info.textEnd<=info.textStart) return NO;
        *outInfo=info; return YES;
    }
    return NO;
}

static unsigned ZNSSP3RecoverStaticNativeHooks(const char *image) {
    ZNSSP3ImageInfo info={0};
    if (!ZNSSP3ImageForName(image,&info)) {
        ZNSSP3Log([NSString stringWithFormat:@"[SSP3-STATIC-NATIVE-SCAN] image=%s status=NO_TEXT",image]);
        return 0;
    }
    unsigned recovered=0;
    for (uintptr_t pc=info.textStart;pc+4<=info.textEnd;pc+=4) {
        uint32_t word=0; if (!ZNSSP3Readable(pc,4)) break; memcpy(&word,(void *)pc,4);
        uintptr_t secret=ZNSSP3ADR(pc,word,2); uint32_t len=0,flags=0;
        if (!secret||!ZNSSP3LooksLikeIntSecret(secret,&len,&flags)) continue;
        uintptr_t replacement=0,adr3PC=0;
        for (uintptr_t p=pc+4;p<pc+0x50u&&p+4<=info.textEnd;p+=4) {
            uint32_t w=0; memcpy(&w,(void *)p,4); uintptr_t candidate=ZNSSP3ADR(p,w,3);
            if (candidate>=info.textStart&&candidate<info.textEnd) { replacement=candidate; adr3PC=p; break; }
        }
        if (!replacement) continue;
        uintptr_t slot=0,addPC=0;
        for (uintptr_t p=adr3PC+4;p<adr3PC+0x30u&&p+4<=info.textEnd;p+=4) {
            uint32_t w=0; memcpy(&w,(void *)p,4); uintptr_t page=ZNSSP3ADRP(p,w,4); if (!page) continue;
            for (uintptr_t q=p+4;q<p+0x10u&&q+4<=info.textEnd;q+=4) {
                uint32_t aw=0; memcpy(&aw,(void *)q,4); uintptr_t add=0;
                if (ZNSSP3ADDX4(aw,&add)) { slot=page+add; addPC=q; break; }
            }
            if (slot) break;
        }
        if (!slot||!ZNSSP3Readable(slot,sizeof(uintptr_t))) continue;
        uintptr_t callsite=0;
        for (uintptr_t p=addPC+4;p<addPC+0x20u&&p+4<=info.textEnd;p+=4) {
            uint32_t w=0; memcpy(&w,(void *)p,4); if ((w&0xFC000000u)==0x94000000u) { callsite=p; break; }
        }
        if (!callsite) continue;
        gStaticNativeCandidateCount++;
        uintptr_t original=0; memcpy(&original,(void *)slot,sizeof(original));
        char replacementImage[256]={0},slotImage[256]={0},originalImage[256]={0};
        uintptr_t replacementRVA=0,slotRVA=0,originalRVA=0;
        ZNSSP3Describe(replacement,replacementImage,sizeof(replacementImage),&replacementRVA);
        ZNSSP3Describe(slot,slotImage,sizeof(slotImage),&slotRVA); ZNSSP3Describe(original,originalImage,sizeof(originalImage),&originalRVA);
        ZNSSP3Log([NSString stringWithFormat:@"[SSP3-STATIC-NATIVE-HOOK] image=%s callsiteRVA=0x%llX secretRVA=0x%llX len=%u flags=%08X replacement=%p replacementImage=%s replacementRVA=0x%llX slot=%p slotImage=%s slotRVA=0x%llX original=%p originalImage=%s originalRVA=0x%llX",
                   image,(unsigned long long)(callsite-info.base),(unsigned long long)(secret-info.base),len,flags,(void *)replacement,
                   replacementImage[0]?replacementImage:"?",(unsigned long long)replacementRVA,(void *)slot,slotImage[0]?slotImage:"?",
                   (unsigned long long)slotRVA,(void *)original,originalImage[0]?originalImage:"?",(unsigned long long)originalRVA]);
        recovered++; gStaticNativeRecoveredCount++;
    }
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-STATIC-NATIVE-SCAN] image=%s candidates=%u recovered=%u",image,gStaticNativeCandidateCount,recovered]);
    return recovered;
}

void ZNSSPV3InstallExecutionProbes(IMP anchorIMP) {
    if (gInstalled) return;
    Dl_info info={0};
    if (!anchorIMP||!dladdr((void *)anchorIMP,&info)||!info.dli_fname) {
        ZNSSP3Log(@"[SSP3-INSTALL] status=NO_ANCHOR_IMAGE");
        return;
    }
    snprintf(gAnchorImage,sizeof(gAnchorImage),"%s",ZNSSP3Base(info.dli_fname));
    gInstalled=YES;
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-INSTALL] image=%s anchorIMP=%p",gAnchorImage,anchorIMP]);
    ZNSSP3InstallDynamicApplyHooks(gAnchorImage);
    ZNSSP3InstallNativeHookAPIs(gAnchorImage);
    ZNSSP3RecoverStaticNativeHooks(gAnchorImage);
}

void ZNSSPV3FeatureBegin(id object, BOOL active) {
    const char *identifier=ZNSSP3FeatureIdentifier(object);
    if (gFeatureDepth++==0) {
        snprintf(gCurrentIdentifier,sizeof(gCurrentIdentifier),"%s",identifier);
        snprintf(gLastIdentifier,sizeof(gLastIdentifier),"%s",identifier);
        gCurrentRequested=active;
    }
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-FEATURE] phase=begin identifier=%s requested=%u object=%p class=%@ depth=%u",
               identifier,active?1:0,object,NSStringFromClass([object class])?:@"?",gFeatureDepth]);
    ZNSSP3CaptureObjectSecrets(object);
}

void ZNSSPV3FeatureEnd(id object, BOOL active) {
    const char *identifier=ZNSSP3FeatureIdentifier(object);
    ZNSSP3Log([NSString stringWithFormat:@"[SSP3-FEATURE] phase=end identifier=%s requested=%u object=%p class=%@ depth=%u",
               identifier,active?1:0,object,NSStringFromClass([object class])?:@"?",gFeatureDepth]);
    if (gFeatureDepth&&--gFeatureDepth==0) {
        gCurrentIdentifier[0]=0;
        gCurrentRequested=NO;
    }
}

NSArray<NSString *> *ZNSSPV3DiagnosticLines(void) {
    return @[
        [NSString stringWithFormat:@"Execution Probe v3：%@ · Image：%s",gInstalled?@"Installed":@"Not installed",gAnchorImage[0]?gAnchorImage:"?"],
        [NSString stringWithFormat:@"Descriptor Secret：%u · Dynamic Apply Hooks：%u",gDescriptorSecretCount,gApplyHookCount],
        [NSString stringWithFormat:@"Native Hook APIs：%u · Static Native：%u/%u",gNativeHookCount,gStaticNativeRecoveredCount,gStaticNativeCandidateCount],
        [NSString stringWithFormat:@"Last Feature：%s",gLastIdentifier[0]?gLastIdentifier:"?"]
    ];
}
