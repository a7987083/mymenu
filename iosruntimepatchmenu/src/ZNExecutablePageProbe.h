#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZNExecutablePageProbe : NSObject
+ (instancetype)sharedProbe;
@property(nonatomic,assign,readonly) BOOL hasRun;
@property(nonatomic,assign,readonly) BOOL supported;
@property(nonatomic,assign,readonly) double durationMs;
@property(nonatomic,copy,readonly) NSString *lastResult;
- (BOOL)runProbe;
- (NSString *)diagnosticReport;
@end

NS_ASSUME_NONNULL_END
