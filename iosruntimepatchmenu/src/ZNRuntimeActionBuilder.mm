#import "ZNRuntimeActionBuilder.h"
#import "ZNComplexStructCodec.h"
#import "ZNRuntimeActionFormat.h"
#import "ZNRuntimeActionModel.h"
#import "ZNNativeHookAction.h"
#import "ZNIL2CPPMethodSignature.h"
#import "ZNStaticPatchFormat.h"
#import "ZNGeneratedDataLayout.h"
#import "ZNPatchCore.h"
#import <mach-o/loader.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#include <string.h>

static uint64_t ZNRABAlign8(uint64_t value) { return (value + 7ULL) & ~7ULL; }

static BOOL ZNRABAppendString(NSMutableData *data, NSString *value, uint32_t *offset, NSString **error) {
    NSData *utf8=[(value?:@"") dataUsingEncoding:NSUTF8StringEncoding]; if(!utf8)utf8=[NSData data];
    if((uint64_t)data.length+(uint64_t)utf8.length+1ULL>UINT32_MAX){if(error)*error=@"Runtime Action string pool 超过 32-bit offset 范围";return NO;}
    if(offset)*offset=(uint32_t)data.length; [data appendData:utf8]; uint8_t zero=0; [data appendBytes:&zero length:1]; return YES;
}

static NSString *ZNRABEncodeJSON(id object, NSString **error) {
    NSError *jsonError=nil; NSData *data=[NSJSONSerialization dataWithJSONObject:object?:@{} options:0 error:&jsonError];
    if(!data){if(error)*error=[NSString stringWithFormat:@"Runtime Action JSON 编码失败：%@",jsonError.localizedDescription?:@"unknown"];return nil;}
    NSString *json=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]; if(!json&&error)*error=@"Runtime Action JSON 不是 UTF-8"; return json;
}
static NSString *ZNRABEncodeArgumentVector(NSArray<NSString *> *values, NSString **error) { return ZNRABEncodeJSON(values?:@[],error); }

static NSData *ZNRABSerialize(NSArray<ZNRuntimeMethodAction *> *actions,
                              NSArray<ZNNativeHookAction *> *hooks,
                              NSString **error) {
    NSUInteger totalCount=actions.count+hooks.count;
    if(!totalCount)return [NSData data];
    if(totalCount>ZN_RUNTIME_ACTION_MAX_ENTRIES){if(error)*error=[NSString stringWithFormat:@"Runtime Action 数量超过上限 %u",ZN_RUNTIME_ACTION_MAX_ENTRIES];return nil;}
    uint64_t fixed=sizeof(ZNRuntimeActionHeader)+totalCount*sizeof(ZNRuntimeMethodCallEntry); if(fixed>UINT32_MAX){if(error)*error=@"Runtime Action 固定表过大";return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)fixed]; ZNRuntimeActionHeader *header=(ZNRuntimeActionHeader *)data.mutableBytes;
    header->magic=ZN_RUNTIME_ACTION_MAGIC;header->version=ZN_RUNTIME_ACTION_VERSION;header->count=(uint32_t)totalCount;header->entrySize=sizeof(ZNRuntimeMethodCallEntry);header->stringPoolOffset=(uint32_t)fixed;
    for(NSUInteger i=0;i<actions.count;i++){
        ZNRuntimeMethodAction *action=actions[i];
        if(action.argumentCount>ZN_RUNTIME_ACTION_MAX_ARGUMENTS){if(error)*error=[NSString stringWithFormat:@"%@：参数数量超过上限 %u",action.canonicalIdentity,ZN_RUNTIME_ACTION_MAX_ARGUMENTS];return nil;}
        if(action.argumentCount>0&&action.argumentValues.count!=action.argumentCount){if(error)*error=@"Runtime Action 参数数量不匹配";return nil;}
        if(action.argumentControlConfigs.count&&action.argumentControlConfigs.count!=action.argumentCount){if(error)*error=@"Runtime 参数控件数量必须等于 argc";return nil;}
        if(action.signatureAvailable&&action.parameterTypeNames.count!=action.argumentCount){if(error)*error=@"Full Signature 参数数量不匹配";return nil;}
        uint32_t titleOffset=0,groupOffset=0,assemblyOffset=0,namespaceOffset=0,classOffset=0,methodOffset=0;
        uint32_t argument0Offset=0,signatureOffset=0,argumentVectorOffset=0,controlsOffset=0,chainOffset=0,descriptionOffset=0; NSString *stringError=nil;
        if(!ZNRABAppendString(data,action.title,&titleOffset,&stringError)||!ZNRABAppendString(data,action.group,&groupOffset,&stringError)||!ZNRABAppendString(data,action.assembly,&assemblyOffset,&stringError)||!ZNRABAppendString(data,action.namespaceName,&namespaceOffset,&stringError)||!ZNRABAppendString(data,action.className,&classOffset,&stringError)||!ZNRABAppendString(data,action.methodName,&methodOffset,&stringError)){if(error)*error=stringError?:@"Runtime Action string pool 写入失败";return nil;}
        if(action.argumentCount==1&&!ZNRABAppendString(data,action.argumentValues.firstObject?:@"",&argument0Offset,&stringError)){if(error)*error=stringError;return nil;}
        if(action.signatureAvailable){NSString *encoded=ZNIL2CPPEncodeParameterTypeNames(action.parameterTypeNames?:@[]);if(!ZNRABAppendString(data,encoded,&signatureOffset,&stringError)){if(error)*error=stringError;return nil;}}
        if(action.argumentCount>0){NSString *json=ZNRABEncodeArgumentVector(action.argumentValues,&stringError);if(!json||!ZNRABAppendString(data,json,&argumentVectorOffset,&stringError)){if(error)*error=stringError;return nil;}}
        if(action.argumentControlConfigs.count){NSString *json=ZNRABEncodeJSON(action.argumentControlConfigs,&stringError);if(!json||!ZNRABAppendString(data,json,&controlsOffset,&stringError)){if(error)*error=stringError;return nil;}}
        if(action.immediateChain.count){NSString *json=ZNRABEncodeJSON(action.immediateChain,&stringError);if(!json||!ZNRABAppendString(data,json,&chainOffset,&stringError)){if(error)*error=stringError;return nil;}}
        if(action.featureDescription.length&&!ZNRABAppendString(data,action.featureDescription,&descriptionOffset,&stringError)){if(error)*error=stringError;return nil;}
        ZNRuntimeMethodCallEntry *entries=(ZNRuntimeMethodCallEntry *)((uint8_t *)data.mutableBytes+sizeof(ZNRuntimeActionHeader)); ZNRuntimeMethodCallEntry *entry=&entries[i];
        entry->actionID=action.actionID;entry->kind=(action.executionKind==ZNRuntimeExecutionKindDirectNativeCall)?ZNRuntimeActionKindDirectNativeCall:ZNRuntimeActionKindIL2CPPMethodCall;entry->argumentCount=(uint32_t)action.argumentCount;entry->titleOffset=titleOffset;entry->groupOffset=groupOffset;entry->assemblyOffset=assemblyOffset;entry->namespaceOffset=namespaceOffset;entry->classOffset=classOffset;entry->methodOffset=methodOffset;
        if(action.argumentCount==1){entry->flags|=ZNRuntimeActionFlagArgument0Text;entry->reserved[0]=argument0Offset;}
        if(action.signatureAvailable){entry->flags|=ZNRuntimeActionFlagParameterSignature;entry->reserved[1]=signatureOffset;}
        if(action.argumentCount>0){entry->flags|=ZNRuntimeActionFlagArgumentVectorText;entry->reserved[2]=argumentVectorOffset;}
        if(action.argumentControlConfigs.count){entry->flags|=ZNRuntimeActionFlagArgumentControls;entry->reserved[3]=controlsOffset;}
        if(action.immediateChain.count){entry->flags|=ZNRuntimeActionFlagImmediateChain;entry->reserved[4]=chainOffset;}
        if(action.featureDescription.length){entry->flags|=ZNRuntimeActionFlagFeatureDescription;entry->reserved[5]=descriptionOffset;}
    }

    for(NSUInteger i=0;i<hooks.count;i++){
        ZNNativeHookAction *hook=hooks[i];
        BOOL argScaleValid=hook.templateKind==ZNNativeHookTemplateArgScaleInt32&&hook.argumentIndex<hook.argumentCount;
        BOOL callbackValid=hook.templateKind==ZNNativeHookTemplateManagedCallbackShortCircuit&&
                           hook.callbackArgumentIndex<hook.argumentCount&&hook.skipOriginal;
        BOOL returnBoolValid=hook.templateKind==ZNNativeHookTemplateReturnBoolOverride;
        BOOL structFieldValid=hook.templateKind==ZNNativeHookTemplateStructFieldTransform&&
                              hook.fieldArgumentIndex<hook.argumentCount&&
                              [hook.fieldArgumentMode isEqualToString:@"indirect-pointer"]&&
                              [hook.fieldCodec isEqualToString:@"secure-long-accessor"]&&
                              hook.fieldOffset<=0x100000ULL&&hook.codecClassName.length&&
                              hook.codecGetterMethod.length&&hook.codecSetterMethod.length;
        NSString *expectedComplexCodec=ZNComplexStructCodecKeyForManagedType(hook.codecClassName);
        BOOL complexStructValid=hook.templateKind==ZNNativeHookTemplateComplexStructTransform&&
                                hook.fieldArgumentIndex<hook.argumentCount&&
                                [hook.fieldArgumentMode isEqualToString:@"indirect-pointer"]&&
                                hook.fieldCodec.length&&[expectedComplexCodec isEqualToString:hook.fieldCodec]&&
                                hook.fieldOffset==0&&hook.codecClassName.length;
        if(!argScaleValid&&!callbackValid&&!returnBoolValid&&!structFieldValid&&!complexStructValid){
            if(error)*error=[NSString stringWithFormat:@"%@：Native Hook 配置无效",hook.canonicalIdentity?:hook.methodName];
            return nil;
        }
        if(hook.signatureAvailable&&hook.parameterTypeNames.count!=hook.argumentCount){
            if(error)*error=[NSString stringWithFormat:@"%@：Native Hook Full Signature 参数数量不匹配",hook.canonicalIdentity];
            return nil;
        }

        uint32_t titleOffset=0,groupOffset=0,assemblyOffset=0,namespaceOffset=0,classOffset=0,methodOffset=0;
        uint32_t configOffset=0,signatureOffset=0,descriptionOffset=0; NSString *stringError=nil;
        if(!ZNRABAppendString(data,hook.title,&titleOffset,&stringError)||
           !ZNRABAppendString(data,hook.group,&groupOffset,&stringError)||
           !ZNRABAppendString(data,hook.assembly,&assemblyOffset,&stringError)||
           !ZNRABAppendString(data,hook.namespaceName,&namespaceOffset,&stringError)||
           !ZNRABAppendString(data,hook.className,&classOffset,&stringError)||
           !ZNRABAppendString(data,hook.methodName,&methodOffset,&stringError)){
            if(error)*error=stringError?:@"Native Hook string pool 写入失败";return nil;
        }

        if(!hook.preparedDescriptor || !hook.preparedRVA ||
           !hook.preparedUUID.length || !hook.preparedStaticKnown){
            if(error)*error=[NSString stringWithFormat:@"%@：Native Hook 缺少 M6.9 Prepared Descriptor，请重新生成",
                             hook.canonicalIdentity ?: hook.methodName];
            return nil;
        }
        if(!hook.staticPrepatch || !hook.staticHookSlotRVA ||
           !hook.staticTrampolineRVA || !hook.staticCodeCaveRVA ||
           !hook.staticDisplacedInstruction){
            if(error)*error=[NSString stringWithFormat:@"%@：Native Hook 缺少 M6.10 Static Prepared Descriptor",
                             hook.canonicalIdentity ?: hook.methodName];
            return nil;
        }
        NSMutableDictionary *config=[@{
            @"version":@3,
            @"template":ZNNativeHookTemplateKey(hook.templateKind),
            @"resolutionMode":@"static-prepatch-v1",
            @"prepared":@YES,
            @"preparedRVA":@(hook.preparedRVA),
            @"preparedUUID":hook.preparedUUID?:@"",
            @"preparedStaticKnown":@(hook.preparedStaticKnown),
            @"preparedIsStatic":@(hook.preparedIsStatic),
            @"preparedCodecGetterRVA":@(hook.preparedCodecGetterRVA),
            @"preparedCodecSetterRVA":@(hook.preparedCodecSetterRVA),
            @"staticPrepatch":@YES,
            @"staticHookSlotRVA":@(hook.staticHookSlotRVA),
            @"staticTrampolineRVA":@(hook.staticTrampolineRVA),
            @"staticCodeCaveRVA":@(hook.staticCodeCaveRVA),
            @"staticDisplacedInstruction":@(hook.staticDisplacedInstruction),
            // Kept only for diagnostics/authoring compatibility.
            @"fallbackRVA":@(hook.fallbackRVA),
            @"fallbackUUID":hook.fallbackUUID?:@""
        } mutableCopy];
        if(hook.templateKind==ZNNativeHookTemplateArgScaleInt32){
            config[@"argumentIndex"]=@(hook.argumentIndex);
            config[@"control"]=@"slider";
            config[@"min"]=@(hook.minValue);config[@"max"]=@(hook.maxValue);config[@"default"]=@(hook.defaultValue);
        }else if(hook.templateKind==ZNNativeHookTemplateManagedCallbackShortCircuit){
            config[@"callbackArgumentIndex"]=@(hook.callbackArgumentIndex);
            config[@"callbackValue"]=@(hook.callbackValue);
            config[@"skipOriginal"]=@(hook.skipOriginal);
            config[@"control"]=@"switch";
            config[@"default"]=@0;
        }else if(hook.templateKind==ZNNativeHookTemplateReturnBoolOverride){
            config[@"returnBoolValue"]=@(hook.returnBoolValue);
            config[@"control"]=@"switch";
            config[@"default"]=@0;
        }else{
            config[@"fieldArgumentIndex"]=@(hook.fieldArgumentIndex);
            config[@"fieldArgumentMode"]=hook.fieldArgumentMode?:@"indirect-pointer";
            config[@"fieldOffset"]=@(hook.fieldOffset);
            config[@"fieldCodec"]=hook.fieldCodec?:@"secure-long-accessor";
            config[@"codecAssembly"]=hook.codecAssembly?:@"";
            config[@"codecNamespace"]=hook.codecNamespaceName?:@"";
            config[@"codecClass"]=hook.codecClassName?:@"";
            config[@"codecGetterMethod"]=hook.codecGetterMethod?:@"";
            config[@"codecSetterMethod"]=hook.codecSetterMethod?:@"";
            config[@"codecGetterArgumentCount"]=@(hook.codecGetterArgumentCount);
            config[@"codecSetterArgumentCount"]=@(hook.codecSetterArgumentCount);
            config[@"control"]=@"slider";
            config[@"min"]=@(hook.minValue);config[@"max"]=@(hook.maxValue);config[@"default"]=@(hook.defaultValue);
        }
        NSString *json=ZNRABEncodeJSON(config,&stringError);
        if(!json||!ZNRABAppendString(data,json,&configOffset,&stringError)){if(error)*error=stringError?:@"Native Hook config 编码失败";return nil;}
        if(hook.signatureAvailable){
            NSString *encoded=ZNIL2CPPEncodeParameterTypeNames(hook.parameterTypeNames?:@[]);
            if(!ZNRABAppendString(data,encoded,&signatureOffset,&stringError)){if(error)*error=stringError;return nil;}
        }
        if(hook.featureDescription.length&&!ZNRABAppendString(data,hook.featureDescription,&descriptionOffset,&stringError)){if(error)*error=stringError;return nil;}

        ZNRuntimeMethodCallEntry *entries=(ZNRuntimeMethodCallEntry *)((uint8_t *)data.mutableBytes+sizeof(ZNRuntimeActionHeader));
        ZNRuntimeMethodCallEntry *entry=&entries[actions.count+i];
        entry->actionID=hook.actionID;
        entry->kind=ZNRuntimeActionKindIL2CPPNativeHook;
        entry->argumentCount=(uint32_t)hook.argumentCount;
        entry->titleOffset=titleOffset;entry->groupOffset=groupOffset;entry->assemblyOffset=assemblyOffset;
        entry->namespaceOffset=namespaceOffset;entry->classOffset=classOffset;entry->methodOffset=methodOffset;
        entry->flags|=ZNRuntimeActionFlagNativeHookConfig;entry->reserved[0]=configOffset;
        if(hook.signatureAvailable){entry->flags|=ZNRuntimeActionFlagParameterSignature;entry->reserved[1]=signatureOffset;}
        if(hook.featureDescription.length){entry->flags|=ZNRuntimeActionFlagFeatureDescription;entry->reserved[5]=descriptionOffset;}
    }

    while(data.length&7u){uint8_t zero=0;[data appendBytes:&zero length:1];}
    if(data.length>UINT32_MAX){if(error)*error=@"Runtime Action table 超过 4GB";return nil;}
    header=(ZNRuntimeActionHeader *)data.mutableBytes;header->totalSize=(uint32_t)data.length;header->stringPoolSize=header->totalSize-header->stringPoolOffset;return [data copy];
}

static BOOL ZNRABIsZeroRange(const uint8_t *p,size_t n){for(size_t i=0;i<n;i++)if(p[i]!=0)return NO;return YES;}

static void ZNRABUpdateBuildReport(NSArray<NSString *> *builderOutputs,
                                  NSArray<ZNRuntimeMethodAction *> *actions,
                                  NSArray<ZNNativeHookAction *> *hooks,
                                  NSUInteger tableBytes){
    NSString *reportPath=nil;for(NSString *path in builderOutputs)if([path.lastPathComponent isEqualToString:@"build_report.json"]){reportPath=path;break;}if(!reportPath.length)return;
    NSData *json=[NSData dataWithContentsOfFile:reportPath];if(!json.length)return;NSMutableDictionary *object=[[NSJSONSerialization JSONObjectWithData:json options:NSJSONReadingMutableContainers error:nil] mutableCopy];if(![object isKindOfClass:NSMutableDictionary.class])return;
    NSMutableArray *items=[NSMutableArray arrayWithCapacity:actions.count];for(ZNRuntimeMethodAction *action in actions)[items addObject:@{@"actionID":@(action.actionID),@"executionKind":@(action.executionKind),@"title":action.title?:@"",@"description":action.featureDescription?:@"",@"identity":action.canonicalIdentity?:@"",@"argumentCount":@(action.argumentCount),@"argumentValues":action.argumentValues?:@[],@"argumentControls":action.argumentControlConfigs?:@[],@"immediateChain":action.immediateChain?:@{}}];
    object[@"runtimeMethodCall"]=@{@"format":@"com.zonoe.runtime-action/v1",@"version":@1,@"storage":@"__ZNDATA/__zndata after Static Dispatch table",@"staticEntryABIPreserved":@YES,@"runtimeEntrySize":@(sizeof(ZNRuntimeMethodCallEntry)),@"typedArgumentMaxCount":@(ZN_RUNTIME_ACTION_MAX_ARGUMENTS),@"supportedArgumentRange":@"0-8",@"signatureEncoding":@"U+001F parameter types via reserved[1]",@"argumentVectorEncoding":@"UTF-8 JSON array via reserved[2]",@"argumentControlsEncoding":@"UTF-8 JSON via reserved[3]",@"immediateChainEncoding":@"UTF-8 JSON via reserved[4]",@"featureDescriptionEncoding":@"UTF-8 via reserved[5]",@"count":@(actions.count),@"bytes":@(tableBytes),@"actions":items};
    NSMutableArray *hookItems=[NSMutableArray arrayWithCapacity:hooks.count];
    for(ZNNativeHookAction *hook in hooks){
        [hookItems addObject:@{@"actionID":@(hook.actionID),@"title":hook.title?:@"",@"identity":hook.canonicalIdentity?:@"",
                               @"template":ZNNativeHookTemplateKey(hook.templateKind),@"argumentIndex":@(hook.argumentIndex),
                               @"callbackArgumentIndex":@(hook.callbackArgumentIndex==NSNotFound?NSUIntegerMax:hook.callbackArgumentIndex),
                               @"callbackValue":@(hook.callbackValue),@"skipOriginal":@(hook.skipOriginal),
                               @"returnBoolValue":@(hook.returnBoolValue),
                               @"fieldArgumentIndex":@(hook.fieldArgumentIndex==NSNotFound?NSUIntegerMax:hook.fieldArgumentIndex),
                               @"fieldArgumentMode":hook.fieldArgumentMode?:@"",@"fieldOffset":@(hook.fieldOffset),
                               @"fieldCodec":hook.fieldCodec?:@"",@"codecAssembly":hook.codecAssembly?:@"",
                               @"codecNamespace":hook.codecNamespaceName?:@"",@"codecClass":hook.codecClassName?:@"",
                               @"codecGetterMethod":hook.codecGetterMethod?:@"",@"codecSetterMethod":hook.codecSetterMethod?:@"",
                               @"min":@(hook.minValue),@"max":@(hook.maxValue),@"default":@(hook.defaultValue),
                               @"prepared":@(hook.preparedDescriptor),
                               @"preparedRVA":@(hook.preparedRVA),
                               @"preparedUUID":hook.preparedUUID?:@"",
                               @"preparedIsStatic":@(hook.preparedIsStatic),
                               @"preparedCodecGetterRVA":@(hook.preparedCodecGetterRVA),
                               @"preparedCodecSetterRVA":@(hook.preparedCodecSetterRVA),
                               @"staticPrepatch":@(hook.staticPrepatch),
                               @"staticHookSlotRVA":@(hook.staticHookSlotRVA),
                               @"staticTrampolineRVA":@(hook.staticTrampolineRVA),
                               @"staticCodeCaveRVA":@(hook.staticCodeCaveRVA),
                               @"staticDisplacedInstruction":@(hook.staticDisplacedInstruction),
                               @"fallbackRVA":@(hook.fallbackRVA),@"fallbackUUID":hook.fallbackUUID?:@""}];
    }
    object[@"nativeHook"]=@{@"format":@"com.zonoe.native-hook/v1",@"engine":@"Dobby",@"count":@(hooks.count),@"actions":hookItems};
    NSData *updated=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];if(updated)[updated writeToFile:reportPath atomically:YES];
}

static BOOL ZNRABEmbedTableAtPath(NSString *path,NSData *table,NSString **error){
    int fd=open(path.fileSystemRepresentation,O_RDWR);if(fd<0){if(error)*error=[NSString stringWithFormat:@"打开 %@ 失败 errno=%d",path.lastPathComponent,errno];return NO;}struct stat st={};if(fstat(fd,&st)!=0||st.st_size<=0){close(fd);if(error)*error=@"读取生成物大小失败";return NO;}size_t fileSize=(size_t)st.st_size;uint8_t *base=(uint8_t *)mmap(NULL,fileSize,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(base==MAP_FAILED){close(fd);if(error)*error=@"mmap 生成物失败";return NO;}
    BOOL ok=NO;NSString *localError=nil;do{if(fileSize<sizeof(struct mach_header_64)){localError=@"生成物不是完整 Mach-O";break;}struct mach_header_64 *mh=(struct mach_header_64 *)base;if(mh->magic!=MH_MAGIC_64){localError=@"Runtime Action Builder 仅支持 thin 64-bit Mach-O";break;}uint64_t commandEnd=sizeof(*mh)+(uint64_t)mh->sizeofcmds;if(commandEnd>fileSize){localError=@"Mach-O load commands 越界";break;}struct segment_command_64 *owned=NULL;struct section_64 *zndata=NULL;uint8_t *cursor=base+sizeof(*mh),*limit=base+commandEnd;for(uint32_t i=0;i<mh->ncmds;i++){if(cursor+sizeof(struct load_command)>limit){localError=@"load command 损坏";break;}struct load_command *lc=(struct load_command *)cursor;if(lc->cmdsize<sizeof(*lc)||cursor+lc->cmdsize>limit){localError=@"load command size 损坏";break;}if(lc->cmd==LC_SEGMENT_64&&lc->cmdsize>=sizeof(struct segment_command_64)){struct segment_command_64 *seg=(struct segment_command_64 *)cursor;if(strncmp(seg->segname,"__ZNDATA",16)==0){owned=seg;uint64_t sectionBytes=(uint64_t)seg->nsects*sizeof(struct section_64);if(lc->cmdsize<sizeof(*seg)+sectionBytes){localError=@"__ZNDATA section table 越界";break;}struct section_64 *sections=(struct section_64 *)(seg+1);for(uint32_t j=0;j<seg->nsects;j++)if(strncmp(sections[j].sectname,"__zndata",16)==0){zndata=&sections[j];break;}}}cursor+=lc->cmdsize;}if(localError)break;if(!owned||!zndata){localError=@"生成物缺少 V3-owned __ZNDATA/__zndata";break;}if(owned->fileoff>fileSize||owned->filesize>fileSize-owned->fileoff){localError=@"__ZNDATA file range 越界";break;}if(zndata->offset>fileSize||zndata->size>fileSize-zndata->offset){localError=@"__zndata section range 越界";break;}if(zndata->size<sizeof(ZN44StaticHeader)){localError=@"__zndata 太小，缺少 Static Header";break;}ZN44StaticHeader *staticHeader=(ZN44StaticHeader *)(base+zndata->offset);if(staticHeader->magic0!=ZN44_STATIC_MAGIC0||staticHeader->magic1!=ZN44_STATIC_MAGIC1||staticHeader->entrySize!=sizeof(ZN44StaticEntry)||staticHeader->count>ZN44_STATIC_MAX_ENTRIES){localError=@"__zndata Static Dispatch Header 无效";break;}uint64_t actionRelative=0;if(!ZNGeneratedDataLayoutV1LocateRuntimeAction(base+zndata->offset,zndata->size,&actionRelative)){localError=@"__ZNDATA Generated Data Layout V1 无效";break;}uint64_t sectionStart=zndata->offset,actionOffset=sectionStart+actionRelative,segmentEnd=owned->fileoff+owned->filesize;if(actionOffset<sectionStart||actionOffset>segmentEnd||table.length>segmentEnd-actionOffset){localError=@"__ZNDATA owned capacity 不足";break;}if(actionOffset+table.length>fileSize){localError=@"Runtime Action 写入范围超出文件";break;}if(!ZNRABIsZeroRange(base+actionOffset,table.length)){localError=@"Runtime Action 目标区域不是 V3-owned zero padding；拒绝覆盖未知数据";break;}memcpy(base+actionOffset,table.bytes,table.length);uint64_t newSectionSize=(actionOffset-sectionStart)+table.length;if(newSectionSize>owned->filesize){localError=@"Runtime Action section size 超出 owned segment";break;}zndata->size=newSectionSize;if(msync(base,fileSize,MS_SYNC)!=0){localError=[NSString stringWithFormat:@"Runtime Action msync 失败 errno=%d",errno];break;}ok=YES;}while(0);munmap(base,fileSize);close(fd);if(!ok&&error)*error=localError?:@"Runtime Action 写入失败";return ok;
}

BOOL ZNRuntimeActionEmbedIntoGeneratedOutputs(NSArray<NSString *> *builderOutputs,NSString **report,NSString **error){
    NSArray<ZNRuntimeMethodAction *> *actions=[[ZNRuntimeActionStore sharedStore] actionsSnapshot];
    NSArray<ZNNativeHookAction *> *hooks=[[ZNNativeHookStore sharedStore] actionsSnapshot];
    if(!actions.count&&!hooks.count){if(report)*report=@"Runtime Action：无待导出 action";return YES;}
    NSString *serializeError=nil;NSData *table=ZNRABSerialize(actions,hooks,&serializeError);if(!table.length){if(error)*error=serializeError?:@"Runtime Action 序列化失败";return NO;}
    NSString *unityOutput=nil;for(NSString *path in builderOutputs){NSString *name=path.lastPathComponent.lowercaseString;if([name isEqualToString:@"unityframework"]||([name containsString:@"unityframework"]&&![name hasSuffix:@".json"])){unityOutput=path;break;}}
    if(!unityOutput.length){if(error)*error=@"存在 Runtime/Native Hook Action，但本次 Builder 没有 UnityFramework 二进制输出。";return NO;}
    NSString *embedError=nil;if(!ZNRABEmbedTableAtPath(unityOutput,table,&embedError)){if(error)*error=embedError?:@"Runtime Action 嵌入失败";return NO;}
    ZNRABUpdateBuildReport(builderOutputs,actions,hooks,table.length);
    if(report)*report=[NSString stringWithFormat:@"Runtime Action：Method=%lu Hook=%lu · %lu bytes · %@",(unsigned long)actions.count,(unsigned long)hooks.count,(unsigned long)table.length,unityOutput.lastPathComponent];
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[runtime-action] embedded method=%lu nativeHook=%lu bytes=%lu output=%@",(unsigned long)actions.count,(unsigned long)hooks.count,(unsigned long)table.length,unityOutput.lastPathComponent]];
    return YES;
}
