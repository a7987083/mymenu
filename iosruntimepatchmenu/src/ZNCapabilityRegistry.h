#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSInteger, ZNCapabilityLifecycleState) {
    ZNCapabilityLifecycleStateRegistered=0,
    ZNCapabilityLifecycleStatePreparing,
    ZNCapabilityLifecycleStatePrepared,
    ZNCapabilityLifecycleStateFailed,
};
@protocol ZNRuntimeCapabilityAdapter <NSObject>
@property(nonatomic,copy,readonly) NSString *capabilityIdentifier;
- (BOOL)prepareForImageCount:(uint32_t)imageCount error:(NSString * _Nullable * _Nullable)error;
- (NSArray *)snapshotItems;
@optional
- (BOOL)activateItem:(id)item value:(nullable id)value error:(NSString * _Nullable * _Nullable)error;
- (BOOL)deactivateItem:(id)item error:(NSString * _Nullable * _Nullable)error;
@end
@interface ZNCapabilityRegistry : NSObject
+ (instancetype)sharedRegistry;
- (void)registerAdapter:(id<ZNRuntimeCapabilityAdapter>)adapter;
- (nullable id<ZNRuntimeCapabilityAdapter>)adapterForIdentifier:(NSString *)identifier;
- (NSArray<id<ZNRuntimeCapabilityAdapter>> *)adaptersSnapshot;
- (BOOL)prepareCapability:(NSString *)identifier imageCount:(uint32_t)imageCount error:(NSString * _Nullable * _Nullable)error;
- (BOOL)prepareAllForImageCount:(uint32_t)imageCount error:(NSString * _Nullable * _Nullable)error;
- (ZNCapabilityLifecycleState)stateForIdentifier:(NSString *)identifier;
- (nullable NSString *)lastErrorForIdentifier:(NSString *)identifier;
- (uint32_t)preparedImageCountForIdentifier:(NSString *)identifier;
@end
NS_ASSUME_NONNULL_END
