#import <Foundation/Foundation.h>
#import "ZNBinaryPatchWorkspace.h"
#import "ZNPatchCore.h"
#import "ZNValueTypeModel.h"

NS_ASSUME_NONNULL_BEGIN

// Reuse ZNPatchCore's established ZNFeatureControlType. M2.2 extends that enum
// with Number while preserving historical Switch/Slider/Button numeric values.
// Toggle and Action are semantic aliases declared in ZNPatchCore.h.

// Keep the existing 128-byte Static Entry ABI. Bits 8..10 of entry.flags are
// reserved for the public Feature control model. Legacy outputs leave them 0
// and therefore decode as Toggle/Switch.
#define ZN_FEATURE_CONTROL_FLAG_SHIFT 8u
#define ZN_FEATURE_CONTROL_FLAG_MASK  UINT32_C(0x00000700)

// M5.5 Typed Control Binding V2. Bits 11..13 store the seven-value public
// numeric type. Zero is Auto, so every legacy generated binary decodes safely.
#define ZN_FEATURE_VALUE_FLAG_SHIFT 11u
#define ZN_FEATURE_VALUE_FLAG_MASK  UINT32_C(0x00003800)

static inline uint32_t ZNFeatureControlFlags(ZNFeatureControlType type) {
    return (((uint32_t)type << ZN_FEATURE_CONTROL_FLAG_SHIFT) & ZN_FEATURE_CONTROL_FLAG_MASK);
}

static inline ZNFeatureControlType ZNFeatureControlTypeFromFlags(uint32_t flags) {
    uint32_t raw = (flags & ZN_FEATURE_CONTROL_FLAG_MASK) >> ZN_FEATURE_CONTROL_FLAG_SHIFT;
    switch (raw) {
        case ZNFeatureControlTypeSwitch:
        case ZNFeatureControlTypeSlider:
        case ZNFeatureControlTypeButton:
        case ZNFeatureControlTypeNumber:
            return (ZNFeatureControlType)raw;
        default:
            return ZNFeatureControlTypeSwitch;
    }
}

static inline uint32_t ZNFeatureValueTypeFlags(ZNValueType type) {
    return (((uint32_t)type << ZN_FEATURE_VALUE_FLAG_SHIFT) & ZN_FEATURE_VALUE_FLAG_MASK);
}

static inline ZNValueType ZNFeatureValueTypeFromFlags(uint32_t flags) {
    uint32_t raw = (flags & ZN_FEATURE_VALUE_FLAG_MASK) >> ZN_FEATURE_VALUE_FLAG_SHIFT;
    return raw <= ZNValueTypeF64 ? (ZNValueType)raw : ZNValueTypeAuto;
}

FOUNDATION_EXPORT NSString *ZNFeatureControlTypeName(ZNFeatureControlType type);
FOUNDATION_EXPORT ZNFeatureControlType ZNFeatureControlTypeForFeatureName(NSString *featureName);
FOUNDATION_EXPORT ZNValueType ZNFeatureValueTypeForFeatureName(NSString *featureName);

FOUNDATION_EXPORT NSNotificationName const ZNFeatureNumberValueDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const ZNFeatureSliderValueDidChangeNotification;
FOUNDATION_EXPORT NSNotificationName const ZNFeatureActionRequestedNotification;

@interface ZNBinaryPatchRow (ZNFeatureControlModel)
@property(nonatomic,assign) ZNFeatureControlType featureControlType;
@property(nonatomic,assign) ZNValueType featureValueType;
@end

@interface ZNBinaryPatchWorkspace (ZNFeatureControlEditingV2)
- (ZNFeatureControlType)controlTypeForFeature:(NSString *)featureName;
- (BOOL)setControlType:(ZNFeatureControlType)type
            forFeature:(NSString *)featureName
                 error:(NSString * _Nullable * _Nullable)error;
- (ZNValueType)valueTypeForFeature:(NSString *)featureName;
- (BOOL)setValueType:(ZNValueType)type
          forFeature:(NSString *)featureName
               error:(NSString * _Nullable * _Nullable)error;
- (BOOL)removeFeatureNamed:(NSString *)featureName
                     error:(NSString * _Nullable * _Nullable)error;
- (BOOL)removePatchAtGlobalIndex:(NSUInteger)index
                           error:(NSString * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
