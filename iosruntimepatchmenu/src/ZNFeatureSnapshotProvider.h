#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZNFeatureSnapshotProvider : NSObject
+ (instancetype)sharedProvider;

// Immutable feature dictionaries preserving the existing ZNF1 grouping rules.
// Keys: key, featureID, title, records, controlType, valueType, sliderMax.
- (NSArray<NSDictionary *> *)currentFeatures;

@property(nonatomic,assign,readonly) uint64_t generation;
@end

NS_ASSUME_NONNULL_END
