#import "ZNSharedSiteProbe.h"
#import "ZNPatchCore.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <stdlib.h>
#import <string.h>

static const uint64_t kZNSSPPostersOnlyRVA  = 0x2E1BCA0ULL;
static const uint64_t kZNSSPSharedRVA       = 0x2E25904ULL;
static const uint64_t kZNSSPPrestigeOnlyRVA = 0x2E257E4ULL;
static NSString * const kZNSSPModule = @"UnityFramework";
static NSString * const kZNSSPExactClassName = @"MdhpNuX";

typedef void (*ZNSSPSetActiveIMP)(id, SEL, BOOL);
static ZNSSPSetActiveIMP gZNSSPOriginalSetActive = NULL;
static IMP gZNSSPReplacementIMP = NULL;

typedef struct {
    const struct mach_header_64 *header;
    intptr_t slide;
    uintptr_t imageBase;
    uintptr_t textStart;
    uintptr_t textEnd;
    uint64_t textVM;
    uint64_t linkVM;
    uint64_t linkFile;
    const struct linkedit_data_command *functionStarts;
    char path[1024];
} ZNSSPImageInfo;

@interface ZNSharedSiteProbe ()
@property(nonatomic,assign,readwrite,getter=isInstalled) BOOL installed;
@property(nonatomic,assign,readwrite,getter=isLoggingEnabled) BOOL loggingEnabled;
@property(nonatomic,copy,readwrite) NSString *targetClassName;
@property(nonatomic,copy,readwrite) NSString *lastStatus;
@property(nonatomic,copy,readwrite) NSString *logPath;
@property(nonatomic,assign) BOOL arming;
@property(nonatomic,assign) NSUInteger armToken;
@property(nonatomic,strong) NSMutableSet<NSString *> *bootstrapKeys;
@property(nonatomic,copy) NSString *bootstrapStatus;
- (void)recordObject:(id)obj requestedActive:(BOOL)active phase:(NSString *)phase;
- (NSString *)siteSnapshot;
- (void)appendLine:(NSString *)line;
- (BOOL)installOnClass:(Class)cls error:(NSString **)error;
- (void)retryInstallToken:(NSUInteger)token remaining:(NSUInteger)remaining;
- (void)probeBootstrapRootForObject:(id)obj;
@end

@implementation ZNSharedSiteProbe

+ (instancetype)sharedProbe {
    static ZNSharedSiteProbe *probe;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ probe=[ZNSharedSiteProbe new]; });
    return probe;
}

- (instancetype)init {
    if ((self=[super init])) {
        NSString *documents=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        _logPath=[documents stringByAppendingPathComponent:@"ZonoePatch_SharedSiteProbe.log"];
        _targetClassName=@"未安装";
        _lastStatus=@"等待启用 Probe";
        _bootstrapStatus=@"未观察";
        _bootstrapKeys=[NSMutableSet set];
    }
    return self;
}

static id ZNSSPValue(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *ZNSSPStringValue(id obj, NSString *key) {
    id value=ZNSSPValue(obj,key);
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue] ?: @"";
    return value ? [value description] : @"";
}

static BOOL ZNSSPHasSelector(Class cls, SEL sel) {
    return cls && class_getInstanceMethod(cls,sel) != NULL;
}

static BOOL ZNSSPClassLooksLikePatchObject(Class cls) {
    if (!cls) return NO;
    return ZNSSPHasSelector(cls,@selector(setActive:)) &&
           ZNSSPHasSelector(cls,@selector(identifier)) &&
           ZNSSPHasSelector(cls,@selector(address));
}

static NSString *ZNSSPIMPImage(Method method) {
    if (!method) return @"";
    Dl_info info={0};
    IMP imp=method_getImplementation(method);
    if (!imp || !dladdr((const void *)imp,&info) || !info.dli_fname) return @"";
    return [[NSString stringWithUTF8String:info.dli_fname] lastPathComponent] ?: @"";
}

static Class ZNSSPFindTargetClass(NSString **detail) {
    Class exact=objc_lookUpClass(kZNSSPExactClassName.UTF8String);
    if (!exact) exact=NSClassFromString(kZNSSPExactClassName);
    if (exact && ZNSSPHasSelector(exact,@selector(setActive:))) {
        if (detail) {
            Method m=class_getInstanceMethod(exact,@selector(setActive:));
            *detail=[NSString stringWithFormat:@"exact=%@ setActive=YES identifier=%@ address=%@ impImage=%@",
                     NSStringFromClass(exact) ?: @"?",
                     ZNSSPHasSelector(exact,@selector(identifier))?@"YES":@"NO",
                     ZNSSPHasSelector(exact,@selector(address))?@"YES":@"NO",
                     ZNSSPIMPImage(m).length?ZNSSPIMPImage(m):@"?"];
        }
        return exact;
    }

    int count=objc_getClassList(NULL,0);
    if (count<=0) {
        if (detail) *detail=@"objc_getClassList returned 0";
        return Nil;
    }
    Class *classes=(Class *)calloc((size_t)count,sizeof(Class));
    if (!classes) {
        if (detail) *detail=@"class buffer allocation failed";
        return Nil;
    }
    count=objc_getClassList(classes,count);

    Class namedFallback=Nil;
    Class imageFallback=Nil;
    NSString *imageFallbackName=@"";
    for (int i=0;i<count;i++) {
        Class cls=classes[i];
        NSString *name=NSStringFromClass(cls) ?: @"";
        if ([name isEqualToString:kZNSSPExactClassName] && ZNSSPHasSelector(cls,@selector(setActive:))) {
            namedFallback=cls;
            break;
        }
        if (!ZNSSPClassLooksLikePatchObject(cls)) continue;
        Method m=class_getInstanceMethod(cls,@selector(setActive:));
        NSString *image=ZNSSPIMPImage(m);
        if ([image rangeOfString:@"EarntoDieRogue" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            imageFallback=cls;
            imageFallbackName=image;
            break;
        }
    }
    free(classes);

    Class found=namedFallback ?: imageFallback;
    if (detail) {
        if (found) {
            *detail=[NSString stringWithFormat:@"scan=%@ impImage=%@ classCount=%d",
                     NSStringFromClass(found) ?: @"?",
                     imageFallbackName.length?imageFallbackName:ZNSSPIMPImage(class_getInstanceMethod(found,@selector(setActive:))),
                     count];
        } else {
            *detail=[NSString stringWithFormat:@"exactPresent=%@ exactSetActive=%@ classCount=%d",
                     exact?@"YES":@"NO",
                     (exact&&ZNSSPHasSelector(exact,@selector(setActive:)))?@"YES":@"NO",
                     count];
        }
    }
    return found;
}

static int64_t ZNSSPSignExtend(uint64_t value, unsigned bits) {
    uint64_t sign=1ULL << (bits-1);
    return (int64_t)((value ^ sign) - sign);
}

static uintptr_t ZNSSPADRTarget(uintptr_t pc, uint32_t word) {
    if ((word & 0x9F000000u) != 0x10000000u) return 0;
    uint64_t immlo=(word >> 29) & 0x3u;
    uint64_t immhi=(word >> 5) & 0x7FFFFu;
    int64_t imm=ZNSSPSignExtend((immhi << 2) | immlo,21);
    return (uintptr_t)((intptr_t)pc + (intptr_t)imm);
}

static uintptr_t ZNSSPADRPPage(uintptr_t pc, uint32_t word, unsigned *regOut) {
    if ((word & 0x9F000000u) != 0x90000000u) return 0;
    uint64_t immlo=(word >> 29) & 0x3u;
    uint64_t immhi=(word >> 5) & 0x7FFFFu;
    int64_t pages=ZNSSPSignExtend((immhi << 2) | immlo,21);
    uintptr_t page=(pc & ~(uintptr_t)0xFFFu) + ((intptr_t)pages << 12);
    if (regOut) *regOut=word & 31u;
    return page;
}

static BOOL ZNSSPADDImmSame(uint32_t word, unsigned reg, uintptr_t *offsetOut) {
    if ((word & 0xFF000000u) != 0x91000000u) return NO;
    if ((word & 31u) != reg || ((word >> 5) & 31u) != reg) return NO;
    uintptr_t imm=(uintptr_t)((word >> 10) & 0xFFFu);
    if ((word >> 22) & 1u) imm <<= 12;
    if (offsetOut) *offsetOut=imm;
    return YES;
}

static BOOL ZNSSPImageInfoForPathFragment(NSString *fragment, ZNSSPImageInfo *outInfo) {
    if (!fragment.length || !outInfo) return NO;
    uint32_t count=_dyld_image_count();
    for (uint32_t i=0;i<count;i++) {
        const char *name=_dyld_get_image_name(i);
        const struct mach_header *mh=_dyld_get_image_header(i);
        if (!name || !mh || mh->magic != MH_MAGIC_64) continue;
        NSString *path=[NSString stringWithUTF8String:name] ?: @"";
        if ([path rangeOfString:fragment options:NSCaseInsensitiveSearch].location == NSNotFound) continue;

        ZNSSPImageInfo info={0};
        info.header=(const struct mach_header_64 *)mh;
        info.slide=_dyld_get_image_vmaddr_slide(i);
        strlcpy(info.path,name,sizeof(info.path));

        const uint8_t *cursor=(const uint8_t *)(info.header+1);
        for (uint32_t c=0;c<info.header->ncmds;c++) {
            const struct load_command *lc=(const struct load_command *)cursor;
            if (!lc->cmdsize) break;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg=(const struct segment_command_64 *)cursor;
                if (strncmp(seg->segname,"__TEXT",16)==0) {
                    info.textVM=seg->vmaddr;
                    info.textStart=(uintptr_t)((intptr_t)info.slide + (intptr_t)seg->vmaddr);
                    info.textEnd=info.textStart + (uintptr_t)seg->vmsize;
                    info.imageBase=info.textStart;
                } else if (strncmp(seg->segname,"__LINKEDIT",16)==0) {
                    info.linkVM=seg->vmaddr;
                    info.linkFile=seg->fileoff;
                }
            } else if (lc->cmd == LC_FUNCTION_STARTS) {
                info.functionStarts=(const struct linkedit_data_command *)cursor;
            }
            cursor += lc->cmdsize;
        }
        if (!info.imageBase || !info.textEnd) continue;
        *outInfo=info;
        return YES;
    }
    return NO;
}

static uintptr_t ZNSSPFindReference(const ZNSSPImageInfo *info, uintptr_t target, NSString **modeOut) {
    if (!info || !target || !info->textStart || info->textEnd <= info->textStart) return 0;
    for (uintptr_t pc=info->textStart; pc+4<=info->textEnd; pc+=4) {
        uint32_t word=0;
        memcpy(&word,(const void *)pc,sizeof(word));
        uintptr_t adr=ZNSSPADRTarget(pc,word);
        if (adr == target) {
            if (modeOut) *modeOut=@"ADR";
            return pc;
        }
        unsigned reg=0;
        uintptr_t page=ZNSSPADRPPage(pc,word,&reg);
        if (!page) continue;
        for (uintptr_t q=pc+4; q<pc+16 && q+4<=info->textEnd; q+=4) {
            uint32_t addWord=0;
            memcpy(&addWord,(const void *)q,sizeof(addWord));
            uintptr_t add=0;
            if (!ZNSSPADDImmSame(addWord,reg,&add)) continue;
            if (page + add == target) {
                if (modeOut) *modeOut=@"ADRP+ADD";
                return pc;
            }
        }
    }
    return 0;
}

static BOOL ZNSSPFunctionRange(const ZNSSPImageInfo *info,
                               uintptr_t address,
                               uintptr_t *startOut,
                               uintptr_t *endOut) {
    if (!info || !address || !info->functionStarts || !info->linkVM || !info->textStart) return NO;
    uintptr_t linkBase=(uintptr_t)((intptr_t)info->slide + (intptr_t)info->linkVM - (intptr_t)info->linkFile);
    const uint8_t *p=(const uint8_t *)(linkBase + info->functionStarts->dataoff);
    const uint8_t *end=p + info->functionStarts->datasize;
    uintptr_t previous=0;
    uint64_t cumulative=0;

    while (p<end) {
        uint64_t delta=0;
        unsigned shift=0;
        while (p<end && shift<64) {
            uint8_t byte=*p++;
            delta |= (uint64_t)(byte & 0x7Fu) << shift;
            if (!(byte & 0x80u)) break;
            shift += 7;
        }
        if (!delta) continue;
        cumulative += delta;
        uintptr_t current=info->textStart + (uintptr_t)cumulative;
        if (current > address) {
            if (!previous) return NO;
            if (startOut) *startOut=previous;
            if (endOut) *endOut=current;
            return YES;
        }
        previous=current;
    }
    if (previous && address>=previous && address<info->textEnd) {
        if (startOut) *startOut=previous;
        if (endOut) *endOut=info->textEnd;
        return YES;
    }
    return NO;
}

static uintptr_t ZNSSPSecretPointer(id wrapper) {
    if (!wrapper) return 0;
    SEL secretSel=sel_registerName("secret");
    if (![wrapper respondsToSelector:secretSel]) return 0;
    return ((uintptr_t (*)(id,SEL))objc_msgSend)(wrapper,secretSel);
}

static NSString *ZNSSPHexAt(uintptr_t address, NSUInteger length) {
    if (!address || !length) return @"<unresolved>";
    const uint8_t *bytes=(const uint8_t *)address;
    NSMutableString *hex=[NSMutableString stringWithCapacity:length*2];
    for (NSUInteger i=0;i<length;i++) [hex appendFormat:@"%02X",bytes[i]];
    return hex;
}

- (NSString *)siteSnapshot {
    ZNModuleManager *modules=[ZNModuleManager sharedManager];
    uintptr_t posters=[modules runtimeAddressForModule:kZNSSPModule rva:kZNSSPPostersOnlyRVA];
    uintptr_t shared=[modules runtimeAddressForModule:kZNSSPModule rva:kZNSSPSharedRVA];
    uintptr_t prestige=[modules runtimeAddressForModule:kZNSSPModule rva:kZNSSPPrestigeOnlyRVA];
    return [NSString stringWithFormat:@"posters@0x%llX=%@ shared@0x%llX=%@ prestige@0x%llX=%@",
            kZNSSPPostersOnlyRVA,ZNSSPHexAt(posters,16),
            kZNSSPSharedRVA,ZNSSPHexAt(shared,16),
            kZNSSPPrestigeOnlyRVA,ZNSSPHexAt(prestige,16)];
}

- (void)appendLine:(NSString *)line {
    if (!line.length) return;
    @synchronized (self) {
        NSString *dir=[self.logPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.logPath]) {
            [[NSData data] writeToFile:self.logPath atomically:YES];
        }
        NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:self.logPath];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
        self.lastStatus=line;
        [[ZNRuntimeLogger sharedLogger] log:line];
    }
}

- (void)probeBootstrapRootForObject:(id)obj {
    NSString *identifier=ZNSSPStringValue(obj,@"identifier");
    NSString *switchKey=ZNSSPStringValue(obj,@"HlkuHDyxft");
    if (!identifier.length) identifier=switchKey.length?switchKey:@"?";
    if (![identifier isEqualToString:@"5"] && ![identifier isEqualToString:@"10"] &&
        ![switchKey isEqualToString:@"5-switch"] && ![switchKey isEqualToString:@"10-switch"]) return;

    NSString *dedupe=[NSString stringWithFormat:@"%@/%@",identifier,switchKey ?: @""];
    @synchronized (self.bootstrapKeys) {
        if ([self.bootstrapKeys containsObject:dedupe]) return;
    }

    Method activeMethod=class_getInstanceMethod([obj class],@selector(setActive:));
    NSString *imageName=ZNSSPIMPImage(activeMethod);
    if (!imageName.length) imageName=@"EarntoDieRogue";

    ZNSSPImageInfo info={0};
    if (!ZNSSPImageInfoForPathFragment(imageName,&info) &&
        !ZNSSPImageInfoForPathFragment(@"EarntoDieRogue",&info)) {
        self.bootstrapStatus=@"NO_IMAGE";
        [self appendLine:[NSString stringWithFormat:@"[SSP-FEATURE-ROOT] id=%@ key=%@ status=NO_IMAGE impImage=%@",
                          identifier,switchKey.length?switchKey:@"?",imageName]];
        return;
    }

    id addressWrapper=ZNSSPValue(obj,@"address");
    id patchWrapper=ZNSSPValue(obj,@"IzwIRvtGs");
    if (!patchWrapper) patchWrapper=ZNSSPValue(obj,@"wrYyOhyFM");
    uintptr_t addressSecret=ZNSSPSecretPointer(addressWrapper);
    uintptr_t patchSecret=ZNSSPSecretPointer(patchWrapper);

    NSString *addressMode=nil;
    NSString *patchMode=nil;
    uintptr_t addressRef=addressSecret?ZNSSPFindReference(&info,addressSecret,&addressMode):0;
    uintptr_t patchRef=patchSecret?ZNSSPFindReference(&info,patchSecret,&patchMode):0;
    uintptr_t anchor=addressRef ?: patchRef;
    if (!anchor) {
        self.bootstrapStatus=@"NO_ANCHOR";
        [self appendLine:[NSString stringWithFormat:@"[SSP-FEATURE-ROOT] id=%@ key=%@ image=%s addressSecret=0x%llX patchSecret=0x%llX status=NO_ANCHOR",
                          identifier,switchKey.length?switchKey:@"?",info.path,
                          (unsigned long long)(addressSecret?addressSecret-info.imageBase:0),
                          (unsigned long long)(patchSecret?patchSecret-info.imageBase:0)]];
        return;
    }

    uintptr_t rootStart=0,rootEnd=0;
    if (!ZNSSPFunctionRange(&info,anchor,&rootStart,&rootEnd) || rootEnd<=rootStart) {
        self.bootstrapStatus=@"NO_FUNCTION_RANGE";
        [self appendLine:[NSString stringWithFormat:@"[SSP-FEATURE-ROOT] id=%@ key=%@ image=%s anchorRVA=0x%llX status=NO_FUNCTION_RANGE",
                          identifier,switchKey.length?switchKey:@"?",info.path,
                          (unsigned long long)(anchor-info.imageBase)]];
        return;
    }

    // Re-check both secret references inside the recovered function. This is the
    // v1.9.9 invariant we care about: the Feature root owns the descriptors.
    ZNSSPImageInfo rootInfo=info;
    rootInfo.textStart=rootStart;
    rootInfo.textEnd=rootEnd;
    NSString *rootAddressMode=nil;
    NSString *rootPatchMode=nil;
    uintptr_t rootAddressRef=addressSecret?ZNSSPFindReference(&rootInfo,addressSecret,&rootAddressMode):0;
    uintptr_t rootPatchRef=patchSecret?ZNSSPFindReference(&rootInfo,patchSecret,&rootPatchMode):0;

    NSString *verdict=(rootAddressRef || rootPatchRef)?@"FEATURE_ROOT":@"PARTIAL_ROOT";
    self.bootstrapStatus=[NSString stringWithFormat:@"%@ id=%@ root=0x%llX",verdict,identifier,
                          (unsigned long long)(rootStart-info.imageBase)];
    @synchronized (self.bootstrapKeys) {
        [self.bootstrapKeys addObject:dedupe];
    }

    [self appendLine:[NSString stringWithFormat:
        @"[SSP-FEATURE-ROOT] id=%@ key=%@ image=%s rootRVA=0x%llX endRVA=0x%llX size=0x%llX anchorRVA=0x%llX anchorMode=%@ addressSecretRVA=0x%llX addressRefRVA=0x%llX addressMode=%@ patchSecretRVA=0x%llX patchRefRVA=0x%llX patchMode=%@ verdict=%@",
        identifier,switchKey.length?switchKey:@"?",info.path,
        (unsigned long long)(rootStart-info.imageBase),
        (unsigned long long)(rootEnd-info.imageBase),
        (unsigned long long)(rootEnd-rootStart),
        (unsigned long long)(anchor-info.imageBase),
        addressRef?addressMode:(patchMode ?: @"?"),
        (unsigned long long)(addressSecret?addressSecret-info.imageBase:0),
        (unsigned long long)(rootAddressRef?rootAddressRef-info.imageBase:0),
        rootAddressMode ?: @"-",
        (unsigned long long)(patchSecret?patchSecret-info.imageBase:0),
        (unsigned long long)(rootPatchRef?rootPatchRef-info.imageBase:0),
        rootPatchMode ?: @"-",verdict]];
}

- (BOOL)installOnClass:(Class)cls error:(NSString **)error {
    if (!cls) {
        if (error) *error=@"目标类为空";
        return NO;
    }
    Method resolved=class_getInstanceMethod(cls,@selector(setActive:));
    if (!resolved) {
        if (error) *error=@"目标类不存在 -setActive:";
        return NO;
    }
    IMP original=method_getImplementation(resolved);
    const char *types=method_getTypeEncoding(resolved);
    if (!original || !types) {
        if (error) *error=@"无法取得 setActive: 原始 IMP/类型编码";
        return NO;
    }

    gZNSSPOriginalSetActive=(ZNSSPSetActiveIMP)original;
    __weak ZNSharedSiteProbe *weakProbe=self;
    id block=^void(id obj, BOOL active) {
        ZNSharedSiteProbe *probe=weakProbe;
        NSString *identifier=ZNSSPStringValue(obj,@"identifier");
        NSString *switchKey=ZNSSPStringValue(obj,@"HlkuHDyxft");
        BOOL relevant=[identifier isEqualToString:@"5"] || [identifier isEqualToString:@"10"] ||
                      [switchKey isEqualToString:@"5-switch"] || [switchKey isEqualToString:@"10-switch"];
        BOOL shouldLog=probe.isLoggingEnabled && relevant;
        if (shouldLog) {
            [probe probeBootstrapRootForObject:obj];
            [probe recordObject:obj requestedActive:active phase:@"BEGIN"];
        }

        if (gZNSSPOriginalSetActive) gZNSSPOriginalSetActive(obj,@selector(setActive:),active);

        if (shouldLog) {
            [probe recordObject:obj requestedActive:active phase:@"END"];
            __weak id weakObject=obj;
            dispatch_async(dispatch_get_main_queue(), ^{
                id strongObject=weakObject;
                if (probe.isLoggingEnabled && strongObject) {
                    [probe recordObject:strongObject requestedActive:active phase:@"DEFERRED"];
                }
            });
        }
    };
    gZNSSPReplacementIMP=imp_implementationWithBlock(block);
    if (!gZNSSPReplacementIMP) {
        if (error) *error=@"imp_implementationWithBlock 失败";
        return NO;
    }

    BOOL added=class_addMethod(cls,@selector(setActive:),gZNSSPReplacementIMP,types);
    NSString *hookMode=nil;
    if (added) {
        hookMode=@"class-override(inherited)";
    } else {
        Method direct=class_getInstanceMethod(cls,@selector(setActive:));
        if (!direct) {
            if (error) *error=@"无法取得直接 setActive: Method";
            return NO;
        }
        method_setImplementation(direct,gZNSSPReplacementIMP);
        hookMode=@"direct-replace";
    }

    self.targetClassName=NSStringFromClass(cls) ?: @"?";
    self.installed=YES;
    self.arming=NO;
    self.loggingEnabled=YES;
    [self appendLine:[NSString stringWithFormat:@"[SSP-INSTALL-V2] class=%@ selector=setActive: mode=%@ original=%p impImage=%@ shared=0x%llX bootstrap=FeatureBootstrapRoot",
                      self.targetClassName,hookMode,(void *)original,
                      ZNSSPIMPImage(resolved).length?ZNSSPIMPImage(resolved):@"?",
                      kZNSSPSharedRVA]];
    [self captureCurrentStateWithLabel:@"probe-v2-enabled"];
    return YES;
}

- (void)retryInstallToken:(NSUInteger)token remaining:(NSUInteger)remaining {
    if (token != self.armToken || self.installed || !self.arming) return;
    NSString *detail=nil;
    Class cls=ZNSSPFindTargetClass(&detail);
    if (cls) {
        NSString *e=nil;
        if ([self installOnClass:cls error:&e]) return;
        self.lastStatus=[NSString stringWithFormat:@"[SSP-RETRY] class found but install failed: %@",e ?: @"unknown"];
    }
    if (remaining == 0) {
        self.arming=NO;
        self.loggingEnabled=NO;
        [self appendLine:[NSString stringWithFormat:@"[SSP-FAIL] 10s 内未发现可 Hook Patch 类 · %@",detail ?: @"no detail"]];
        return;
    }
    self.lastStatus=[NSString stringWithFormat:@"[SSP-WAIT] 等待 Patch 类加载 · %@",detail ?: @"scanning"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.25*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [self retryInstallToken:token remaining:remaining-1];
    });
}

- (BOOL)installAndEnable:(NSString **)error {
    if (self.installed) {
        self.loggingEnabled=YES;
        [self appendLine:[NSString stringWithFormat:@"[SSP-RESUME] class=%@ %@",self.targetClassName,[self siteSnapshot]]];
        return YES;
    }
    NSString *detail=nil;
    Class cls=ZNSSPFindTargetClass(&detail);
    if (cls) {
        NSString *e=nil;
        BOOL ok=[self installOnClass:cls error:&e];
        if (!ok && error) *error=e;
        return ok;
    }
    self.arming=YES;
    self.loggingEnabled=YES;
    self.armToken += 1;
    NSUInteger token=self.armToken;
    [self appendLine:[NSString stringWithFormat:@"[SSP-ARM-V2] 等待 MdhpNuX/-setActive: 加载；安装后自动启用 FeatureBootstrapRoot · %@",detail ?: @"scanning"]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.25*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [self retryInstallToken:token remaining:39];
    });
    return YES;
}

- (void)setLoggingEnabled:(BOOL)enabled {
    if (!self.installed && enabled) {
        NSString *error=nil;
        [self installAndEnable:&error];
        return;
    }
    _loggingEnabled=enabled;
    if (!enabled && self.arming) {
        self.arming=NO;
        self.armToken += 1;
    }
    if (self.installed) {
        [self appendLine:[NSString stringWithFormat:@"[SSP-%@] class=%@",enabled?@"RESUME":@"PAUSE",self.targetClassName]];
    }
}

- (void)recordObject:(id)obj requestedActive:(BOOL)active phase:(NSString *)phase {
    NSString *identifier=ZNSSPStringValue(obj,@"identifier");
    NSString *switchKey=ZNSSPStringValue(obj,@"HlkuHDyxft");
    NSString *objectClass=NSStringFromClass([obj class]) ?: @"?";
    NSString *line=[NSString stringWithFormat:@"[SSP-%@] id=%@ key=%@ requested=%d object=%p class=%@ %@",
                    phase,identifier.length?identifier:@"?",switchKey.length?switchKey:@"?",active?1:0,obj,objectClass,[self siteSnapshot]];
    [self appendLine:line];
}

- (void)captureCurrentStateWithLabel:(NSString *)label {
    NSString *clean=label.length?label:@"manual";
    [self appendLine:[NSString stringWithFormat:@"[SSP-SNAPSHOT] label=%@ %@",clean,[self siteSnapshot]]];
}

- (void)clearLog {
    @synchronized (self) {
        [[NSFileManager defaultManager] removeItemAtPath:self.logPath error:nil];
        [self.bootstrapKeys removeAllObjects];
        self.bootstrapStatus=@"未观察";
        self.lastStatus=@"Probe 日志已清除";
    }
    if (self.installed && self.loggingEnabled) [self captureCurrentStateWithLabel:@"after-clear"];
}

- (NSString *)logText {
    NSError *error=nil;
    NSString *text=[NSString stringWithContentsOfFile:self.logPath encoding:NSUTF8StringEncoding error:&error];
    return text.length?text:(error.localizedDescription?:@"Probe 日志为空");
}

- (NSArray<NSString *> *)diagnosticLines {
    NSString *hook=self.installed?@"Installed":(self.arming?@"Waiting":@"Not installed");
    return @[
        [NSString stringWithFormat:@"Hook：%@ · Logging：%@",hook,self.loggingEnabled?@"ON":@"OFF"],
        [NSString stringWithFormat:@"Class：%@ · -setActive:",self.targetClassName.length?self.targetClassName:@"?"],
        [NSString stringWithFormat:@"Bootstrap：%@",self.bootstrapStatus.length?self.bootstrapStatus:@"未观察"],
        [NSString stringWithFormat:@"Shared Site：%@ + 0x%llX",kZNSSPModule,kZNSSPSharedRVA],
        [NSString stringWithFormat:@"Posters-only：0x%llX · Prestige-only：0x%llX",kZNSSPPostersOnlyRVA,kZNSSPPrestigeOnlyRVA],
        [NSString stringWithFormat:@"Log：Documents/%@",self.logPath.lastPathComponent],
        [NSString stringWithFormat:@"Last：%@",self.lastStatus.length?self.lastStatus:@"-"]
    ];
}

@end
