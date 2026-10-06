#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef BOOL (^ZNBuildCapabilityProbe)(void);

/// Registry is backend-facing. Any future buildable feature registers one probe.
/// UI must never inspect concrete hook/action stores.
@interface ZNBuildCapabilityRegistry : NSObject
+ (instancetype)sharedRegistry;
- (void)registerProviderIdentifier:(NSString *)identifier
             hasBuildableContent:(ZNBuildCapabilityProbe)probe;
- (void)unregisterProviderIdentifier:(NSString *)identifier;
- (BOOL)hasBuildableContent;
- (NSArray<NSString *> *)activeProviderIdentifiers;
@end

/// Single policy owner for whether the Build button is actionable.
@interface ZNBinaryBuildCoordinator : NSObject
+ (instancetype)sharedCoordinator;
@property(nonatomic,readonly) BOOL canBuild;
@property(nonatomic,copy,readonly) NSString *blockedReason;
@property(nonatomic,copy,readonly) NSArray<NSString *> *activeProviderIdentifiers;
@end

/// Convenience C ABI for future modules that should not depend on UI code.
FOUNDATION_EXPORT void ZNRegisterBuildCapabilityProvider(NSString *identifier,
                                                         ZNBuildCapabilityProbe probe);
FOUNDATION_EXPORT void ZNUnregisterBuildCapabilityProvider(NSString *identifier);

NS_ASSUME_NONNULL_END
