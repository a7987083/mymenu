#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZNRuntimeMethodActionRecord : NSObject
@property(nonatomic,assign,readonly) uint32_t actionID;
@property(nonatomic,assign,readonly) NSInteger executionKind;
@property(nonatomic,copy,readonly) NSString *title;
@property(nonatomic,copy,readonly) NSString *group;
@property(nonatomic,copy,readonly) NSString *featureDescription;
@property(nonatomic,copy,readonly) NSString *assembly;
@property(nonatomic,copy,readonly) NSString *namespaceName;
@property(nonatomic,copy,readonly) NSString *className;
@property(nonatomic,copy,readonly) NSString *methodName;
@property(nonatomic,assign,readonly) NSUInteger argumentCount;
@property(nonatomic,copy,readonly) NSArray<NSString *> *argumentValues;
@property(nonatomic,copy,readonly) NSArray<NSString *> *parameterTypeNames;
@property(nonatomic,assign,readonly) BOOL signatureAvailable;
@property(nonatomic,copy,readonly) NSArray<NSDictionary<NSString *, id> *> *argumentControlConfigs;
@property(nonatomic,copy,readonly) NSDictionary<NSString *, id> *immediateChain;
@property(nonatomic,copy,readonly) NSString *sourceImage;
@property(nonatomic,copy,readonly) NSString *canonicalIdentity;
@end

@interface ZNRuntimeActionRuntime : NSObject
+ (instancetype)sharedRuntime;
@property(nonatomic,copy,readonly) NSArray<ZNRuntimeMethodActionRecord *> *records;
@property(nonatomic,copy,readonly) NSArray<ZNRuntimeMethodActionRecord *> *directRecords;
@property(nonatomic,copy,readonly) NSString *lastStatus;
- (void)refresh;
- (BOOL)executeRecord:(ZNRuntimeMethodActionRecord *)record error:(NSString * _Nullable * _Nullable)error;
- (NSArray<NSString *> *)diagnosticLines;
@end

NS_ASSUME_NONNULL_END
