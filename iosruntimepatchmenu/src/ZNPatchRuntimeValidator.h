#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Developer-only runtime validator for a jailbroken/TrollStore-style test device.
// It never trusts JSON "original" bytes: the restore baseline is captured live
// from target + RVA before the temporary patch is applied.
@interface ZNPatchRuntimeValidator : NSObject
+ (instancetype)sharedValidator;

@property(nonatomic,copy,readonly) NSString *target;
@property(nonatomic,assign,readonly) uint64_t rva;
@property(nonatomic,copy,readonly,nullable) NSData *patchBytes;
@property(nonatomic,copy,readonly,nullable) NSData *capturedOriginalBytes;
@property(nonatomic,copy,readonly,nullable) NSData *currentBytes;
@property(nonatomic,assign,readonly) uintptr_t runtimeAddress;
@property(nonatomic,assign,readonly,getter=isConfigured) BOOL configured;
@property(nonatomic,assign,readonly,getter=isValidated) BOOL validated;
@property(nonatomic,assign,readonly,getter=isApplied) BOOL applied;
@property(nonatomic,copy,readonly) NSString *lastResult;

- (BOOL)configureTarget:(NSString *)target
           offsetString:(NSString *)offsetString
               patchHex:(NSString *)patchHex
                  error:(NSString * _Nullable * _Nullable)error;

// Binary/runtime preflight only. Captures the live bytes as the session restore
// baseline when the target is still unpatched.
- (BOOL)validate:(NSString * _Nullable * _Nullable)error;

// Temporary runtime apply for the developer's capable test device. Before
// touching the real target it requires the dedicated executable-page probe to
// have passed, then performs write/read-back/protection-restore verification.
- (BOOL)applyTemporary:(NSString * _Nullable * _Nullable)error;

// Restores the exact bytes captured by validate/apply in this process.
- (BOOL)restoreOriginal:(NSString * _Nullable * _Nullable)error;

- (void)clearSession;
- (NSArray<NSString *> *)diagnosticLines;
- (NSString *)diagnosticReport;
@end

NS_ASSUME_NONNULL_END
