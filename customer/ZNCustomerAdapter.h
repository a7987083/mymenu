#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSUInteger, ZNCustomerControlKind) {
    ZNCustomerControlSwitch,
    ZNCustomerControlButton,
    ZNCustomerControlNumber,
    ZNCustomerControlSlider
};
@interface ZNCustomerItem : NSObject
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,copy) NSString *title;
@property(nonatomic,copy) NSString *detail;
@property(nonatomic,assign) ZNCustomerControlKind kind;
@property(nonatomic,assign) BOOL enabled;
@property(nonatomic,assign) double minimum, maximum, value;
@end
@protocol ZNCustomerFeatureBackend <NSObject>
- (NSArray<ZNCustomerItem *> *)snapshot;
- (BOOL)setEnabled:(BOOL)enabled identifier:(NSString *)identifier error:(NSString * _Nullable * _Nullable)error;
- (BOOL)execute:(NSString *)identifier value:(nullable NSNumber *)value error:(NSString * _Nullable * _Nullable)error;
@end
@interface ZNCustomerAdapter : NSObject <ZNCustomerFeatureBackend>
+ (instancetype)shared;
@end
NS_ASSUME_NONNULL_END
