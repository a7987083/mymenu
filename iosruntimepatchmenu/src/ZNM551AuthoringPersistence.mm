#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ZNRuntimeActionModel.h"
#import "ZNPatchCore.h"

static NSString * const kZNM551AuthoringKey = @"zonoe.m5.5.authoring-actions.v1";
static BOOL gZNM551Restoring = NO;

static NSDictionary *ZNM551EncodeAction(ZNRuntimeMethodAction *a) {
    return @{
        @"title": a.title ?: @"",
        @"assembly": a.assembly ?: @"Assembly-CSharp.dll",
        @"namespace": a.namespaceName ?: @"",
        @"class": a.className ?: @"",
        @"method": a.methodName ?: @"",
        @"argumentCount": @(a.argumentCount),
        @"argumentValues": a.argumentValues ?: @[],
        @"parameterTypeNames": a.parameterTypeNames ?: @[],
        @"signatureAvailable": @(a.signatureAvailable),
        @"argumentControlConfigs": a.argumentControlConfigs ?: @[],
        @"immediateChain": a.immediateChain ?: @{}
    };
}

static void ZNM551Save(void) {
    if (gZNM551Restoring) return;
    NSArray<ZNRuntimeMethodAction *> *actions = [[ZNRuntimeActionStore sharedStore] actionsSnapshot];
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:actions.count];
    for (ZNRuntimeMethodAction *a in actions) [items addObject:ZNM551EncodeAction(a)];
    NSDictionary *root = @{@"version": @1, @"actions": items};
    [NSUserDefaults.standardUserDefaults setObject:root forKey:kZNM551AuthoringKey];
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m5.5.1-persist] saved %lu authoring actions", (unsigned long)items.count]];
}

static void ZNM551Restore(void) {
    if ([[ZNRuntimeActionStore sharedStore] actionsSnapshot].count) return;
    NSDictionary *root = [NSUserDefaults.standardUserDefaults objectForKey:kZNM551AuthoringKey];
    if (![root isKindOfClass:NSDictionary.class] || [root[@"version"] integerValue] != 1) return;
    NSArray *items = [root[@"actions"] isKindOfClass:NSArray.class] ? root[@"actions"] : @[];
    if (!items.count) return;

    gZNM551Restoring = YES;
    NSUInteger restored = 0;
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *assembly = [item[@"assembly"] isKindOfClass:NSString.class] ? item[@"assembly"] : @"Assembly-CSharp.dll";
        NSString *ns = [item[@"namespace"] isKindOfClass:NSString.class] ? item[@"namespace"] : @"";
        NSString *cls = [item[@"class"] isKindOfClass:NSString.class] ? item[@"class"] : @"";
        NSString *method = [item[@"method"] isKindOfClass:NSString.class] ? item[@"method"] : @"";
        NSUInteger argc = [item[@"argumentCount"] unsignedIntegerValue];
        if (!cls.length || !method.length || argc > 8) continue;
        NSArray *values = [item[@"argumentValues"] isKindOfClass:NSArray.class] ? item[@"argumentValues"] : @[];
        NSArray *types = [item[@"parameterTypeNames"] isKindOfClass:NSArray.class] ? item[@"parameterTypeNames"] : @[];
        BOOL sig = [item[@"signatureAvailable"] boolValue];
        NSDictionary *candidate = @{
            @"assembly": assembly,
            @"namespace": ns,
            @"class": cls,
            @"method": method,
            @"argumentCount": @(argc),
            @"parameterTypeNames": types,
            @"signatureAvailable": @(sig)
        };
        NSString *error = nil;
        ZNRuntimeMethodAction *created = [[ZNRuntimeActionStore sharedStore] addMethodCandidate:candidate
                                                                                         title:item[@"title"]
                                                                                argumentValues:values
                                                                                         error:&error];
        if (!created) {
            [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m5.5.1-persist] restore skip %@::%@ error=%@", cls, method, error ?: @"unknown"]];
            continue;
        }
        NSUInteger index = [[ZNRuntimeActionStore sharedStore] actionsSnapshot].count - 1;
        NSArray *configs = [item[@"argumentControlConfigs"] isKindOfClass:NSArray.class] ? item[@"argumentControlConfigs"] : @[];
        if (configs.count == argc) [[ZNRuntimeActionStore sharedStore] updateArgumentControlConfigs:configs atIndex:index error:nil];
        NSDictionary *chain = [item[@"immediateChain"] isKindOfClass:NSDictionary.class] ? item[@"immediateChain"] : @{};
        if (chain.count) [[ZNRuntimeActionStore sharedStore] updateImmediateChain:chain atIndex:index error:nil];
        restored++;
    }
    gZNM551Restoring = NO;
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m5.5.1-persist] restored %lu/%lu authoring actions", (unsigned long)restored, (unsigned long)items.count]];
}

@interface ZNRuntimeActionStore (ZNM551Persistence)
- (ZNRuntimeMethodAction *)znm551_addMethodCandidate:(NSDictionary<NSString *, id> *)candidate title:(NSString *)title argumentValues:(NSArray<NSString *> *)argumentValues error:(NSString **)error;
- (BOOL)znm551_updateTitle:(NSString *)title atIndex:(NSUInteger)index error:(NSString **)error;
- (BOOL)znm551_updateArgumentValues:(NSArray<NSString *> *)argumentValues atIndex:(NSUInteger)index error:(NSString **)error;
- (BOOL)znm551_updateArgumentControlConfigs:(NSArray<NSDictionary<NSString *, id> *> *)configs atIndex:(NSUInteger)index error:(NSString **)error;
- (BOOL)znm551_updateImmediateChain:(NSDictionary<NSString *, id> *)chain atIndex:(NSUInteger)index error:(NSString **)error;
- (BOOL)znm551_removeActionAtIndex:(NSUInteger)index;
- (void)znm551_clear;
@end

@implementation ZNRuntimeActionStore (ZNM551Persistence)
- (ZNRuntimeMethodAction *)znm551_addMethodCandidate:(NSDictionary<NSString *,id> *)candidate title:(NSString *)title argumentValues:(NSArray<NSString *> *)argumentValues error:(NSString **)error {
    ZNRuntimeMethodAction *result = [self znm551_addMethodCandidate:candidate title:title argumentValues:argumentValues error:error];
    if (result) ZNM551Save();
    return result;
}
- (BOOL)znm551_updateTitle:(NSString *)title atIndex:(NSUInteger)index error:(NSString **)error { BOOL ok=[self znm551_updateTitle:title atIndex:index error:error]; if(ok) ZNM551Save(); return ok; }
- (BOOL)znm551_updateArgumentValues:(NSArray<NSString *> *)argumentValues atIndex:(NSUInteger)index error:(NSString **)error { BOOL ok=[self znm551_updateArgumentValues:argumentValues atIndex:index error:error]; if(ok) ZNM551Save(); return ok; }
- (BOOL)znm551_updateArgumentControlConfigs:(NSArray<NSDictionary<NSString *,id> *> *)configs atIndex:(NSUInteger)index error:(NSString **)error { BOOL ok=[self znm551_updateArgumentControlConfigs:configs atIndex:index error:error]; if(ok) ZNM551Save(); return ok; }
- (BOOL)znm551_updateImmediateChain:(NSDictionary<NSString *,id> *)chain atIndex:(NSUInteger)index error:(NSString **)error { BOOL ok=[self znm551_updateImmediateChain:chain atIndex:index error:error]; if(ok) ZNM551Save(); return ok; }
- (BOOL)znm551_removeActionAtIndex:(NSUInteger)index { BOOL ok=[self znm551_removeActionAtIndex:index]; if(ok) ZNM551Save(); return ok; }
- (void)znm551_clear { [self znm551_clear]; ZNM551Save(); }
@end

static void ZNM551Swap(Class cls, SEL a, SEL b) {
    Method ma = class_getInstanceMethod(cls, a), mb = class_getInstanceMethod(cls, b);
    if (ma && mb) method_exchangeImplementations(ma, mb);
}

extern "C" void ZNInstallM551AuthoringPersistenceDeferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZNM551Restore();
        Class cls = ZNRuntimeActionStore.class;
        ZNM551Swap(cls, @selector(addMethodCandidate:title:argumentValues:error:), @selector(znm551_addMethodCandidate:title:argumentValues:error:));
        ZNM551Swap(cls, @selector(updateTitle:atIndex:error:), @selector(znm551_updateTitle:atIndex:error:));
        ZNM551Swap(cls, @selector(updateArgumentValues:atIndex:error:), @selector(znm551_updateArgumentValues:atIndex:error:));
        ZNM551Swap(cls, @selector(updateArgumentControlConfigs:atIndex:error:), @selector(znm551_updateArgumentControlConfigs:atIndex:error:));
        ZNM551Swap(cls, @selector(updateImmediateChain:atIndex:error:), @selector(znm551_updateImmediateChain:atIndex:error:));
        ZNM551Swap(cls, @selector(removeActionAtIndex:), @selector(znm551_removeActionAtIndex:));
        ZNM551Swap(cls, @selector(clear), @selector(znm551_clear));
        [[ZNRuntimeLogger sharedLogger] log:@"[m5.5.1-persist] authoring persistence installed"];
    });
}
