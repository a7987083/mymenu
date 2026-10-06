#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, ZNBuildItemDomain) {
    ZNBuildItemDomainStatic = 1,
    ZNBuildItemDomainRuntime = 2,
};

@interface ZNBuildItem : NSObject
@property(nonatomic,copy) NSString *providerIdentifier;
@property(nonatomic,copy) NSString *kind;
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,assign) ZNBuildItemDomain domain;
@property(nonatomic,copy) NSDictionary<NSString *, id> *metadata;
+ (instancetype)itemWithProvider:(NSString *)provider
                            kind:(NSString *)kind
                      identifier:(NSString *)identifier
                          domain:(ZNBuildItemDomain)domain
                        metadata:(NSDictionary<NSString *, id> *)metadata;
@end

NS_ASSUME_NONNULL_END
