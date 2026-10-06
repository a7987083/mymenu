#import "ZNBuildManifest.h"

#import "ZNBinaryPatchWorkspace.h"
#import "ZNFeatureControlModel.h"
#import "ZNRuntimeActionModel.h"
#import "ZNNativeHookAction.h"
#import "ZNNativeHookBuildPrepare.h"
#import "ZNNativeHookStaticPrepatch.h"
#import "ZNRuntimeActionBuilder.h"
#import "ZNRuntimeActionSignaturePostprocess.h"
#import "ZNM462RuntimeOnlyVerifier.h"
#import "ZNBuildStaticPrepare.h"

@interface ZNBuildProviderRecord : NSObject
@property(nonatomic,copy) NSString *identifier;
// Providers may share one physical serialization/emit stage without becoming
// one logical capability. This prevents capability-combination branches.
@property(nonatomic,copy) NSString *emitGroup;
@property(nonatomic,copy) ZNBuildItemCollector collector;
@property(nonatomic,copy) ZNBuildProviderPrepare prepare;
@property(nonatomic,copy) ZNBuildProviderEmit emit;
@end
@implementation ZNBuildProviderRecord @end

@interface ZNBuildProviderRegistry : NSObject
@property(nonatomic,strong) NSMutableDictionary<NSString *,ZNBuildProviderRecord *> *providers;
@property(nonatomic,assign) BOOL builtinsInstalled;
+ (instancetype)shared;
- (void)installBuiltinsIfNeeded;
@end

@interface ZNBuildManifest ()
@property(nonatomic,copy,readwrite) NSArray<ZNBuildItem *> *items;
@property(nonatomic,copy,readwrite) NSArray<NSString *> *activeProviderIdentifiers;
@end

static NSString *ZNM684Trim(NSString *s) {
    return [s ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL ZNM684RuntimeSignatureBridge(NSArray<NSString *> *builderOutputs,
                                         BOOL runtimeOnly,
                                         NSString **report,
                                         NSString **error) {
    if(!runtimeOnly)
        return ZNRuntimeActionAugmentGeneratedOutputsM46(builderOutputs,report,error);

    NSString *unity=nil;
    for(NSString *path in builderOutputs ?: @[]) {
        NSString *name=path.lastPathComponent.lowercaseString;
        if([name containsString:@"unityframework"] &&
           ![name hasSuffix:@".znpatched"] &&
           [NSFileManager.defaultManager fileExistsAtPath:path]) {
            unity=path; break;
        }
    }
    if(!unity.length)
        return ZNRuntimeActionAugmentGeneratedOutputsM46(builderOutputs,report,error);

    NSString *alias=[unity stringByAppendingString:@".znpatched"];
    [NSFileManager.defaultManager removeItemAtPath:alias error:nil];
    NSError *linkError=nil;
    if(![NSFileManager.defaultManager linkItemAtPath:unity toPath:alias error:&linkError]) {
        if(error)*error=[NSString stringWithFormat:@"Runtime Full Signature bridge 创建失败：%@",
                         linkError.localizedDescription ?: @"unknown"];
        return NO;
    }

    NSMutableArray<NSString *> *bridged=[builderOutputs mutableCopy] ?: [NSMutableArray array];
    [bridged addObject:alias];
    NSString *innerReport=nil,*innerError=nil;
    BOOL ok=ZNRuntimeActionAugmentGeneratedOutputsM46(bridged,&innerReport,&innerError);
    [NSFileManager.defaultManager removeItemAtPath:alias error:nil];
    if(!ok) {
        if(error)*error=innerError ?: @"Runtime Full Signature 写入失败";
        return NO;
    }
    if(report)*report=innerReport ?: @"Runtime Full Signature 完成";
    return YES;
}

static BOOL ZNM69PrepareRuntimeMethodProvider(NSString **error) {
    ZNRuntimeActionStore *store=[ZNRuntimeActionStore sharedStore];
    NSArray<ZNRuntimeMethodAction *> *actions=[store actionsSnapshot];
    for(NSUInteger actionIndex=0;actionIndex<actions.count;actionIndex++) {
        ZNRuntimeMethodAction *action=actions[actionIndex];
        if(action.argumentControlConfigs.count!=action.argumentCount)continue;
        NSMutableArray<NSDictionary<NSString *,id> *> *configs=[action.argumentControlConfigs mutableCopy];
        BOOL changed=NO;
        for(NSUInteger arg=0;arg<action.argumentCount;arg++) {
            NSDictionary *original=configs[arg];
            if(![original[@"enabled"] boolValue] ||
               ZNRuntimeArgumentControlTypeFromKey(original[@"type"])!=ZNRuntimeArgumentControlTypeSlider)
                continue;
            NSString *text=arg<action.argumentValues.count?ZNM684Trim(action.argumentValues[arg]):@"";
            NSDecimalNumber *number=text.length
                ? [NSDecimalNumber decimalNumberWithString:text locale:@{NSLocaleDecimalSeparator:@"."}]
                : NSDecimalNumber.notANumber;
            double maxValue=number.doubleValue;
            if(!text.length || [number isEqualToNumber:NSDecimalNumber.notANumber] ||
               !isfinite(maxValue) || maxValue<=0.0) {
                if(error)*error=[NSString stringWithFormat:@"%@ 参数%lu：滑块必须在生成时填写大于 0 的最大值",
                                 action.title.length?action.title:action.methodName,
                                 (unsigned long)arg+1];
                return NO;
            }
            NSMutableDictionary *cfg=[original mutableCopy];
            cfg[@"min"]=@0;cfg[@"max"]=number;cfg[@"step"]=@1;cfg[@"default"]=number;
            configs[arg]=[cfg copy];changed=YES;
        }
        if(changed) {
            NSString *local=nil;
            if(![store updateArgumentControlConfigs:configs atIndex:actionIndex error:&local]) {
                if(error)*error=local ?: @"Runtime Slider 范围写入失败";
                return NO;
            }
        }
    }
    return YES;
}

static BOOL ZNM69EmitRuntimeActionTable(ZNBuildManifest *manifest,
                                        NSArray<NSString *> *builderOutputs,
                                        BOOL runtimeOnlyBase,
                                        NSString **report,
                                        NSString **error) {
    NSString *embedReport=nil,*embedError=nil;
    if(!ZNRuntimeActionEmbedIntoGeneratedOutputs(builderOutputs ?: @[],&embedReport,&embedError)) {
        if(error)*error=embedError ?: @"Runtime Action 写入失败";
        return NO;
    }
    NSString *sigReport=nil,*sigError=nil;
    if(!ZNM684RuntimeSignatureBridge(builderOutputs ?: @[],runtimeOnlyBase,&sigReport,&sigError)) {
        if(error)*error=sigError ?: @"Runtime Full Signature 写入失败";
        return NO;
    }

    NSString *verifyReport=nil;
    if(runtimeOnlyBase) {
        NSUInteger expected=[[ZNRuntimeActionStore sharedStore] actionsSnapshot].count +
                            [[ZNNativeHookStore sharedStore] actionsSnapshot].count;
        NSString *verifyError=nil;
        if(!ZNM462VerifyRuntimeOnlyOutputs(builderOutputs ?: @[],expected,&verifyReport,&verifyError)) {
            if(error)*error=verifyError ?: @"Runtime-only Verify 失败";
            return NO;
        }
    }

    NSMutableArray<NSString *> *parts=[NSMutableArray array];
    for(NSString *piece in @[embedReport ?: @"",sigReport ?: @"",verifyReport ?: @""])
        if(piece.length)[parts addObject:piece];
    if(report)*report=[parts componentsJoinedByString:@"\n"];
    (void)manifest;
    return YES;
}

@implementation ZNBuildProviderRegistry
+ (instancetype)shared {
    static ZNBuildProviderRegistry *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r=[ZNBuildProviderRegistry new]; r.providers=[NSMutableDictionary dictionary]; });
    [r installBuiltinsIfNeeded];
    return r;
}

- (void)installBuiltinsIfNeeded {
    @synchronized(self) {
        if(self.builtinsInstalled)return;
        self.builtinsInstalled=YES;

        ZNBuildProviderRecord *staticProvider=[ZNBuildProviderRecord new];
        staticProvider.identifier=@"static-patch";
        staticProvider.emitGroup=@"static-patch";
        staticProvider.collector=^NSArray<ZNBuildItem *> *(ZNBinaryPatchWorkspace *workspace) {
            NSMutableArray<ZNBuildItem *> *items=[NSMutableArray array];
            [workspace.rows enumerateObjectsUsingBlock:^(ZNBinaryPatchRow *row, NSUInteger idx, BOOL *stop) {
                (void)stop;
                BOOL hasOffset=ZNM684Trim(row.offsetText).length>0;
                BOOL hasPatch=ZNM684Trim(row.enabledText).length>0;
                ZNFeatureControlType type=row.featureControlType;
                BOOL valueRow=(type==ZNFeatureControlTypeNumber || type==ZNFeatureControlTypeSlider);
                BOOL authored=valueRow ? hasOffset : (hasOffset && hasPatch);
                if(!authored)return;
                NSString *identity=[NSString stringWithFormat:@"row:%lu",(unsigned long)idx];
                NSDictionary *meta=@{@"rowIndex":@(idx),
                                     @"title":row.title ?: @"",
                                     @"group":row.group ?: @"",
                                     @"controlType":@(type)};
                [items addObject:[ZNBuildItem itemWithProvider:@"static-patch"
                                                          kind:@"static-patch"
                                                    identifier:identity
                                                        domain:ZNBuildItemDomainStatic
                                                      metadata:meta]];
            }];
            return items;
        };
        staticProvider.prepare=^BOOL(ZNBuildManifest *manifest, ZNBinaryPatchWorkspace *workspace, NSString **error) {
            (void)manifest;
            NSString *local=nil;
            if(workspace.filledCount && workspace.validatedCount!=workspace.filledCount) {
                if(![workspace validateAll:&local]) {
                    if(error)*error=local ?: workspace.lastStatus ?: @"Static BuildItem 验证失败";
                    return NO;
                }
            }
            if(!ZNBuildPrepareStaticWorkspaceV1(workspace,&local)) {
                if(error)*error=local ?: @"Static BuildManifest provider prepare 失败";
                return NO;
            }
            return YES;
        };
        self.providers[staticProvider.identifier]=staticProvider;

        ZNBuildProviderRecord *runtimeMethodProvider=[ZNBuildProviderRecord new];
        runtimeMethodProvider.identifier=@"runtime-method-call";
        runtimeMethodProvider.emitGroup=@"runtime-action-table";
        runtimeMethodProvider.collector=^NSArray<ZNBuildItem *> *(ZNBinaryPatchWorkspace *workspace) {
            (void)workspace;
            NSMutableArray<ZNBuildItem *> *items=[NSMutableArray array];
            NSArray<ZNRuntimeMethodAction *> *actions=[[ZNRuntimeActionStore sharedStore] actionsSnapshot];
            [actions enumerateObjectsUsingBlock:^(ZNRuntimeMethodAction *action, NSUInteger idx, BOOL *stop) {
                (void)stop;
                NSString *identity=action.canonicalIdentity.length?action.canonicalIdentity:[NSString stringWithFormat:@"runtime:%lu",(unsigned long)idx];
                [items addObject:[ZNBuildItem itemWithProvider:@"runtime-method-call"
                                                          kind:@"runtime-method"
                                                    identifier:identity
                                                        domain:ZNBuildItemDomainRuntime
                                                      metadata:@{@"index":@(idx),@"title":action.title ?: @""}]];
            }];
            return items;
        };
        runtimeMethodProvider.prepare=^BOOL(ZNBuildManifest *manifest,
                                            ZNBinaryPatchWorkspace *workspace,
                                            NSString **error) {
            (void)manifest;(void)workspace;
            return ZNM69PrepareRuntimeMethodProvider(error);
        };
        runtimeMethodProvider.emit=^BOOL(ZNBuildManifest *manifest,
                                         NSArray<NSString *> *builderOutputs,
                                         BOOL runtimeOnlyBase,
                                         NSString **report,
                                         NSString **error) {
            return ZNM69EmitRuntimeActionTable(manifest,builderOutputs,runtimeOnlyBase,report,error);
        };
        self.providers[runtimeMethodProvider.identifier]=runtimeMethodProvider;

        ZNBuildProviderRecord *nativeHookProvider=[ZNBuildProviderRecord new];
        nativeHookProvider.identifier=@"native-hook";
        nativeHookProvider.emitGroup=@"runtime-action-table";
        nativeHookProvider.collector=^NSArray<ZNBuildItem *> *(ZNBinaryPatchWorkspace *workspace) {
            (void)workspace;
            NSMutableArray<ZNBuildItem *> *items=[NSMutableArray array];
            NSArray<ZNNativeHookAction *> *hooks=[[ZNNativeHookStore sharedStore] actionsSnapshot];
            [hooks enumerateObjectsUsingBlock:^(ZNNativeHookAction *hook, NSUInteger idx, BOOL *stop) {
                (void)stop;
                NSString *identity=hook.canonicalIdentity.length?hook.canonicalIdentity:[NSString stringWithFormat:@"native-hook:%lu",(unsigned long)idx];
                [items addObject:[ZNBuildItem itemWithProvider:@"native-hook"
                                                          kind:@"native-hook"
                                                    identifier:identity
                                                        domain:ZNBuildItemDomainRuntime
                                                      metadata:@{@"index":@(idx),@"title":hook.title ?: @""}]];
            }];
            return items;
        };
        nativeHookProvider.prepare=^BOOL(ZNBuildManifest *manifest,
                                         ZNBinaryPatchWorkspace *workspace,
                                         NSString **error) {
            (void)manifest;(void)workspace;
            NSString *hookPrepareReport=nil,*hookPrepareError=nil;
            if(!ZNBuildPrepareNativeHookDescriptorsV1(&hookPrepareReport,&hookPrepareError)) {
                if(error)*error=hookPrepareError ?: @"Prepared Native Hook descriptor 生成失败";
                return NO;
            }
            return YES;
        };
        nativeHookProvider.emit=^BOOL(ZNBuildManifest *manifest,
                                      NSArray<NSString *> *builderOutputs,
                                      BOOL runtimeOnlyBase,
                                      NSString **report,
                                      NSString **error) {
            NSString *prepatchReport=nil,*prepatchError=nil;
            if(!ZNBuildInstallStaticPreparedNativeHooksV1(builderOutputs,&prepatchReport,&prepatchError)){
                if(error)*error=prepatchError ?: @"Static Prepared Native Hook 预埋失败";
                return NO;
            }
            NSString *tableReport=nil,*tableError=nil;
            if(!ZNM69EmitRuntimeActionTable(manifest,builderOutputs,runtimeOnlyBase,&tableReport,&tableError)){
                if(error)*error=tableError ?: @"Runtime Action Table emit 失败";
                return NO;
            }
            NSMutableArray<NSString *> *parts=[NSMutableArray array];
            if(prepatchReport.length)[parts addObject:prepatchReport];
            if(tableReport.length)[parts addObject:tableReport];
            if(report)*report=[parts componentsJoinedByString:@"\n"];
            return YES;
        };
        self.providers[nativeHookProvider.identifier]=nativeHookProvider;
    }
}
@end

@implementation ZNBuildManifest
+ (instancetype)manifestForWorkspace:(ZNBinaryPatchWorkspace *)workspace {
    ZNBuildManifest *manifest=[ZNBuildManifest new];
    NSMutableArray<ZNBuildItem *> *items=[NSMutableArray array];
    NSMutableArray<NSString *> *active=[NSMutableArray array];

    ZNBuildProviderRegistry *registry=[ZNBuildProviderRegistry shared];
    NSDictionary<NSString *,ZNBuildProviderRecord *> *snapshot=nil;
    @synchronized(registry){ snapshot=[registry.providers copy]; }

    for(NSString *key in [[snapshot allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        ZNBuildProviderRecord *provider=snapshot[key];
        NSArray<ZNBuildItem *> *provided=@[];
        @try { provided=provider.collector ? provider.collector(workspace) : @[]; }
        @catch(__unused NSException *e) { provided=@[]; }
        if(provided.count) {
            [items addObjectsFromArray:provided];
            [active addObject:key];
        }
    }
    manifest.items=[items copy];
    manifest.activeProviderIdentifiers=[active copy];
    return manifest;
}

- (NSUInteger)itemCount { return self.items.count; }
- (NSUInteger)staticItemCount {
    NSUInteger n=0; for(ZNBuildItem *item in self.items)if(item.domain==ZNBuildItemDomainStatic)n++; return n;
}
- (NSUInteger)runtimeItemCount {
    NSUInteger n=0; for(ZNBuildItem *item in self.items)if(item.domain==ZNBuildItemDomainRuntime)n++; return n;
}
- (BOOL)hasStaticItems { return self.staticItemCount>0; }
- (BOOL)hasRuntimeItems { return self.runtimeItemCount>0; }
@end

void ZNRegisterBuildItemProvider(NSString *identifier,
                                 ZNBuildItemCollector collector,
                                 ZNBuildProviderPrepare prepare,
                                 ZNBuildProviderEmit emit) {
    NSString *key=ZNM684Trim(identifier);
    if(!key.length||!collector)return;
    ZNBuildProviderRecord *record=[ZNBuildProviderRecord new];
    record.identifier=key; record.emitGroup=key; record.collector=[collector copy];
    record.prepare=[prepare copy]; record.emit=[emit copy];
    ZNBuildProviderRegistry *registry=[ZNBuildProviderRegistry shared];
    @synchronized(registry){ registry.providers[key]=record; }
}

void ZNUnregisterBuildItemProvider(NSString *identifier) {
    NSString *key=ZNM684Trim(identifier);
    if(!key.length)return;
    ZNBuildProviderRegistry *registry=[ZNBuildProviderRegistry shared];
    @synchronized(registry){
        if(![key isEqualToString:@"static-patch"] &&
           ![key isEqualToString:@"runtime-method-call"] &&
           ![key isEqualToString:@"native-hook"])
            [registry.providers removeObjectForKey:key];
    }
}

BOOL ZNPrepareBuildManifestProviders(ZNBuildManifest *manifest,
                                     ZNBinaryPatchWorkspace *workspace,
                                     NSString **error) {
    ZNBuildProviderRegistry *registry=[ZNBuildProviderRegistry shared];
    NSDictionary *snapshot=nil; @synchronized(registry){ snapshot=[registry.providers copy]; }
    for(NSString *identifier in manifest.activeProviderIdentifiers ?: @[]) {
        ZNBuildProviderRecord *provider=snapshot[identifier];
        if(provider.prepare && !provider.prepare(manifest,workspace,error))return NO;
    }
    return YES;
}

BOOL ZNEmitBuildManifestProviders(ZNBuildManifest *manifest,
                                  NSArray<NSString *> *builderOutputs,
                                  BOOL runtimeOnlyBase,
                                  NSString **report,
                                  NSString **error) {
    ZNBuildProviderRegistry *registry=[ZNBuildProviderRegistry shared];
    NSDictionary *snapshot=nil; @synchronized(registry){ snapshot=[registry.providers copy]; }
    NSMutableArray<NSString *> *parts=[NSMutableArray array];
    NSMutableSet<NSString *> *emittedGroups=[NSMutableSet set];
    for(NSString *identifier in manifest.activeProviderIdentifiers ?: @[]) {
        ZNBuildProviderRecord *provider=snapshot[identifier];
        if(!provider.emit)continue;
        NSString *group=provider.emitGroup.length?provider.emitGroup:identifier;
        if([emittedGroups containsObject:group])continue;
        NSString *piece=nil,*local=nil;
        if(!provider.emit(manifest,builderOutputs,runtimeOnlyBase,&piece,&local)) {
            if(error)*error=local ?: [NSString stringWithFormat:@"%@ emit 失败",identifier];
            return NO;
        }
        [emittedGroups addObject:group];
        if(piece.length)[parts addObject:piece];
    }
    if(report)*report=[parts componentsJoinedByString:@"\n"];
    return YES;
}
