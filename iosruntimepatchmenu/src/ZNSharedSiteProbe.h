#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZNSharedSiteProbe : NSObject
+ (instancetype)sharedProbe;

@property(nonatomic,assign,readonly,getter=isInstalled) BOOL installed;
@property(nonatomic,assign,readonly,getter=isLoggingEnabled) BOOL loggingEnabled;
@property(nonatomic,copy,readonly) NSString *targetClassName;
@property(nonatomic,copy,readonly) NSString *lastStatus;
@property(nonatomic,copy,readonly) NSString *logPath;

- (BOOL)installAndEnable:(NSString * _Nullable * _Nullable)error;
- (void)setLoggingEnabled:(BOOL)enabled;
- (void)captureCurrentStateWithLabel:(NSString *)label;
- (void)clearLog;
- (NSString *)logText;
- (NSArray<NSString *> *)diagnosticLines;

@end

NS_ASSUME_NONNULL_END
