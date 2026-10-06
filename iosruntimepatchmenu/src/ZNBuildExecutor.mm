#import "ZNBuildExecutor.h"

#import "ZNBuildManifest.h"
#import "ZNBinaryPatchWorkspace.h"
#import "ZNStaticBinaryBuilderV3Internal.h"
#import "ZNRuntimeOnlyBinaryBuilder.h"
#import "ZNGeneratedBinaryPostprocess.h"
#import "ZNPatchCore.h"

static NSArray<NSNumber *> *ZNM684StaticRowIndexes(ZNBuildManifest *manifest) {
    NSMutableArray<NSNumber *> *indexes=[NSMutableArray array];
    for(ZNBuildItem *item in manifest.items ?: @[]) {
        if(item.domain!=ZNBuildItemDomainStatic)continue;
        NSNumber *index=[item.metadata[@"rowIndex"] isKindOfClass:NSNumber.class] ? item.metadata[@"rowIndex"] : nil;
        if(index)[indexes addObject:index];
    }
    return [indexes copy];
}

BOOL ZNBuildExecutorBuildWorkspace(ZNBinaryPatchWorkspace *workspace,
                                   NSArray<NSString *> **outputs,
                                   NSString **report,
                                   NSString **error) {
    if(!workspace) {
        if(error)*error=@"Build workspace 不存在";
        return NO;
    }
    if(workspace.hasAnyApplied) {
        if(error)*error=@"生成前必须恢复所有临时 Runtime Patch";
        return NO;
    }

    ZNBuildManifest *manifest=[ZNBuildManifest manifestForWorkspace:workspace];
    if(!manifest.itemCount) {
        if(error)*error=@"没有可生成的 BuildItem";
        return NO;
    }

    BOOL runtimeOnlyBase=!manifest.hasStaticItems;
    ZNBinaryPatchWorkspace *buildWorkspace=workspace;
    if(manifest.hasStaticItems) {
        NSArray<NSNumber *> *indexes=ZNM684StaticRowIndexes(manifest);
        buildWorkspace=[workspace buildSnapshotForRowIndexes:indexes];
    }

    NSString *prepareError=nil;
    if(!ZNPrepareBuildManifestProviders(manifest,buildWorkspace,&prepareError)) {
        if(error)*error=prepareError ?: @"BuildItem prepare 失败";
        return NO;
    }

    NSArray<NSString *> *builderOutputs=nil;
    NSString *builderReport=nil,*builderError=nil;
    BOOL baseOK=runtimeOnlyBase
        ? ZNRuntimeOnlyBinaryBuilderBuildWorkspace(buildWorkspace,&builderOutputs,&builderReport,&builderError)
        : ZNStaticBinaryBuilderV3BuildWorkspace(buildWorkspace,&builderOutputs,&builderReport,&builderError);
    if(!baseOK) {
        if(error)*error=builderError ?: (runtimeOnlyBase ? @"Runtime-only base 生成失败" : @"Static base 生成失败");
        return NO;
    }

    NSString *providerReport=nil,*providerError=nil;
    if(!ZNEmitBuildManifestProviders(manifest,builderOutputs ?: @[],runtimeOnlyBase,&providerReport,&providerError)) {
        if(error)*error=providerError ?: @"BuildItem provider emit 失败";
        return NO;
    }

    NSString *combined=builderReport ?: @"";
    if(providerReport.length)
        combined=combined.length ? [combined stringByAppendingFormat:@"\n%@",providerReport] : providerReport;
    NSString *manifestLine=[NSString stringWithFormat:
        @"M6.8.4 BuildManifest：items=%lu static=%lu runtime=%lu providers=%@",
        (unsigned long)manifest.itemCount,
        (unsigned long)manifest.staticItemCount,
        (unsigned long)manifest.runtimeItemCount,
        [manifest.activeProviderIdentifiers componentsJoinedByString:@","]];
    combined=combined.length ? [combined stringByAppendingFormat:@"\n%@",manifestLine] : manifestLine;

    NSString *postError=nil;
    BOOL postOK=runtimeOnlyBase
        ? ZNRuntimeOnlyPostProcessGeneratedOutputsM461(builderOutputs ?: @[],combined,outputs,report,&postError)
        : ZNPostProcessGeneratedBinaryOutputs(builderOutputs ?: @[],combined,outputs,report,&postError);
    if(!postOK) {
        if(error)*error=postError ?: @"生成后二进制后处理失败";
        return NO;
    }

    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:
        @"[m6.8.4-build-manifest] items=%lu static=%lu runtime=%lu base=%@ providers=%@",
        (unsigned long)manifest.itemCount,
        (unsigned long)manifest.staticItemCount,
        (unsigned long)manifest.runtimeItemCount,
        runtimeOnlyBase?@"runtime-only":@"static",
        [manifest.activeProviderIdentifiers componentsJoinedByString:@","]]];
    return YES;
}
