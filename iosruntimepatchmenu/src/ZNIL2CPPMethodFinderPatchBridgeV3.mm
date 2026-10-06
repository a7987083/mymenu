#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// V3 candidate -> Builder bridge.
// The legacy Builder helper writes its current query into row.offsetText.
// For a multi-candidate search that query may be intentionally ambiguous
// (for example "gethp"). Preserve the user's search text in the Finder UI,
// but feed the selected candidate's canonical expression to Builder so the
// exact candidate remains selected through Runtime Validator.

@interface ZNRuntimeMenuControllerV040 : NSObject
- (NSDictionary *)zn60v3_selected;
- (NSString *)zn57mf_query;
- (void)zn57mf_setQuery:(NSString *)value;
- (void)zn57mf_setResult:(NSDictionary *)value;
- (void)zn60v3_createPatch:(id)sender;
@end

@interface ZNRuntimeMenuControllerV040 (ZNIL2CPPMethodFinderPatchBridgeV3)
- (void)zn61v3_createPatch:(id)sender;
@end

@implementation ZNRuntimeMenuControllerV040 (ZNIL2CPPMethodFinderPatchBridgeV3)

- (void)zn61v3_createPatch:(id)sender {
    NSDictionary *candidate = [self zn60v3_selected];
    NSString *canonical = [candidate[@"canonical"] isKindOfClass:NSString.class] ? candidate[@"canonical"] : @"";
    NSString *previousQuery = [self zn57mf_query] ?: @"";

    if (candidate && canonical.length) {
        [self zn57mf_setResult:candidate];
        [self zn57mf_setQuery:canonical];
    }

    // After method_exchangeImplementations this selector invokes the original
    // V3 create-Patch implementation, which in turn reuses the proven Builder
    // and Runtime Validator transaction chain.
    [self zn61v3_createPatch:sender];

    // Finder search history remains what the user typed; only the generated
    // Builder row receives the selected candidate's unambiguous expression.
    if (canonical.length) [self zn57mf_setQuery:previousQuery];
}

@end

extern "C" void ZNInstallIL2CPPMethodFinderPatchBridgeV3Deferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = NSClassFromString(@"ZNRuntimeMenuControllerV040");
        if (!cls) return;
        Method original = class_getInstanceMethod(cls, @selector(zn60v3_createPatch:));
        Method replacement = class_getInstanceMethod(cls, @selector(zn61v3_createPatch:));
        if (original && replacement) method_exchangeImplementations(original, replacement);
    });
}
