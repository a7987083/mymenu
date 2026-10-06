#import "ZNBinaryPatchWorkspace.h"
#import "ZNPatchRuntimeValidator.h"
#import "ZNPatchCore.h"
#import <objc/runtime.h>

@interface ZNBinaryPatchWorkspace (ZNOffsetV2InputPreservation)
- (BOOL)znov2_validateAll:(NSString **)error;
@end

@implementation ZNBinaryPatchWorkspace (ZNOffsetV2InputPreservation)

- (BOOL)znov2_validateAll:(NSString **)error {
    NSMutableArray<NSString *> *inputs = [NSMutableArray arrayWithCapacity:self.rows.count];
    for (ZNBinaryPatchRow *row in self.rows) [inputs addObject:row.offsetText ?: @""];

    // After method_exchangeImplementations this invokes the original
    // validateAll:, but every row uses Offset Resolver V2 validators.
    BOOL ok = [self znov2_validateAll:error];

    NSUInteger count = MIN(inputs.count, self.rows.count);
    for (NSUInteger i = 0; i < count; i++) self.rows[i].offsetText = inputs[i];

    // Runtime apply/static build already consume validator.rva, so Shared Site
    // identity remains canonical even though the visible input text is kept.
    if (ok) {
        NSMutableDictionary<NSString *, NSNumber *> *siteCounts = [NSMutableDictionary dictionary];
        for (ZNBinaryPatchRow *row in self.rows) {
            if (!row.validated || !row.validator) continue;
            NSString *identity = row.validator.target.length ? row.validator.target.lowercaseString : @"?";
            NSString *key = [NSString stringWithFormat:@"%@|%llx", identity, row.validator.rva];
            siteCounts[key] = @([siteCounts[key] unsignedIntegerValue] + 1);
        }
        BOOL shared = NO;
        for (NSNumber *n in siteCounts.allValues) {
            if (n.unsignedIntegerValue > 1) { shared = YES; break; }
        }
        if (shared && ![self.lastStatus containsString:@"Shared Site"]) {
            self.lastStatus = [self.lastStatus stringByAppendingString:@" · Shared Site 已按规范化地址识别"];
        }
    }
    return ok;
}

@end

extern "C" void ZNInstallBinaryPatchWorkspaceAddressV2Deferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = ZNBinaryPatchWorkspace.class;
        Method original = class_getInstanceMethod(cls, @selector(validateAll:));
        Method replacement = class_getInstanceMethod(cls, @selector(znov2_validateAll:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
        [[ZNRuntimeLogger sharedLogger] log:@"[offset-v2] workspace input preservation installed"];
    });
}
