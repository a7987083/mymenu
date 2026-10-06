#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ZNRuntimeActionFormat.h"
#import "ZNRuntimeActionModel.h"
#import "ZNPatchCore.h"

@interface ZNRuntimeActionStore (ZNM52ChainStoreV2)
- (BOOL)znm52_updateImmediateChain:(NSDictionary<NSString *, id> *)chain
                           atIndex:(NSUInteger)index
                             error:(NSString **)error;
@end

@implementation ZNRuntimeActionStore (ZNM52ChainStoreV2)
- (BOOL)znm52_updateImmediateChain:(NSDictionary<NSString *,id> *)chain atIndex:(NSUInteger)index error:(NSString **)error {
    if ([chain[@"version"] integerValue] != 2) {
        return [self znm52_updateImmediateChain:chain atIndex:index error:error];
    }
    NSArray *nodes = [chain[@"nodes"] isKindOfClass:NSArray.class] ? chain[@"nodes"] : nil;
    if (!nodes.count || nodes.count > 8) {
        if (error) *error = @"Immediate Chain V2 后续节点数量必须为 1-8";
        return NO;
    }
    for (NSUInteger i = 0; i < nodes.count; i++) {
        NSDictionary *node = [nodes[i] isKindOfClass:NSDictionary.class] ? nodes[i] : nil;
        NSString *cls = [node[@"class"] isKindOfClass:NSString.class] ? node[@"class"] : @"";
        NSString *method = [node[@"method"] isKindOfClass:NSString.class] ? node[@"method"] : @"";
        NSArray *types = [node[@"parameterTypeNames"] isKindOfClass:NSArray.class] ? node[@"parameterTypeNames"] : nil;
        NSArray *values = [node[@"argumentValues"] isKindOfClass:NSArray.class] ? node[@"argumentValues"] : nil;
        if (!cls.length || !method.length || !types || !values || types.count != values.count || values.count > ZN_RUNTIME_ACTION_MAX_ARGUMENTS) {
            if (error) *error = [NSString stringWithFormat:@"Immediate Chain V2 Level %lu Class/Method/signature/args 无效", (unsigned long)i + 1];
            return NO;
        }
    }

    NSMutableArray *mutableActions = [self valueForKey:@"mutableActions"];
    @synchronized (self) {
        if (![mutableActions isKindOfClass:NSMutableArray.class] || index >= mutableActions.count) {
            if (error) *error = @"Runtime Method Call 索引已失效";
            return NO;
        }
        ZNRuntimeMethodAction *action = mutableActions[index];
        action.immediateChain = [chain copy];
    }
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m5.2-chain-store] saved action index=%lu nodes=%lu", (unsigned long)index, (unsigned long)nodes.count]];
    if (error) *error = nil;
    return YES;
}
@end

static void ZNM52ChainStoreSwap(void) {
    Class cls = ZNRuntimeActionStore.class;
    Method original = class_getInstanceMethod(cls, @selector(updateImmediateChain:atIndex:error:));
    Method replacement = class_getInstanceMethod(cls, @selector(znm52_updateImmediateChain:atIndex:error:));
    if (original && replacement) method_exchangeImplementations(original, replacement);
}

extern "C" void ZNInstallM52ChainStoreV2Deferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZNM52ChainStoreSwap();
        [[ZNRuntimeLogger sharedLogger] log:@"[m5.2-chain-store] V2 nodes metadata accepted; V1 validation preserved"];
    });
}
