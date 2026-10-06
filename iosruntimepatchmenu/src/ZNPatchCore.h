#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZNPatchState) {
    ZNPatchStateUninitialized = 0,
    ZNPatchStateReady,
    ZNPatchStateEnabled,
    ZNPatchStateDisabled,
    ZNPatchStateUnsupported,
    ZNPatchStateFailed,
    ZNPatchStateWaitingModule,
    ZNPatchStateResolving,
    ZNPatchStateTargetMissing,
    ZNPatchStateByteMismatch,
    ZNPatchStateConflict,
};

// Generic public Feature controls. Preserve the historical numeric values for
// Switch/Slider/Button and append Number so existing descriptors stay ABI/
// behavior compatible. M2.2 aliases Toggle/Action to the established names.
typedef NS_ENUM(NSInteger, ZNFeatureControlType) {
    ZNFeatureControlTypeSwitch = 0,
    ZNFeatureControlTypeSlider = 1,
    ZNFeatureControlTypeButton = 2,
    ZNFeatureControlTypeNumber = 3,
};
#define ZNFeatureControlTypeToggle ZNFeatureControlTypeSwitch
#define ZNFeatureControlTypeAction ZNFeatureControlTypeButton

typedef NS_ENUM(NSInteger, ZNPatchActionType) {
    ZNPatchActionTypeBytes = 0,
    ZNPatchActionTypeValue,
    ZNPatchActionTypeIL2CPPMethod,
    ZNPatchActionTypeIL2CPPField,
    ZNPatchActionTypeIL2CPPInvoke,
};

@interface ZNPatchActionDescriptor : NSObject
@property(nonatomic,copy,readonly) NSString *identifier;
@property(nonatomic,assign,readonly) ZNPatchActionType type;
@property(nonatomic,copy) NSString *module;
@property(nonatomic,assign) uint64_t rva;
@property(nonatomic,copy) NSString *assemblyName;
@property(nonatomic,copy) NSString *namespaceName;
@property(nonatomic,copy) NSString *className;
@property(nonatomic,copy) NSString *memberName;
@property(nonatomic,assign) NSInteger argumentCount;
@property(nonatomic,assign) ZNPatchState state;
@property(nonatomic,assign) uintptr_t resolvedAddress;
@property(nonatomic,copy) NSString *lastError;
- (instancetype)initWithIdentifier:(NSString *)identifier type:(ZNPatchActionType)type;
@end

@interface ZNPatchDescriptor : NSObject
@property(nonatomic,copy,readonly) NSString *identifier;
@property(nonatomic,copy,readonly) NSString *name;
@property(nonatomic,copy,readonly) NSString *category;
@property(nonatomic,copy) NSString *backend;
@property(nonatomic,assign) ZNPatchState state;
@property(nonatomic,assign) BOOL enabled;
@property(nonatomic,assign) double value;
@property(nonatomic,assign) ZNFeatureControlType controlType;
@property(nonatomic,copy) NSArray<ZNPatchActionDescriptor *> *actions;
@property(nonatomic,copy) NSString *lastError;
- (instancetype)initWithIdentifier:(NSString *)identifier
                              name:(NSString *)name
                          category:(NSString *)category
                           backend:(NSString *)backend
                             value:(double)value;
@end

@interface ZNRuntimeLogger : NSObject
+ (instancetype)sharedLogger;
- (void)log:(NSString *)message;
- (NSArray<NSString *> *)recentLines:(NSUInteger)limit;
- (void)clear;
@end

@interface ZNModuleManager : NSObject
+ (instancetype)sharedManager;
@property(nonatomic,assign,readonly) uint64_t moduleGeneration;
- (NSArray<NSDictionary<NSString *, id> *> *)loadedImages;
- (nullable NSDictionary<NSString *, id> *)mainExecutable;
- (nullable NSDictionary<NSString *, id> *)unityFramework;
- (nullable NSDictionary<NSString *, id> *)moduleNamed:(NSString *)moduleName;
- (uintptr_t)runtimeAddressForModule:(NSString *)moduleName rva:(uint64_t)rva;
- (NSString *)diagnosticReport;
@end

@interface ZNPatchManager : NSObject
+ (instancetype)sharedManager;
- (BOOL)enabledForFeature:(NSString *)identifier;
- (void)setFeature:(NSString *)identifier enabled:(BOOL)enabled;
- (double)valueForFeature:(NSString *)identifier fallback:(double)fallback;
- (void)setFeature:(NSString *)identifier value:(double)value;
@property(nonatomic,copy,readonly) NSArray<ZNPatchDescriptor *> *allDescriptors;
@property(nonatomic,assign,readonly) NSUInteger actionCount;
@property(nonatomic,copy,readonly) NSDictionary<NSString *, NSNumber *> *stateCounts;
- (nullable ZNPatchDescriptor *)descriptorForIdentifier:(NSString *)identifier;
- (void)refreshResolution;
- (NSString *)diagnosticReport;
- (BOOL)runSelfTest;
@end

FOUNDATION_EXPORT NSString *ZNStringForPatchState(ZNPatchState state);
FOUNDATION_EXPORT NSString *ZNStringForControlType(ZNFeatureControlType type);

NS_ASSUME_NONNULL_END
