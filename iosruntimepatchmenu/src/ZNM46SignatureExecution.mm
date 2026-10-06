#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "ZNIL2CPPInvokeEngine.h"
#import "ZNIL2CPPMethodSignature.h"
#import "ZNIL2CPPResolver.h"
#import "ZNRuntimeActionModel.h"
#import "ZNPatchCore.h"

static NSString * const kZNM46SignatureContextKey = @"com.zonoe.m46.signature-context";
static NSString * const kZNM46SignatureFailureKey = @"com.zonoe.m46.signature-failure";

static NSString *ZNM46NormalizeAssemblyExec(NSString *value) {
    NSString *s = [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    return [s hasSuffix:@".dll"] ? [s substringToIndex:s.length - 4] : s;
}

static BOOL ZNM46ContextMatches(NSDictionary *context,
                                NSString *assembly,
                                NSString *namespaceName,
                                NSString *className,
                                NSString *methodName,
                                NSInteger argumentCount) {
    if (![context isKindOfClass:NSDictionary.class]) return NO;
    NSArray *types = [context[@"parameterTypeNames"] isKindOfClass:NSArray.class] ? context[@"parameterTypeNames"] : nil;
    if (!types || types.count != (NSUInteger)MAX(argumentCount, 0)) return NO;
    if (![ZNM46NormalizeAssemblyExec(context[@"assembly"]) isEqualToString:ZNM46NormalizeAssemblyExec(assembly)]) return NO;
    if (![(context[@"namespace"] ?: @"") isEqualToString:namespaceName ?: @""]) return NO;
    if (![(context[@"class"] ?: @"") isEqualToString:className ?: @""]) return NO;
    if (![(context[@"method"] ?: @"") isEqualToString:methodName ?: @""]) return NO;
    return [context[@"argumentCount"] integerValue] == argumentCount;
}

static NSDictionary *ZNM46ContextForAction(ZNRuntimeMethodAction *action) {
    return @{
        @"assembly": action.assembly ?: @"",
        @"namespace": action.namespaceName ?: @"",
        @"class": action.className ?: @"",
        @"method": action.methodName ?: @"",
        @"argumentCount": @(action.argumentCount),
        @"parameterTypeNames": action.parameterTypeNames ?: @[],
        @"identity": action.canonicalIdentity ?: @"",
    };
}

@interface ZNIL2CPPInvokeEngine (ZNM46SignatureExecution)
- (NSDictionary<NSString *, id> * _Nullable)znm46_executeAction:(ZNRuntimeMethodAction *)action
                                                           error:(NSString * _Nullable * _Nullable)error;
@end

@implementation ZNIL2CPPInvokeEngine (ZNM46SignatureExecution)

- (NSDictionary<NSString *,id> *)znm46_executeAction:(ZNRuntimeMethodAction *)action error:(NSString **)error {
    if (!action.signatureAvailable || action.parameterTypeNames.count != action.argumentCount) {
        return [self znm46_executeAction:action error:error];
    }

    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    NSDictionary *previousContext = threadState[kZNM46SignatureContextKey];
    NSString *previousFailure = threadState[kZNM46SignatureFailureKey];
    threadState[kZNM46SignatureContextKey] = ZNM46ContextForAction(action);
    [threadState removeObjectForKey:kZNM46SignatureFailureKey];

    NSDictionary *result = nil;
    @try {
        result = [self znm46_executeAction:action error:error];
        NSString *signatureFailure = threadState[kZNM46SignatureFailureKey];
        if (!result && signatureFailure.length && error) *error = signatureFailure;
    } @finally {
        if (previousContext) threadState[kZNM46SignatureContextKey] = previousContext;
        else [threadState removeObjectForKey:kZNM46SignatureContextKey];
        if (previousFailure) threadState[kZNM46SignatureFailureKey] = previousFailure;
        else [threadState removeObjectForKey:kZNM46SignatureFailureKey];
    }
    return result;
}

@end

@interface ZNIL2CPPResolver (ZNM46SignatureExecution)
- (NSDictionary<NSString *, id> * _Nullable)znm46_resolveMethodAssembly:(NSString *)assembly
                                                               namespace:(NSString *)namespaceName
                                                               className:(NSString *)className
                                                                  method:(NSString *)methodName
                                                           argumentCount:(NSInteger)argumentCount;
@end

@implementation ZNIL2CPPResolver (ZNM46SignatureExecution)

- (NSDictionary<NSString *,id> *)znm46_resolveMethodAssembly:(NSString *)assembly
                                                    namespace:(NSString *)namespaceName
                                                    className:(NSString *)className
                                                       method:(NSString *)methodName
                                                argumentCount:(NSInteger)argumentCount {
    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    NSDictionary *context = threadState[kZNM46SignatureContextKey];
    if (!ZNM46ContextMatches(context, assembly, namespaceName, className, methodName, argumentCount)) {
        return [self znm46_resolveMethodAssembly:assembly
                                       namespace:namespaceName
                                       className:className
                                          method:methodName
                                   argumentCount:argumentCount];
    }

    NSArray<NSString *> *types = context[@"parameterTypeNames"] ?: @[];
    NSString *signatureError = nil;
    NSDictionary *resolved = [[ZNIL2CPPFullSignatureResolver sharedResolver] resolveAssembly:assembly
                                                                                   namespace:namespaceName ?: @""
                                                                                   className:className
                                                                                      method:methodName
                                                                          parameterTypeNames:types
                                                                                       error:&signatureError];
    if (!resolved) {
        NSString *failure = signatureError ?: [NSString stringWithFormat:@"FAILED_SIGNATURE_RESOLVE：%@", context[@"identity"] ?: @""];
        threadState[kZNM46SignatureFailureKey] = failure;
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m4.6-signature] fail-closed %@", failure]];
        return nil;
    }
    [threadState removeObjectForKey:kZNM46SignatureFailureKey];
    return resolved;
}

@end

static void ZNM46SignatureSwap(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (a && b) method_exchangeImplementations(a, b);
}

extern "C" void ZNInstallM46SignatureExecutionDeferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZNM46SignatureSwap(ZNIL2CPPInvokeEngine.class,
                           @selector(executeAction:error:),
                           @selector(znm46_executeAction:error:));
        ZNM46SignatureSwap(ZNIL2CPPResolver.class,
                           @selector(resolveMethodAssembly:namespace:className:method:argumentCount:),
                           @selector(znm46_resolveMethodAssembly:namespace:className:method:argumentCount:));
        [[ZNRuntimeLogger sharedLogger] log:@"[m4.6-signature] exact Runtime Action resolver installed; full signatures fail closed instead of falling back to Method/N"];
    });
}
