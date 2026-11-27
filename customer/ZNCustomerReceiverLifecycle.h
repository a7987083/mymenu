#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Main-thread Customer UI only. A failed resolution supplies identity, not a
// persisted object address. Choice objects own temporary GC handles.
@interface ZNCustomerReceiverChoice : NSObject
@property(nonatomic,readonly) NSString *displayTitle;
@end

@interface ZNCustomerReceiverRequest : NSObject
@property(nonatomic,readonly) NSString *assembly;
@property(nonatomic,readonly) NSString *namespaceName;
@property(nonatomic,readonly) NSString *className;
@property(nonatomic,readonly) NSArray<ZNCustomerReceiverChoice *> *choices;
- (BOOL)prepareChoices:(NSString * _Nullable * _Nullable)error;
- (BOOL)selectChoice:(ZNCustomerReceiverChoice *)choice error:(NSString * _Nullable * _Nullable)error;
@end

void ZNCustomerBeginReceiverSelectionCapture(void);
ZNCustomerReceiverRequest * _Nullable ZNCustomerEndReceiverSelectionCapture(void);

NS_ASSUME_NONNULL_END
