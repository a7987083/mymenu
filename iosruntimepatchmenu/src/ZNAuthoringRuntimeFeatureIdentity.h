#import <Foundation/Foundation.h>

// Feature identity for schema v1 authoring records. Method identity is used only
// for IL2CPP resolution; distinct argument/control/chain configurations are
// independent features even when they invoke the same exact method.
// No RVA, generated actionID or unstable dictionary description is involved.
static inline NSDictionary<NSString *, id> *ZNAuthoringRuntimeFeatureIdentity(
    NSDictionary<NSString *, id> *record, NSString *methodIdentity) {
    NSString *method = [record[@"method"] isKindOfClass:NSString.class] ? record[@"method"] : @"";
    NSString *title = [record[@"title"] isKindOfClass:NSString.class] ? record[@"title"] : @"";
    title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!title.length) title = method;
    return @{
        @"methodIdentity": methodIdentity ?: @"",
        @"executionKind": @([record[@"executionKind"] integerValue] == 3 ? 3 : 1),
        @"title": title,
        @"description": [record[@"description"] isKindOfClass:NSString.class] ? record[@"description"] : @"",
        @"argumentValues": [record[@"argumentValues"] isKindOfClass:NSArray.class] ? record[@"argumentValues"] : @[],
        @"argumentControlConfigs": [record[@"argumentControlConfigs"] isKindOfClass:NSArray.class] ? record[@"argumentControlConfigs"] : @[],
        @"immediateChain": [record[@"immediateChain"] isKindOfClass:NSDictionary.class] ? record[@"immediateChain"] : @{}
    };
}
