#pragma once
#import <Foundation/Foundation.h>
#import "ZNBuildItem.h"

NS_ASSUME_NONNULL_BEGIN

@class ZNBinaryPatchWorkspace;
@class ZNBuildManifest;

typedef NSArray<ZNBuildItem *> * _Nonnull (^ZNBuildItemCollector)(ZNBinaryPatchWorkspace *workspace);
typedef BOOL (^ZNBuildProviderPrepare)(ZNBuildManifest *manifest,
                                       ZNBinaryPatchWorkspace *workspace,
                                       NSString * _Nullable * _Nullable error);
typedef BOOL (^ZNBuildProviderEmit)(ZNBuildManifest *manifest,
                                    NSArray<NSString *> *builderOutputs,
                                    BOOL runtimeOnlyBase,
                                    NSString * _Nullable * _Nullable report,
                                    NSString * _Nullable * _Nullable error);

@interface ZNBuildManifest : NSObject
@property(nonatomic,copy,readonly) NSArray<ZNBuildItem *> *items;
@property(nonatomic,copy,readonly) NSArray<NSString *> *activeProviderIdentifiers;
@property(nonatomic,readonly) BOOL hasStaticItems;
@property(nonatomic,readonly) BOOL hasRuntimeItems;
@property(nonatomic,readonly) NSUInteger staticItemCount;
@property(nonatomic,readonly) NSUInteger runtimeItemCount;
@property(nonatomic,readonly) NSUInteger itemCount;
+ (instancetype)manifestForWorkspace:(ZNBinaryPatchWorkspace *)workspace;
@end

FOUNDATION_EXPORT void ZNRegisterBuildItemProvider(NSString *identifier,
                                                   ZNBuildItemCollector collector,
                                                   ZNBuildProviderPrepare _Nullable prepare,
                                                   ZNBuildProviderEmit _Nullable emit);
FOUNDATION_EXPORT void ZNUnregisterBuildItemProvider(NSString *identifier);

FOUNDATION_EXPORT BOOL ZNPrepareBuildManifestProviders(ZNBuildManifest *manifest,
                                                       ZNBinaryPatchWorkspace *workspace,
                                                       NSString * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL ZNEmitBuildManifestProviders(ZNBuildManifest *manifest,
                                                    NSArray<NSString *> *builderOutputs,
                                                    BOOL runtimeOnlyBase,
                                                    NSString * _Nullable * _Nullable report,
                                                    NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
