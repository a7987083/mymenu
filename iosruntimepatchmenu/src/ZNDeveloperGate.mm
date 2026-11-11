#import "ZNDeveloperGate.h"
#import "ZNPatchCore.h"
#import "ZNDeferredBootstrap.h"
#import <UIKit/UIKit.h>

@implementation ZNDeveloperGate {
    BOOL _markerPresent;
    BOOL _authorized;
    BOOL _otherAuthorized;
    BOOL _hostBridgeAvailable;
    NSString *_markerPath;
    NSString *_authorizedUDID;
    NSString *_observedUDID;
    ZNIdentitySource _identitySource;
    NSString *_lastError;
    BOOL _awaitingZonoe;
    BOOL _markerHasG;
    BOOL _markerHasQ;
    BOOL _activationEvaluated;
}

+ (instancetype)sharedGate {
    static ZNDeveloperGate *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [ZNDeveloperGate new]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _markerPath = @"";
    _authorizedUDID = @"";
    _observedUDID = @"";
    _lastError = @"尚未检测";
    _identitySource = ZNIdentitySourceNone;
    _hostBridgeAvailable = NO;
    _awaitingZonoe = NO;
    _otherAuthorized = NO;
    _markerHasG = NO;
    _markerHasQ = NO;
    _activationEvaluated = NO;
    [self refresh];
    return self;
}

- (BOOL)markerPresent { return _markerPresent; }
- (BOOL)authorized { return _authorized; }
- (BOOL)otherAuthorized { return _otherAuthorized; }
- (BOOL)hostBridgeAvailable { return _hostBridgeAvailable; }
- (NSString *)markerPath { return _markerPath ?: @""; }
- (NSString *)authorizedUDID { return _authorizedUDID ?: @""; }
- (NSString *)observedUDID { return _observedUDID ?: @""; }
- (ZNIdentitySource)identitySource { return _identitySource; }
- (NSString *)lastError { return _lastError ?: @""; }
- (BOOL)awaitingZonoe { return _awaitingZonoe; }

// Developer build: all local authoring panels are available without marker file 1.
- (void)refresh {
    @synchronized(self) {
        if(_activationEvaluated)return;
        _activationEvaluated=YES;
        _authorized=YES;
        _otherAuthorized=YES;
        _markerPresent=NO;
        _markerPath=@"";
        _authorizedUDID=@"";
        _observedUDID=@"";
        _identitySource=ZNIdentitySourceNone;
        _lastError=@"";
        _hostBridgeAvailable=NO;
        _awaitingZonoe=NO;
        [[ZNRuntimeLogger sharedLogger] log:@"[dev-gate] developer build: all panels enabled"];
    }
}
- (void)requestZonoeValidation { [self refresh]; }
- (void)submitHostUDID:(NSString *)udid authorized:(BOOL)authorized {
    (void)udid; (void)authorized;
}
- (NSString *)sourceDescription {
    switch (_identitySource) {
        case ZNIdentitySourceMarkerFile: return @"首次点击标记文件";
        case ZNIdentitySourceHostDylib: return @"Host Dylib（已禁用）";
        case ZNIdentitySourceZonoeLocalTicket: return @"Local Ticket（已禁用）";
        case ZNIdentitySourceSubmittedHost: return @"Host Submitted（已禁用）";
        default: return @"无";
    }
}

- (NSString *)maskedUDID:(NSString *)udid {
    if (!udid.length) return @"";
    if (udid.length <= 8) return @"********";
    return [NSString stringWithFormat:@"%@****%@", [udid substringToIndex:4], [udid substringFromIndex:udid.length-4]];
}

- (NSString *)diagnosticReport {
    return @"开发端：所有功能已启用，不再检查文件 1";
}
@end

extern "C" __attribute__((visibility("default"))) bool ZonoePatchDeveloperAuthorized(void) {
    if (!ZNDeferredBootstrapIsActivated()) return false;
    return [ZNDeveloperGate sharedGate].authorized;
}

extern "C" __attribute__((visibility("default"))) bool ZonoePatchOtherAuthorized(void) {
    if (!ZNDeferredBootstrapIsActivated()) return false;
    return [ZNDeveloperGate sharedGate].otherAuthorized;
}

extern "C" __attribute__((visibility("default"))) void ZonoePatchRequestUDIDValidation(void) {
    if (!ZNDeferredBootstrapIsActivated()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ZNDeveloperGate sharedGate] requestZonoeValidation];
    });
}

extern "C" __attribute__((visibility("default"))) void ZonoePatchSubmitHostIdentity(const char *udid, bool authorized) {
    if (!ZNDeferredBootstrapIsActivated()) return;
    (void)udid;
    (void)authorized;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ZNDeveloperGate sharedGate] submitHostUDID:nil authorized:NO];
    });
}
