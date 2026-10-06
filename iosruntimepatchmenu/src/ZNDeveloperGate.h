#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZNIdentitySource) {
    ZNIdentitySourceNone = 0,
    ZNIdentitySourceHostDylib,
    ZNIdentitySourceZonoeLocalTicket,
    ZNIdentitySourceSubmittedHost,
    ZNIdentitySourceMarkerFile,
};

@interface ZNDeveloperGate : NSObject
@property(nonatomic,assign,readonly) BOOL markerPresent;
// `g` token in file 1: controls Diagnostics + Debug.
@property(nonatomic,assign,readonly) BOOL authorized;
// `q` token in file 1: controls the Other category.
@property(nonatomic,assign,readonly) BOOL otherAuthorized;
@property(nonatomic,assign,readonly) BOOL hostBridgeAvailable;
@property(nonatomic,copy,readonly) NSString *markerPath;
@property(nonatomic,copy,readonly) NSString *authorizedUDID;
@property(nonatomic,copy,readonly) NSString *observedUDID;
@property(nonatomic,assign,readonly) ZNIdentitySource identitySource;
@property(nonatomic,copy,readonly) NSString *lastError;
@property(nonatomic,assign,readonly) BOOL awaitingZonoe;
+ (instancetype)sharedGate;
- (void)refresh;
- (void)requestZonoeValidation;
- (void)submitHostUDID:(nullable NSString *)udid authorized:(BOOL)authorized;
- (NSString *)sourceDescription;
- (NSString *)maskedUDID:(NSString *)udid;
- (NSString *)diagnosticReport;
@end

#ifdef __cplusplus
extern "C" {
#endif
__attribute__((visibility("default"))) bool ZonoePatchDeveloperAuthorized(void);
__attribute__((visibility("default"))) bool ZonoePatchOtherAuthorized(void);
__attribute__((visibility("default"))) void ZonoePatchRequestUDIDValidation(void);
__attribute__((visibility("default"))) void ZonoePatchSubmitHostIdentity(const char * _Nullable udid, bool authorized);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
