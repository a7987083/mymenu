#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <errno.h>
#import <stdlib.h>

#import "ZNBinaryPatchWorkspace.h"
#import "ZNIL2CPPHybridFinder.h"
#import "ZNPatchRuntimeValidator.h"

extern "C" void ZNInstallIL2CPPMethodFinderUIDeferred(void);
extern "C" void ZNInstallIL2CPPMethodFinderMenuBindingDeferred(void);

// v0.5.7 Named Offset integration.
//
// This layer is authoring-time only. A symbolic Offset is resolved when the
// developer explicitly taps “读取验证”, then the existing Runtime Validator and
// Static Builder continue to use the resolved numeric UnityFramework RVA. No
// IL2CPP lookup is performed before the first menu activation, and generated
// binaries have no runtime dependency on these symbolic names.

static NSString *ZN57Trim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL ZN57ParseNumericRVA(NSString *text, uint64_t *outValue) {
    NSString *s = ZN57Trim(text).lowercaseString;
    if (!s.length) return NO;
    const char *c = s.UTF8String;
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(c, &end, 0);
    if (errno || end == c || (end && *end)) {
        errno = 0;
        end = NULL;
        value = strtoull(c, &end, 16);
    }
    if (errno || end == c || (end && *end)) return NO;
    if (outValue) *outValue = (uint64_t)value;
    return YES;
}

static NSString *ZN57ShortCanonical(NSDictionary *resolution) {
    NSString *className = resolution[@"class"] ?: @"";
    NSString *namespaceName = resolution[@"namespace"] ?: @"";
    NSString *method = resolution[@"method"] ?: @"";
    NSInteger arguments = [resolution[@"argumentCount"] integerValue];
    NSString *owner = className;
    if (namespaceName.length && className.length) owner = [NSString stringWithFormat:@"%@.%@", namespaceName, className];
    if (!owner.length) return method;
    return arguments >= 0
        ? [NSString stringWithFormat:@"%@::%@/%ld", owner, method, (long)arguments]
        : [NSString stringWithFormat:@"%@::%@", owner, method];
}

@interface ZNBinaryPatchWorkspace (ZNIL2CPPNamedOffsetV1)
- (BOOL)zn57_validateAll:(NSString * _Nullable * _Nullable)error;
@end

@implementation ZNBinaryPatchWorkspace (ZNIL2CPPNamedOffsetV1)

- (BOOL)zn57_validateAll:(NSString **)error {
    NSMutableArray<NSDictionary *> *symbolic = [NSMutableArray array];
    ZNIL2CPPHybridFinder *finder = [ZNIL2CPPHybridFinder sharedFinder];

    // Resolve every symbolic row first without mutating workspace state. This
    // makes ambiguity/error handling transactional: if one name is not unique,
    // no other row is silently converted or validated against the wrong site.
    for (NSUInteger index = 0; index < self.rows.count; index++) {
        ZNBinaryPatchRow *row = self.rows[index];
        NSString *offset = ZN57Trim(row.offsetText);
        if (!offset.length) continue;

        uint64_t numeric = 0;
        if (ZN57ParseNumericRVA(offset, &numeric)) continue;

        NSString *resolveError = nil;
        NSDictionary *resolution = [finder resolveExpression:offset error:&resolveError];
        if (!resolution) {
            NSString *message = [NSString stringWithFormat:@"#%lu %@",
                                 (unsigned long)index + 1,
                                 resolveError ?: @"IL2CPP Method Finder 解析失败"];
            row.validated = NO;
            row.validator = nil;
            row.originalHex = @"";
            row.statusText = [NSString stringWithFormat:@"❌ %@", resolveError ?: @"Method Finder 解析失败"];
            self.lastStatus = message;
            if (error) *error = message;
            return NO;
        }

        NSString *rvaText = resolution[@"rvaText"];
        if (!rvaText.length) {
            NSString *message = [NSString stringWithFormat:@"#%lu IL2CPP Method Finder 未返回 RVA", (unsigned long)index + 1];
            row.validated = NO;
            row.validator = nil;
            row.originalHex = @"";
            row.statusText = [NSString stringWithFormat:@"❌ %@", message];
            self.lastStatus = message;
            if (error) *error = message;
            return NO;
        }

        [symbolic addObject:@{
            @"row": row,
            @"expression": offset,
            @"rvaText": rvaText,
            @"resolution": resolution,
        }];
    }

    // A symbolic IL2CPP method intrinsically belongs to UnityFramework. Route
    // that row explicitly so the user can type only `GetMoney` + patch bytes;
    // the top-level Binary field does not need to be changed manually.
    //
    // The original validator pipeline still performs ARM64 alignment,
    // executable-segment checks, live Original capture, Shared Site grouping,
    // and Builder preconditions. We feed it temporary numeric RVAs so none of
    // those safety checks are bypassed.
    for (NSDictionary *item in symbolic) {
        ZNBinaryPatchRow *row = item[@"row"];
        row.target = @"UnityFramework";
        row.explicitTarget = YES;
        row.offsetText = item[@"rvaText"];
    }

    BOOL ok = [self zn57_validateAll:error]; // swapped original implementation

    // Keep the user's symbolic authoring expression visible. The attached
    // ZNPatchRuntimeValidator retains the resolved numeric RVA for temporary
    // apply and Static Binary Builder V3.
    for (NSDictionary *item in symbolic) {
        ZNBinaryPatchRow *row = item[@"row"];
        NSDictionary *resolution = item[@"resolution"];
        row.offsetText = item[@"expression"];
        if (row.validated && row.validator) {
            NSString *shortName = ZN57ShortCanonical(resolution);
            NSString *rvaText = resolution[@"rvaText"] ?: @"?";
            uint64_t preferredVA = [resolution[@"preferredVA"] unsignedLongLongValue];
            uint64_t runtimeVA = [resolution[@"runtimeVA"] unsignedLongLongValue];
            NSString *pointerKind = resolution[@"pointerKind"] ?: resolution[@"pointerSource"] ?: @"?";
            row.statusText = [NSString stringWithFormat:@"✅ IL2CPP %@ → RVA %@ · IDA 0x%llX · Runtime 0x%llX · %@",
                              shortName.length ? shortName : item[@"expression"],
                              rvaText,
                              (unsigned long long)preferredVA,
                              (unsigned long long)runtimeVA,
                              pointerKind];
        }
    }

    if (ok && symbolic.count) {
        self.lastStatus = [NSString stringWithFormat:@"读取验证通过：%lu 个 IL2CPP Method Finder 结果已解析并固定到 UnityFramework；生成阶段使用已验证 RVA",
                           (unsigned long)symbolic.count];
    }
    return ok;
}

@end

extern "C" void ZNInstallIL2CPPNamedOffsetWorkspaceDeferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = ZNBinaryPatchWorkspace.class;
        Method original = class_getInstanceMethod(cls, @selector(validateAll:));
        Method replacement = class_getInstanceMethod(cls, @selector(zn57_validateAll:));
        if (!original || !replacement) return;
        method_exchangeImplementations(original, replacement);

        // Method Finder remains part of the same authoring-time deferred stage:
        // no new constructor/+load and nothing runs before first ZN activation.
        ZNInstallIL2CPPMethodFinderUIDeferred();
        ZNInstallIL2CPPMethodFinderMenuBindingDeferred();
    });
}
