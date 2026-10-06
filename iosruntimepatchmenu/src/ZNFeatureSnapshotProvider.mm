#import "ZNFeatureSnapshotProvider.h"

#import "ZNFeatureControlModel.h"
#import "ZNFeatureMetadataCodec.h"
#import "ZNStaticDispatchRuntime.h"
#import "ZNRuntimeCapabilityCoordinator.h"
#import "ZNStaticPatchFormat.h"
#import "ZNValueTypeModel.h"

@interface ZNStaticPatchRecord (ZNFeatureSnapshotPrivate)
@property(nonatomic,assign) ZN44StaticEntry *entry;
@property(nonatomic,copy) NSString *target;
@property(nonatomic,assign) uint32_t patchID;
@property(nonatomic,copy) NSString *title;
@property(nonatomic,copy) NSString *group;
@end

@interface ZNFeatureSnapshotProvider ()
@property(nonatomic,copy) NSArray<NSDictionary *> *cachedFeatures;
@property(nonatomic,assign,readwrite) uint64_t generation;
@end

@implementation ZNFeatureSnapshotProvider

+ (instancetype)sharedProvider {
    static ZNFeatureSnapshotProvider *provider;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        provider = [ZNFeatureSnapshotProvider new];
        provider.cachedFeatures = @[];
        provider.generation = UINT64_MAX;
    });
    return provider;
}

static NSString *ZNFSTrim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSDictionary *ZNFSDisplay(ZNStaticPatchRecord *record) {
    NSDictionary *embedded = record.entry ? ZNFeatureMetadataDecodeEntry(record.entry) : nil;
    if (embedded) return embedded;

    NSString *title = ZNFSTrim(record.title);
    NSString *group = ZNFSTrim(record.group);
    if (!title.length || [title hasPrefix:@"Patch #"]) {
        title = [NSString stringWithFormat:@"功能 #%u", record.patchID];
    }
    if (!group.length) group = @"Imported";

    return @{
        @"featureID": @0,
        @"title": title,
        @"group": group,
        @"explicitGroup": @([group caseInsensitiveCompare:@"Imported"] != NSOrderedSame),
        @"controlType": @(ZNFeatureControlTypeSwitch),
        @"valueType": @(ZNValueTypeAuto),
        @"sliderMax": @0,
        @"source": @"legacy-entry",
    };
}

- (NSArray<NSDictionary *> *)currentFeatures {
    ZNRuntimeCapabilityCoordinator *coordinator=[ZNRuntimeCapabilityCoordinator sharedCoordinator];
    [coordinator requestRefresh];
    ZNRuntimeCapabilitySnapshot *snapshot=coordinator.currentSnapshot;
    uint64_t runtimeGeneration=snapshot.generation;
    if (self.generation == runtimeGeneration && self.cachedFeatures) {
        return self.cachedFeatures;
    }

    NSArray<ZNStaticPatchRecord *> *records = snapshot.staticRecords ?: @[];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<ZNStaticPatchRecord *> *> *members = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *metadata = [NSMutableDictionary dictionary];

    for (ZNStaticPatchRecord *record in records) {
        NSDictionary *display = ZNFSDisplay(record);
        NSString *group = ZNFSTrim(display[@"group"]);
        NSString *title = ZNFSTrim(display[@"title"]);
        uint64_t featureID = [display[@"featureID"] unsignedLongLongValue];
        BOOL explicitFeature = [display[@"explicitGroup"] boolValue] ||
            (group.length && [group caseInsensitiveCompare:@"Imported"] != NSOrderedSame);

        NSString *key = nil;
        if (featureID) {
            key = [NSString stringWithFormat:@"id:%016llx", featureID];
        } else if (explicitFeature) {
            key = [@"group:" stringByAppendingString:group.lowercaseString];
        } else {
            key = [NSString stringWithFormat:@"patch:%@:%u", record.target.lowercaseString ?: @"", record.patchID];
        }

        if (!members[key]) {
            members[key] = [NSMutableArray array];

            ZNFeatureControlType controlType = record.entry
                ? ZNFeatureControlTypeFromFlags(record.entry->flags)
                : ZNFeatureControlTypeSwitch;
            ZNValueType valueType = record.entry
                ? ZNFeatureValueTypeFromFlags(record.entry->flags)
                : ZNValueTypeAuto;
            NSNumber *sliderMax = [display[@"sliderMax"] isKindOfClass:NSNumber.class]
                ? display[@"sliderMax"] : @0;

            NSString *featureTitle = explicitFeature && group.length
                ? group
                : (title.length ? title : [NSString stringWithFormat:@"功能 #%u", record.patchID]);

            metadata[key] = [@{
                @"key": key,
                @"featureID": @(featureID),
                @"title": featureTitle ?: @"功能",
                @"description": record.featureDescription ?: @"",
                @"controlType": @(controlType),
                @"valueType": @(valueType),
                @"sliderMax": sliderMax,
            } mutableCopy];
            [order addObject:key];
        }
        [members[key] addObject:record];
    }

    NSMutableArray<NSDictionary *> *features = [NSMutableArray arrayWithCapacity:order.count];
    for (NSString *key in order) {
        NSMutableDictionary *item = [metadata[key] mutableCopy];
        item[@"records"] = [members[key] copy] ?: @[];
        [features addObject:[item copy]];
    }

    self.cachedFeatures = [features copy];
    self.generation = runtimeGeneration;
    return self.cachedFeatures;
}

@end
