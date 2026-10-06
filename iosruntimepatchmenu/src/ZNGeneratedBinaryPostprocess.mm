#import "ZNGeneratedBinaryPostprocess.h"
#import "ZNStaticMetadataPrivacy.h"
#import "ZNStaticValueCellV1.h"
#import "ZNStaticRVAProtection.h"
#import "ZNAdhocMachOSigner.h"

BOOL ZNPostProcessGeneratedBinaryOutputs(NSArray<NSString *> *innerOutputs,
                                         NSString *innerReport,
                                         NSArray<NSString *> **outputs,
                                         NSString **report,
                                         NSString **error) {
    if (!innerOutputs.count) {
        if (error) *error = @"Static Binary Builder V3 未返回任何输出";
        return NO;
    }

    NSMutableArray<NSDictionary *> *signing = [NSMutableArray array];
    NSMutableArray<NSString *> *finalOutputs = [NSMutableArray arrayWithCapacity:innerOutputs.count];
    NSMutableDictionary<NSString *, NSString *> *renameMap = [NSMutableDictionary dictionary];
    NSString *failure = nil;
    NSString *folder = nil;
    NSUInteger totalEncodedNames = 0;
    NSUInteger totalValueCells = 0;
    NSUInteger totalProtectedRVAs = 0;
    NSUInteger generatedTargets = 0;

    for (NSString *path in innerOutputs) {
        if (![path.pathExtension.lowercaseString isEqualToString:@"znpatched"]) continue;
        generatedTargets++;
        if (!folder.length) folder = path.stringByDeletingLastPathComponent;

        // ZNF1 must run first: it materializes the authored Control Type and
        // Value Type into entry.flags. Value-cell augmentation consumes exactly
        // those flags to decide whether Number/Slider is MOV or FMOV and which
        // I32/U32/I64/U64/F32/F64 cell format to generate.
        NSUInteger encodedNames = 0;
        NSString *privacyError = nil;
        if (!ZNScrubStaticDisplayMetadataAtPath(path, &encodedNames, &privacyError)) {
            failure = [NSString stringWithFormat:@"%@：%@", path.lastPathComponent, privacyError ?: @"显示 metadata 编码失败"];
            break;
        }
        totalEncodedNames += encodedNames;

        NSUInteger convertedCells = 0;
        NSString *cellError = nil;
        if (!ZNStaticValueCellAugmentAtPath(path, &convertedCells, &cellError)) {
            failure = [NSString stringWithFormat:@"%@：%@", path.lastPathComponent, cellError ?: @"Static RW Value Cell 参数化失败"];
            break;
        }
        totalValueCells += convertedCells;

        // RVA protection is intentionally after value-cell augmentation because
        // augmentation needs plain Builder RVAs to walk the Protection-V2 source
        // chain. Signing remains last so the final code/data bytes are covered.
        NSUInteger protectedRVAs = 0;
        NSString *rvaError = nil;
        if (!ZN55ProtectStaticRVAsAtPath(path, &protectedRVAs, &rvaError)) {
            failure = [NSString stringWithFormat:@"%@：%@", path.lastPathComponent, rvaError ?: @"Static RVA Protection V1 失败"];
            break;
        }
        totalProtectedRVAs += protectedRVAs;

        NSDictionary *signMetadata = nil;
        NSString *signError = nil;
        if (!ZNAdhocResignMachOAtPath(path, &signMetadata, &signError)) {
            failure = [NSString stringWithFormat:@"%@：%@", path.lastPathComponent, signError ?: @"ad-hoc CodeDirectory 重建失败"];
            break;
        }

        NSString *finalName = [path.lastPathComponent stringByDeletingPathExtension];
        NSString *finalPath = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:finalName];
        [NSFileManager.defaultManager removeItemAtPath:finalPath error:nil];
        NSError *renameError = nil;
        if (![NSFileManager.defaultManager moveItemAtPath:path toPath:finalPath error:&renameError]) {
            failure = [NSString stringWithFormat:@"%@：移除 .znpatched 后缀失败：%@", path.lastPathComponent, renameError.localizedDescription ?: @"未知错误"];
            break;
        }
        renameMap[path] = finalPath;

        NSMutableDictionary *item = [signMetadata mutableCopy] ?: [NSMutableDictionary dictionary];
        item[@"stagingOutput"] = path;
        item[@"output"] = finalPath;
        item[@"suffixlessExport"] = @YES;
        item[@"encodedFeatureMetadataEntries"] = @(encodedNames);
        item[@"rwValueCellEntries"] = @(convertedCells);
        item[@"protectedStaticRVAEntries"] = @(protectedRVAs);
        [signing addObject:item];
    }

    if (!failure && generatedTargets == 0) failure = @"Builder 输出中没有 Static Builder V3 目标";
    if (failure) {
        if (folder.length) [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
        if (error) *error = [NSString stringWithFormat:@"生成后二进制后处理失败：%@", failure];
        return NO;
    }

    for (NSString *path in innerOutputs) {
        NSString *mapped = renameMap[path];
        [finalOutputs addObject:mapped ?: path];
    }

    for (NSString *path in finalOutputs) {
        if (![path.lastPathComponent isEqualToString:@"build_report.json"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data.length) continue;
        NSMutableDictionary *object = [[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] mutableCopy];
        if (![object isKindOfClass:NSMutableDictionary.class]) continue;

        object[@"generatedBinaryPipeline"] = @{
            @"mode": @"m5.6.2-rw-value-cell",
            @"builder": @"Static Binary Builder V3",
            @"postprocessOrder": @[@"Payload Layout V2 (Builder)", @"ZNF1", @"RW Value Cell V1", @"Static RVA Protection V1", @"Adhoc CodeDirectory", @"Suffixless Export"],
            @"runtimeBuilderSwizzle": @NO,
            @"asyncLoadOrderDependency": @NO,
            @"suffixlessBinaryName": @YES,
        };
        object[@"generatedBinarySignature"] = @{
            @"mode": @"zonoe-self-contained-adhoc",
            @"rebuiltBeforeExport": @YES,
            @"pageHashesVerified": @YES,
            @"outputs": signing,
            @"finalPackageResignRequired": @YES,
        };
        object[@"generatedBinaryPrivacy"] = @{
            @"targetMachODisplayNames": @NO,
            @"plainDisplayNamesPresent": @NO,
            @"embeddedFeatureID": @YES,
            @"displayMetadataCodec": @"ZNF1",
            @"encodedEntries": @(totalEncodedNames),
            @"displayNameStorage": @"generated-macho-static-entry-encoded",
            @"legacyRegistryFallbackWritten": @NO,
            @"hostPreferencesContainTargetRVANameMap": @NO,
            @"staticEntryABIPreserved": @YES,
        };
        object[@"generatedBinaryProtection"] = @{
            @"mode": @"payload-v2+rw-value-cell-v1+static-rva-protection-v1",
            @"plainStaticRVAFieldsPresent": @NO,
            @"protectedFields": @[@"siteRVA", @"offRVA", @"onRVA"],
            @"protectedEntries": @(totalProtectedRVAs),
            @"rwValueCellEntries": @(totalValueCells),
            @"perOutputNonce": @YES,
            @"integrityCheck": @YES,
            @"runtimeDecodesOnDemand": @YES,
            @"runtimeWritesPlainRVAsBackToStaticEntry": @NO,
            @"payloadProtectionV2": @YES,
            @"payloadLayout": @"fragmented-16-byte-slot-chain-v1",
            @"maxContiguousSourceInstructions": @1,
            @"runtimeExecutableWrites": @NO,
            @"runtimeTypedValueBackend": @"RW __ZNDATA value cells",
            @"directSiteBranchStillArchitectural": @YES,
        };

        NSData *updated = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
        if (updated) [updated writeToFile:path atomically:YES];
        break;
    }

    if (outputs) *outputs = [finalOutputs copy];
    if (report) {
        *report = [NSString stringWithFormat:@"%@\nM5.6.2：Static Number/Slider 在构建期转换为 RW __ZNDATA Value Cell；运行时只写数据页，不修改 executable page。Value-cell=%lu。替换回 IPA 后仍需正常整包重签。",
                   innerReport ?: @"Static Binary Builder V3 生成成功",
                   (unsigned long)totalValueCells];
    }
    return YES;
}
