#import "ZNRuntimeActionRuntime.h"
#import "ZNRuntimeActionFormat.h"
#import "ZNRuntimeActionModel.h"
#import "ZNIL2CPPInvokeEngine.h"
#import "ZNIL2CPPMethodSignature.h"
#import "ZNStaticPatchFormat.h"
#import "ZNGeneratedDataLayout.h"
#import "ZNPatchCore.h"
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <string.h>

static uint64_t ZNRARAlign8(uint64_t value){return(value+7ULL)&~7ULL;}
static uint64_t ZNRARMixFingerprint(uint64_t h,uint64_t v){h^=v;h*=1099511628211ULL;return h;}
static uint64_t ZNRARImageFingerprint(uint32_t imageCount){
    uint64_t h=1469598103934665603ULL;h=ZNRARMixFingerprint(h,imageCount);
    for(uint32_t i=0;i<imageCount;i++){
        const struct mach_header *raw=_dyld_get_image_header(i);intptr_t slide=_dyld_get_image_vmaddr_slide(i);const char *path=_dyld_get_image_name(i);
        h=ZNRARMixFingerprint(h,(uint64_t)(uintptr_t)raw);h=ZNRARMixFingerprint(h,(uint64_t)(uintptr_t)slide);
        if(path){for(const unsigned char *p=(const unsigned char *)path;*p;p++){h^=(uint64_t)*p;h*=1099511628211ULL;}}
        if(raw&&raw->magic==MH_MAGIC_64){
            const struct mach_header_64 *mh=(const struct mach_header_64 *)raw;
            const uint8_t *cursor=(const uint8_t *)(mh+1),*limit=cursor+mh->sizeofcmds;
            if(mh->ncmds<=4096&&mh->sizeofcmds<=16*1024*1024){
                for(uint32_t c=0;c<mh->ncmds;c++){
                    if(cursor+sizeof(struct load_command)>limit)break;
                    const struct load_command *lc=(const struct load_command *)cursor;
                    if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit)break;
                    if(lc->cmd==LC_UUID&&lc->cmdsize>=sizeof(struct uuid_command)){
                        const struct uuid_command *uc=(const struct uuid_command *)cursor;
                        for(size_t b=0;b<sizeof(uc->uuid);b++){h^=(uint64_t)uc->uuid[b];h*=1099511628211ULL;}
                        break;
                    }
                    cursor+=lc->cmdsize;
                }
            }
        }
        h=ZNRARMixFingerprint(h,0xffULL);
    }
    return h;
}

@interface ZNRuntimeMethodActionRecord ()
@property(nonatomic,assign,readwrite) uint32_t actionID;@property(nonatomic,assign,readwrite) NSInteger executionKind;@property(nonatomic,copy,readwrite) NSString *title;@property(nonatomic,copy,readwrite) NSString *group;@property(nonatomic,copy,readwrite) NSString *featureDescription;@property(nonatomic,copy,readwrite) NSString *assembly;@property(nonatomic,copy,readwrite) NSString *namespaceName;@property(nonatomic,copy,readwrite) NSString *className;@property(nonatomic,copy,readwrite) NSString *methodName;@property(nonatomic,assign,readwrite) NSUInteger argumentCount;@property(nonatomic,copy,readwrite) NSArray<NSString *> *argumentValues;@property(nonatomic,copy,readwrite) NSArray<NSString *> *parameterTypeNames;@property(nonatomic,assign,readwrite) BOOL signatureAvailable;@property(nonatomic,copy,readwrite) NSArray<NSDictionary<NSString *,id> *> *argumentControlConfigs;@property(nonatomic,copy,readwrite) NSDictionary<NSString *,id> *immediateChain;@property(nonatomic,copy,readwrite) NSString *sourceImage;
@end
@implementation ZNRuntimeMethodActionRecord
- (instancetype)init{self=[super init];if(!self)return nil;_title=@"";_group=@"Runtime Methods";_featureDescription=@"";_assembly=@"";_namespaceName=@"";_className=@"";_methodName=@"";_argumentValues=@[];_parameterTypeNames=@[];_argumentControlConfigs=@[];_immediateChain=@{};_sourceImage=@"";return self;}
- (NSString *)canonicalIdentity{if(self.signatureAvailable&&self.parameterTypeNames.count==self.argumentCount)return ZNIL2CPPFullMethodIdentity(self.assembly?:@"",self.namespaceName?:@"",self.className?:@"",self.methodName?:@"",self.parameterTypeNames?:@[]);NSString *owner=self.namespaceName.length?[NSString stringWithFormat:@"%@.%@",self.namespaceName,self.className]:self.className;return[NSString stringWithFormat:@"%@!%@::%@/%lu",self.assembly?:@"",owner?:@"",self.methodName?:@"",(unsigned long)self.argumentCount];}
@end

static NSString *ZNRARReadString(const uint8_t *table,const ZNRuntimeActionHeader *header,uint32_t offset){if(!table||!header||offset<header->stringPoolOffset||offset>=header->totalSize)return nil;const uint8_t *start=table+offset,*end=table+header->totalSize,*nul=(const uint8_t *)memchr(start,0,(size_t)(end-start));if(!nul)return nil;return[[NSString alloc]initWithData:[NSData dataWithBytes:start length:(NSUInteger)(nul-start)] encoding:NSUTF8StringEncoding];}
static id ZNRARDecodeJSON(NSString *json,Class cls){if(!json.length)return nil;NSData *data=[json dataUsingEncoding:NSUTF8StringEncoding];if(!data.length)return nil;id obj=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];return[obj isKindOfClass:cls]?obj:nil;}
static NSArray<NSString *> *ZNRARDecodeArgs(NSString *json){NSArray *arr=ZNRARDecodeJSON(json,NSArray.class);if(!arr)return nil;for(id x in arr)if(![x isKindOfClass:NSString.class])return nil;return arr;}

static void ZNRARParseImage(uint32_t imageIndex,NSMutableArray *out,NSMutableSet *dedupe,NSMutableArray *diagnostics){
    const struct mach_header *raw=_dyld_get_image_header(imageIndex);if(!raw||raw->magic!=MH_MAGIC_64)return;const struct mach_header_64 *mh=(const struct mach_header_64 *)raw;intptr_t slide=_dyld_get_image_vmaddr_slide(imageIndex);const char *cpath=_dyld_get_image_name(imageIndex);NSString *path=cpath?[NSString stringWithUTF8String:cpath]:@"";const uint8_t *cursor=(const uint8_t *)(mh+1),*limit=cursor+mh->sizeofcmds;if(mh->ncmds>4096||mh->sizeofcmds>16*1024*1024)return;const struct section_64 *zndata=NULL;
    for(uint32_t i=0;i<mh->ncmds;i++){if(cursor+sizeof(struct load_command)>limit)return;const struct load_command *lc=(const struct load_command *)cursor;if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit)return;if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(struct segment_command_64)){const struct segment_command_64 *seg=(const struct segment_command_64 *)cursor;if(strncmp(seg->segname,"__ZNDATA",16)==0){if(lc->cmdsize<sizeof(*seg)+(uint64_t)seg->nsects*sizeof(struct section_64))return;const struct section_64 *sections=(const struct section_64 *)(seg+1);for(uint32_t j=0;j<seg->nsects;j++)if(strncmp(sections[j].sectname,"__zndata",16)==0){zndata=&sections[j];break;}}}if(zndata)break;cursor+=lc->cmdsize;}
    if(!zndata||zndata->size<sizeof(ZN44StaticHeader))return;__int128 ra=(__int128)zndata->addr+(__int128)slide;if(ra<=0||ra>UINTPTR_MAX)return;const uint8_t *section=(const uint8_t *)(uintptr_t)ra;uint64_t sectionSize=zndata->size;const ZN44StaticHeader *sh=(const ZN44StaticHeader *)section;if(sh->magic0!=ZN44_STATIC_MAGIC0||sh->magic1!=ZN44_STATIC_MAGIC1||sh->entrySize!=sizeof(ZN44StaticEntry)||sh->count>ZN44_STATIC_MAX_ENTRIES)return;uint64_t actionRelative=0;if(!ZNGeneratedDataLayoutV1LocateRuntimeAction(section,zndata->size,&actionRelative)||actionRelative>zndata->size||zndata->size-actionRelative<sizeof(ZNRuntimeActionHeader))return;const uint8_t *table=section+actionRelative;const ZNRuntimeActionHeader *header=(const ZNRuntimeActionHeader *)table;if(header->magic!=ZN_RUNTIME_ACTION_MAGIC||header->version!=ZN_RUNTIME_ACTION_VERSION||header->entrySize!=sizeof(ZNRuntimeMethodCallEntry)||header->count>ZN_RUNTIME_ACTION_MAX_ENTRIES||header->totalSize>sectionSize-actionRelative)return;uint64_t fixedEnd=sizeof(*header)+(uint64_t)header->count*header->entrySize;if(fixedEnd>header->totalSize||header->stringPoolOffset<fixedEnd||header->stringPoolOffset>header->totalSize)return;
    const ZNRuntimeMethodCallEntry *entries=(const ZNRuntimeMethodCallEntry *)(table+sizeof(*header));NSUInteger accepted=0;
    for(uint32_t i=0;i<header->count;i++){const ZNRuntimeMethodCallEntry *entry=&entries[i];if((entry->kind!=ZNRuntimeActionKindIL2CPPMethodCall&&entry->kind!=ZNRuntimeActionKindDirectNativeCall)||entry->argumentCount>ZN_RUNTIME_ACTION_MAX_ARGUMENTS)continue;NSString *title=ZNRARReadString(table,header,entry->titleOffset),*group=ZNRARReadString(table,header,entry->groupOffset),*assembly=ZNRARReadString(table,header,entry->assemblyOffset),*ns=ZNRARReadString(table,header,entry->namespaceOffset),*cls=ZNRARReadString(table,header,entry->classOffset),*method=ZNRARReadString(table,header,entry->methodOffset);if(!title||!group||!assembly||!ns||!cls||!method||!assembly.length||!cls.length||!method.length)continue;
        NSArray *args=@[];if(entry->argumentCount>0){if(entry->flags&ZNRuntimeActionFlagArgumentVectorText){args=ZNRARDecodeArgs(ZNRARReadString(table,header,entry->reserved[2]));if(!args||args.count!=entry->argumentCount)continue;}else if(entry->argumentCount==1&&(entry->flags&ZNRuntimeActionFlagArgument0Text)){NSString *a=ZNRARReadString(table,header,entry->reserved[0]);if(!a)continue;args=@[a];}else continue;}
        NSArray *types=@[];BOOL sig=NO;if(entry->flags&ZNRuntimeActionFlagParameterSignature){NSString *encoded=ZNRARReadString(table,header,entry->reserved[1]);if(!encoded)continue;types=ZNIL2CPPDecodeParameterTypeNames(encoded);if(types.count!=entry->argumentCount)continue;sig=YES;}
        NSArray *controls=@[];if(entry->flags&ZNRuntimeActionFlagArgumentControls){controls=ZNRARDecodeJSON(ZNRARReadString(table,header,entry->reserved[3]),NSArray.class);if(!controls||controls.count!=entry->argumentCount)continue;}
        NSDictionary *chain=@{};if(entry->flags&ZNRuntimeActionFlagImmediateChain){chain=ZNRARDecodeJSON(ZNRARReadString(table,header,entry->reserved[4]),NSDictionary.class);if(!chain)continue;}
        NSString *featureDescription=@"";if(entry->flags&ZNRuntimeActionFlagFeatureDescription){featureDescription=ZNRARReadString(table,header,entry->reserved[5])?:@"";}
        ZNRuntimeMethodActionRecord *r=[ZNRuntimeMethodActionRecord new];r.actionID=entry->actionID;r.executionKind=(NSInteger)entry->kind;r.title=title.length?title:method;r.group=group.length?group:@"Runtime Methods";r.featureDescription=featureDescription?:@"";r.assembly=assembly;r.namespaceName=ns;r.className=cls;r.methodName=method;r.argumentCount=entry->argumentCount;r.argumentValues=args;r.parameterTypeNames=types;r.signatureAvailable=sig;r.argumentControlConfigs=controls?:@[];r.immediateChain=chain?:@{};r.sourceImage=path?:@"";NSString *key=[NSString stringWithFormat:@"%u|%@|%@",r.actionID,r.canonicalIdentity,r.argumentValues];if([dedupe containsObject:key])continue;[dedupe addObject:key];[out addObject:r];accepted++;}
    if(accepted)[diagnostics addObject:[NSString stringWithFormat:@"%@：Runtime Actions %lu",path.lastPathComponent?:@"image",(unsigned long)accepted]];
}

@interface ZNRuntimeActionRuntime ()
@property(nonatomic,copy,readwrite) NSArray<ZNRuntimeMethodActionRecord *> *records;@property(nonatomic,copy,readwrite) NSArray<ZNRuntimeMethodActionRecord *> *directRecords;@property(nonatomic,copy,readwrite) NSString *lastStatus;@property(nonatomic,copy) NSArray<NSString *> *lastDiagnostics;@property(nonatomic,assign) uint32_t cachedImageCount;@property(nonatomic,assign) uint64_t cachedImageFingerprint;@property(nonatomic,assign) BOOL hasScanned;
@end
@implementation ZNRuntimeActionRuntime
+ (instancetype)sharedRuntime{static ZNRuntimeActionRuntime *r;static dispatch_once_t once;dispatch_once(&once,^{r=[ZNRuntimeActionRuntime new];});return r;}
- (instancetype)init{self=[super init];if(!self)return nil;_records=@[];_directRecords=@[];_lastDiagnostics=@[];_lastStatus=@"尚未扫描 Runtime Method Call";_cachedImageCount=0;_cachedImageFingerprint=0;_hasScanned=NO;return self;}
- (void)refresh{uint32_t imageCount=_dyld_image_count();if(self.hasScanned&&self.cachedImageCount==imageCount)return;uint64_t fingerprint=ZNRARImageFingerprint(imageCount);NSMutableArray *found=[NSMutableArray array];NSMutableSet *dedupe=[NSMutableSet set];NSMutableArray *diag=[NSMutableArray array];for(uint32_t i=0;i<imageCount;i++)ZNRARParseImage(i,found,dedupe,diag);NSMutableArray *runtime=[NSMutableArray array],*direct=[NSMutableArray array];for(ZNRuntimeMethodActionRecord *r in found){if(r.executionKind==ZNRuntimeActionKindDirectNativeCall)[direct addObject:r];else[runtime addObject:r];}self.records=[runtime copy];self.directRecords=[direct copy];self.lastDiagnostics=[diag copy];self.cachedImageCount=imageCount;self.cachedImageFingerprint=fingerprint;self.hasScanned=YES;self.lastStatus=[NSString stringWithFormat:@"Runtime Method Call：%lu · Direct Native Call：%lu",(unsigned long)runtime.count,(unsigned long)direct.count];[[ZNRuntimeLogger sharedLogger]log:[NSString stringWithFormat:@"[runtime-action] refresh runtime=%lu direct=%lu",(unsigned long)runtime.count,(unsigned long)direct.count]];}
- (BOOL)executeRecord:(ZNRuntimeMethodActionRecord *)record error:(NSString **)error{if(!record){if(error)*error=@"Runtime Method Call record 为空";return NO;}ZNRuntimeMethodAction *a=[ZNRuntimeMethodAction new];a.actionID=record.actionID;a.title=record.title;a.group=record.group;a.featureDescription=record.featureDescription?:@"";a.assembly=record.assembly;a.namespaceName=record.namespaceName;a.className=record.className;a.methodName=record.methodName;a.argumentCount=record.argumentCount;a.argumentValues=record.argumentValues?:@[];a.parameterTypeNames=record.parameterTypeNames?:@[];a.signatureAvailable=record.signatureAvailable;a.argumentControlConfigs=record.argumentControlConfigs?:@[];a.immediateChain=record.immediateChain?:@{};NSString *invokeError=nil;NSDictionary *result=[[ZNIL2CPPInvokeEngine sharedEngine]executeAction:a error:&invokeError];if(!result){self.lastStatus=invokeError?:@"Runtime Method Call 执行失败";if(error)*error=self.lastStatus;return NO;}self.lastStatus=[NSString stringWithFormat:@"%@：SUCCESS",record.title.length?record.title:record.methodName];return YES;}
- (NSArray<NSString *> *)diagnosticLines{NSMutableArray *lines=[NSMutableArray array];[lines addObject:self.lastStatus?:@""];[lines addObjectsFromArray:self.lastDiagnostics?:@[]];for(ZNRuntimeMethodActionRecord *r in self.records)[lines addObject:[NSString stringWithFormat:@"[%u] %@ · %@ · args=%@ · controls=%lu · chain=%@",r.actionID,r.title?:@"",r.canonicalIdentity,r.argumentValues?:@[],(unsigned long)r.argumentControlConfigs.count,r.immediateChain.count?@"YES":@"NO"]];return lines;}
@end
