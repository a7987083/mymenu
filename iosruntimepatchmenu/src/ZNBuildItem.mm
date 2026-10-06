#import "ZNBuildItem.h"

@implementation ZNBuildItem
+ (instancetype)itemWithProvider:(NSString *)provider
                            kind:(NSString *)kind
                      identifier:(NSString *)identifier
                          domain:(ZNBuildItemDomain)domain
                        metadata:(NSDictionary<NSString *,id> *)metadata {
    ZNBuildItem *item=[ZNBuildItem new];
    item.providerIdentifier=provider ?: @"";
    item.kind=kind ?: @"";
    item.identifier=identifier ?: @"";
    item.domain=domain;
    item.metadata=metadata ?: @{};
    return item;
}
@end
