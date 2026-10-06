#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZNRuntimeExecutionKind) {
    ZNRuntimeExecutionKindMethodCall = 1,
    ZNRuntimeExecutionKindDirectNativeCall = 3,
};

typedef NS_ENUM(NSInteger, ZNRuntimeArgumentControlType) {
    ZNRuntimeArgumentControlTypeFixed = 0,
    ZNRuntimeArgumentControlTypeSwitch = 1,
    ZNRuntimeArgumentControlTypeButton = 2,
    ZNRuntimeArgumentControlTypeNumber = 3,
    ZNRuntimeArgumentControlTypeSlider = 4,
};

FOUNDATION_EXPORT NSString *ZNRuntimeArgumentControlTypeName(ZNRuntimeArgumentControlType type);
FOUNDATION_EXPORT NSString *ZNRuntimeArgumentControlTypeKey(ZNRuntimeArgumentControlType type);
FOUNDATION_EXPORT ZNRuntimeArgumentControlType ZNRuntimeArgumentControlTypeFromKey(NSString *key);

@interface ZNRuntimeMethodAction : NSObject <NSCopying>
@property(nonatomic,assign) uint32_t actionID;
@property(nonatomic,assign) ZNRuntimeExecutionKind executionKind;
@property(nonatomic,copy) NSString *title;
@property(nonatomic,copy) NSString *group;
@property(nonatomic,copy) NSString *featureDescription;
@property(nonatomic,copy) NSString *assembly;
@property(nonatomic,copy) NSString *namespaceName;
@property(nonatomic,copy) NSString *className;
@property(nonatomic,copy) NSString *methodName;
@property(nonatomic,assign) NSUInteger argumentCount;
@property(nonatomic,copy) NSArray<NSString *> *argumentValues;
// M4.6: full managed parameter-type identity. Empty + signatureAvailable=YES
// represents an exact zero-parameter signature; signatureAvailable=NO keeps
// legacy Method/N compatibility for records authored by older versions.
@property(nonatomic,copy) NSArray<NSString *> *parameterTypeNames;
@property(nonatomic,assign) BOOL signatureAvailable;
// M5.1: one dictionary per argument. enabled=NO means fixed value. enabled=YES
// exposes that argument in the generated menu using switch/button/number/slider.
@property(nonatomic,copy) NSArray<NSDictionary<NSString *, id> *> *argumentControlConfigs;
// M5.1 Immediate Chain. Empty means no chain. V1 stores a complete target
// method descriptor and never persists a returned object address/GCHandle.
@property(nonatomic,copy) NSDictionary<NSString *, id> *immediateChain;
@property(nonatomic,copy,readonly) NSString *canonicalIdentity;
@property(nonatomic,copy,readonly) NSString *legacyCanonicalIdentity;
@end

@interface ZNRuntimeActionStore : NSObject
+ (instancetype)sharedStore;
@property(nonatomic,copy,readonly) NSArray<ZNRuntimeMethodAction *> *actions;

- (nullable ZNRuntimeMethodAction *)addMethodCandidate:(NSDictionary<NSString *, id> *)candidate
                                                 title:(nullable NSString *)title
                                                 error:(NSString * _Nullable * _Nullable)error;
- (nullable ZNRuntimeMethodAction *)addMethodCandidate:(NSDictionary<NSString *, id> *)candidate
                                                 title:(nullable NSString *)title
                                        argumentValues:(NSArray<NSString *> *)argumentValues
                                                 error:(NSString * _Nullable * _Nullable)error;
- (nullable ZNRuntimeMethodAction *)addDirectNativeCallCandidate:(NSDictionary<NSString *, id> *)candidate
                                                          title:(nullable NSString *)title
                                                 argumentValues:(NSArray<NSString *> *)argumentValues
                                                          error:(NSString * _Nullable * _Nullable)error;
- (BOOL)updateTitle:(nullable NSString *)title
            atIndex:(NSUInteger)index
              error:(NSString * _Nullable * _Nullable)error;
- (BOOL)updateFeatureDescription:(nullable NSString *)featureDescription
                         atIndex:(NSUInteger)index
                           error:(NSString * _Nullable * _Nullable)error;
- (BOOL)updateArgumentValues:(NSArray<NSString *> *)argumentValues
                     atIndex:(NSUInteger)index
                       error:(NSString * _Nullable * _Nullable)error;
- (BOOL)updateArgumentControlConfigs:(NSArray<NSDictionary<NSString *, id> *> *)configs
                             atIndex:(NSUInteger)index
                               error:(NSString * _Nullable * _Nullable)error;
- (BOOL)updateImmediateChain:(nullable NSDictionary<NSString *, id> *)chain
                     atIndex:(NSUInteger)index
                       error:(NSString * _Nullable * _Nullable)error;
- (BOOL)removeActionAtIndex:(NSUInteger)index;
- (void)clear;
- (NSArray<ZNRuntimeMethodAction *> *)actionsSnapshot;
@end

NS_ASSUME_NONNULL_END
