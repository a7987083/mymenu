#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <errno.h>

#import "ZNIL2CPPABIMetadata.h"
#import "ZNIL2CPPInvokeEngine.h"
#import "ZNIL2CPPMethodSignature.h"
#import "ZNIL2CPPResolver.h"
#import "ZNRuntimeActionFormat.h"
#import "ZNRuntimeActionModel.h"
#import "ZNPatchCore.h"

static const NSUInteger kZNM52MaxChainNodes = 8;
static const void *kZNM52CandidateKey = &kZNM52CandidateKey;

typedef int32_t (*ZNM52StringLengthFn)(void *);
typedef const uint16_t *(*ZNM52StringCharsFn)(void *);
typedef uint32_t (*ZNM52MethodGetTokenFn)(const void *);
typedef const void *(*ZNM52MethodGetReturnTypeFn)(const void *);
typedef char *(*ZNM52TypeGetNameFn)(const void *);
typedef void (*ZNM52FreeFn)(void *);
typedef void *(*ZNM52ObjectGetClassFn)(void *);
typedef const char *(*ZNM52ClassGetNameFn)(void *);
typedef const char *(*ZNM52ClassGetNamespaceFn)(void *);
typedef void (*ZNM52FormatExceptionFn)(const void *, char *, int32_t);
typedef void (*ZNM52FormatStackFn)(const void *, char *, int32_t);

static void *ZNM52Symbol(const char *name) {
    return name ? dlsym(RTLD_DEFAULT, name) : NULL;
}

static NSString *ZNM52Trim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSArray<NSString *> *ZNM52CSV(NSString *value) {
    NSString *trimmed = ZNM52Trim(value);
    if (!trimmed.length) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *raw in [trimmed componentsSeparatedByString:@","]) {
        NSString *item = ZNM52Trim(raw);
        if (item.length) [out addObject:item];
    }
    return out;
}

static BOOL ZNM52IsStringType(NSString *type) {
    NSString *n = ZNM52Trim(type).lowercaseString;
    return [n isEqualToString:@"system.string"] || [n isEqualToString:@"string"];
}

static NSString *ZNM52DecodeManagedString(uintptr_t raw) {
    if (!raw) return nil;
    ZNM52StringLengthFn lengthFn = (ZNM52StringLengthFn)ZNM52Symbol("il2cpp_string_length");
    ZNM52StringCharsFn charsFn = (ZNM52StringCharsFn)ZNM52Symbol("il2cpp_string_chars");
    if (!lengthFn || !charsFn) return nil;
    int32_t length = lengthFn((void *)raw);
    if (length < 0 || length > (16 * 1024 * 1024)) return nil;
    const uint16_t *chars = charsFn((void *)raw);
    if (!chars && length) return nil;
    return [[NSString alloc] initWithCharacters:(const unichar *)chars length:(NSUInteger)length];
}

static NSDictionary *ZNM52DecodeStringReturn(NSDictionary *result) {
    if (![result isKindOfClass:NSDictionary.class]) return result;
    NSString *type = [result[@"returnType"] isKindOfClass:NSString.class] ? result[@"returnType"] : @"";
    if (!ZNM52IsStringType(type)) return result;
    uintptr_t raw = [result[@"returnRawObject"] unsignedLongLongValue];
    NSMutableDictionary *out = [result mutableCopy];
    if (!raw) {
        out[@"returnDecoded"] = @YES;
        out[@"returnValue"] = @"null";
        return [out copy];
    }
    NSString *stringValue = ZNM52DecodeManagedString(raw);
    if (!stringValue) return result;
    out[@"returnDecoded"] = @YES;
    out[@"returnValue"] = stringValue;
    out[@"returnString"] = stringValue;
    return [out copy];
}

static uint32_t ZNM52MethodToken(uintptr_t methodInfo) {
    if (!methodInfo) return 0;
    ZNM52MethodGetTokenFn fn = (ZNM52MethodGetTokenFn)ZNM52Symbol("il2cpp_method_get_token");
    return fn ? fn((const void *)methodInfo) : 0;
}

static NSString *ZNM52MethodReturnType(uintptr_t methodInfo) {
    if (!methodInfo) return @"";
    ZNM52MethodGetReturnTypeFn getReturn = (ZNM52MethodGetReturnTypeFn)ZNM52Symbol("il2cpp_method_get_return_type");
    ZNM52TypeGetNameFn getName = (ZNM52TypeGetNameFn)ZNM52Symbol("il2cpp_type_get_name");
    ZNM52FreeFn freeFn = (ZNM52FreeFn)ZNM52Symbol("il2cpp_free");
    if (!getReturn || !getName) return @"";
    const void *type = getReturn((const void *)methodInfo);
    char *raw = type ? getName(type) : NULL;
    if (!raw) return @"";
    NSString *name = [NSString stringWithUTF8String:raw] ?: @"";
    if (freeFn) freeFn(raw);
    return name;
}

static uintptr_t ZNM52ExceptionPointer(NSString *error) {
    NSRange marker = [error rangeOfString:@"exception=0x" options:NSCaseInsensitiveSearch];
    if (marker.location == NSNotFound) return 0;
    NSString *tail = [error substringFromIndex:NSMaxRange(marker)];
    NSScanner *scanner = [NSScanner scannerWithString:tail];
    unsigned long long value = 0;
    return [scanner scanHexLongLong:&value] ? (uintptr_t)value : 0;
}

static NSString *ZNM52ExceptionDetails(NSString *error) {
    uintptr_t address = ZNM52ExceptionPointer(error ?: @"");
    if (!address) return error ?: @"执行失败";
    ZNM52ObjectGetClassFn objectGetClass = (ZNM52ObjectGetClassFn)ZNM52Symbol("il2cpp_object_get_class");
    ZNM52ClassGetNameFn classGetName = (ZNM52ClassGetNameFn)ZNM52Symbol("il2cpp_class_get_name");
    ZNM52ClassGetNamespaceFn classGetNS = (ZNM52ClassGetNamespaceFn)ZNM52Symbol("il2cpp_class_get_namespace");
    ZNM52FormatExceptionFn formatException = (ZNM52FormatExceptionFn)ZNM52Symbol("il2cpp_format_exception");
    ZNM52FormatStackFn formatStack = (ZNM52FormatStackFn)ZNM52Symbol("il2cpp_format_stack_trace");
    NSString *className = @"Il2CppException";
    if (objectGetClass && classGetName) {
        void *klass = objectGetClass((void *)address);
        if (klass) {
            const char *name = classGetName(klass);
            const char *ns = classGetNS ? classGetNS(klass) : NULL;
            NSString *n = name ? ([NSString stringWithUTF8String:name] ?: @"") : @"";
            NSString *s = ns ? ([NSString stringWithUTF8String:ns] ?: @"") : @"";
            if (n.length) className = s.length ? [NSString stringWithFormat:@"%@.%@", s, n] : n;
        }
    }
    char message[2048] = {};
    char stack[4096] = {};
    if (formatException) formatException((const void *)address, message, (int32_t)sizeof(message));
    if (formatStack) formatStack((const void *)address, stack, (int32_t)sizeof(stack));
    NSString *m = message[0] ? ([NSString stringWithUTF8String:message] ?: @"") : @"";
    NSString *st = stack[0] ? ([NSString stringWithUTF8String:stack] ?: @"") : @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:className];
    if (m.length) [parts addObject:m];
    if (st.length) [parts addObject:st];
    return [parts componentsJoinedByString:@"\n"];
}

static NSDictionary *ZNM52V2Chain(NSDictionary *chain) {
    if (![chain isKindOfClass:NSDictionary.class]) return nil;
    if ([chain[@"version"] integerValue] != 2) return nil;
    NSArray *nodes = [chain[@"nodes"] isKindOfClass:NSArray.class] ? chain[@"nodes"] : nil;
    return nodes.count ? chain : nil;
}

static ZNRuntimeMethodAction *ZNM52ActionForNode(NSDictionary *node) {
    ZNRuntimeMethodAction *action = [ZNRuntimeMethodAction new];
    action.title = [node[@"title"] isKindOfClass:NSString.class] ? node[@"title"] : @"Chain Node";
    action.group = @"Immediate Chain";
    action.assembly = [node[@"assembly"] isKindOfClass:NSString.class] ? node[@"assembly"] : @"Assembly-CSharp.dll";
    action.namespaceName = [node[@"namespace"] isKindOfClass:NSString.class] ? node[@"namespace"] : @"";
    action.className = [node[@"class"] isKindOfClass:NSString.class] ? node[@"class"] : @"";
    action.methodName = [node[@"method"] isKindOfClass:NSString.class] ? node[@"method"] : @"";
    action.argumentValues = [node[@"argumentValues"] isKindOfClass:NSArray.class] ? node[@"argumentValues"] : @[];
    action.parameterTypeNames = [node[@"parameterTypeNames"] isKindOfClass:NSArray.class] ? node[@"parameterTypeNames"] : @[];
    action.argumentCount = action.argumentValues.count;
    action.signatureAvailable = [node[@"signatureAvailable"] boolValue] || action.parameterTypeNames.count == action.argumentCount;
    action.argumentControlConfigs = @[];
    action.immediateChain = @{};
    return action;
}

static NSDictionary *ZNM52ResolveNode(NSDictionary *node, NSString **error) {
    ZNRuntimeMethodAction *action = ZNM52ActionForNode(node);
    if (!action.className.length || !action.methodName.length || action.argumentCount > ZN_RUNTIME_ACTION_MAX_ARGUMENTS) {
        if (error) *error = @"Chain node Class/Method/argc 无效";
        return nil;
    }
    if (!action.signatureAvailable || action.parameterTypeNames.count != action.argumentCount) {
        if (error) *error = @"Chain V2 节点必须保存完整 parameter signature";
        return nil;
    }
    NSString *resolveError = nil;
    NSDictionary *resolved = [[ZNIL2CPPFullSignatureResolver sharedResolver] resolveAssembly:action.assembly
                                                                                   namespace:action.namespaceName ?: @""
                                                                                   className:action.className
                                                                                      method:action.methodName
                                                                          parameterTypeNames:action.parameterTypeNames
                                                                                       error:&resolveError];
    if (!resolved) { if (error) *error = resolveError ?: @"Chain node exact resolve failed"; return nil; }
    uintptr_t methodInfo = [resolved[@"methodInfo"] unsignedLongLongValue];
    uint32_t actualToken = ZNM52MethodToken(methodInfo);
    uint32_t savedToken = [node[@"token"] unsignedIntValue];
    if (savedToken && actualToken && savedToken != actualToken) {
        if (error) *error = [NSString stringWithFormat:@"Chain node token mismatch saved=0x%X actual=0x%X", savedToken, actualToken];
        return nil;
    }
    NSString *actualReturn = ZNM52MethodReturnType(methodInfo);
    NSString *savedReturn = [node[@"returnType"] isKindOfClass:NSString.class] ? node[@"returnType"] : @"";
    if (savedReturn.length && actualReturn.length && ![savedReturn isEqualToString:actualReturn]) {
        if (error) *error = [NSString stringWithFormat:@"Chain node return type mismatch saved=%@ actual=%@", savedReturn, actualReturn];
        return nil;
    }
    NSMutableDictionary *out = [resolved mutableCopy];
    out[@"token"] = @(actualToken);
    out[@"returnType"] = actualReturn ?: @"";
    return [out copy];
}

static NSDictionary *ZNM52Trace(NSUInteger level, ZNRuntimeMethodAction *action, NSDictionary *result) {
    return @{
        @"level": @(level),
        @"identity": action.canonicalIdentity ?: @"",
        @"receiver": result[@"instance"] ?: @0,
        @"methodInfo": result[@"methodInfo"] ?: @0,
        @"methodPointer": result[@"methodPointer"] ?: @0,
        @"argumentValues": action.argumentValues ?: @[],
        @"returnType": result[@"returnType"] ?: @"?",
        @"returnKind": result[@"returnKind"] ?: @"unknown",
        @"returnValue": result[@"returnValue"] ?: @"?",
        @"returnRawObject": result[@"returnRawObject"] ?: @0,
        @"status": @"success",
    };
}

@interface ZNIL2CPPInvokeEngine (ZNM52ImmediateChainV2)
- (NSDictionary<NSString *,id> *)znm52_executeAction:(ZNRuntimeMethodAction *)action error:(NSString **)error;
@end

@implementation ZNIL2CPPInvokeEngine (ZNM52ImmediateChainV2)

- (NSDictionary<NSString *,id> *)znm52_executeAction:(ZNRuntimeMethodAction *)action error:(NSString **)error {
    NSDictionary *chain = ZNM52V2Chain(action.immediateChain);
    if (!chain) {
        NSDictionary *result = [self znm52_executeAction:action error:error];
        return ZNM52DecodeStringReturn(result);
    }

    NSArray<NSDictionary *> *nodes = chain[@"nodes"];
    if (!nodes.count || nodes.count > kZNM52MaxChainNodes) {
        if (error) *error = [NSString stringWithFormat:@"Immediate Chain V2 节点数量必须为 1-%lu", (unsigned long)kZNM52MaxChainNodes];
        return nil;
    }

    ZNRuntimeMethodAction *root = [action copy];
    root.immediateChain = @{};
    NSString *rootError = nil;
    NSDictionary *current = ZNM52DecodeStringReturn([self znm52_executeAction:root error:&rootError]);
    if (!current) {
        if (error) *error = [NSString stringWithFormat:@"Level 0 failed\n%@\n%@", root.canonicalIdentity ?: @"?", ZNM52ExceptionDetails(rootError)];
        return nil;
    }

    NSMutableArray<NSDictionary *> *trace = [NSMutableArray arrayWithObject:ZNM52Trace(0, root, current)];
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m5.2-chain] Level 0 %@ return=%@ raw=0x%llX SUCCESS",
                                         root.canonicalIdentity ?: @"?", current[@"returnValue"] ?: @"?",
                                         (unsigned long long)[current[@"returnRawObject"] unsignedLongLongValue]]];

    for (NSUInteger i = 0; i < nodes.count; i++) {
        NSUInteger level = i + 1;
        uintptr_t previousRaw = [current[@"returnRawObject"] unsignedLongLongValue];
        NSString *previousKind = [current[@"returnKind"] isKindOfClass:NSString.class] ? current[@"returnKind"] : @"";
        if (!previousRaw) {
            if (error) *error = [NSString stringWithFormat:@"Chain stopped at Level %lu: previous managed return is null", (unsigned long)level];
            return nil;
        }
        if (![previousKind containsString:@"managed reference"]) {
            if (error) *error = [NSString stringWithFormat:@"Chain stopped at Level %lu: previous return is not managed-reference (%@)", (unsigned long)level, previousKind.length ? previousKind : @"unknown"];
            return nil;
        }

        NSDictionary *node = nodes[i];
        NSString *identityError = nil;
        NSDictionary *resolved = ZNM52ResolveNode(node, &identityError);
        if (!resolved) {
            if (error) *error = [NSString stringWithFormat:@"Level %lu identity validation failed\n%@", (unsigned long)level, identityError ?: @"unknown"];
            return nil;
        }

        ZNRuntimeMethodAction *next = ZNM52ActionForNode(node);
        NSString *nodeError = nil;
        NSDictionary *result = ZNM52DecodeStringReturn([self znm52_executeAction:next error:&nodeError]);
        if (!result) {
            NSString *details = ZNM52ExceptionDetails(nodeError);
            [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m5.2-chain] Level %lu %@ FAILED %@", (unsigned long)level, next.canonicalIdentity ?: @"?", details ?: @"?"]];
            if (error) *error = [NSString stringWithFormat:@"Level %lu failed\n%@\n%@", (unsigned long)level, next.canonicalIdentity ?: @"?", details ?: @"执行失败"];
            return nil;
        }
        NSMutableDictionary *withIdentity = [result mutableCopy];
        withIdentity[@"resolvedToken"] = @([resolved[@"token"] unsignedIntValue]);
        withIdentity[@"resolvedReturnType"] = resolved[@"returnType"] ?: @"";
        current = [withIdentity copy];
        [trace addObject:ZNM52Trace(level, next, current)];
        [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m5.2-chain] Level %lu %@ args=%@ receiver=0x%llX return=%@ raw=0x%llX SUCCESS",
                                             (unsigned long)level, next.canonicalIdentity ?: @"?", next.argumentValues ?: @[],
                                             (unsigned long long)[current[@"instance"] unsignedLongLongValue],
                                             current[@"returnValue"] ?: @"?",
                                             (unsigned long long)[current[@"returnRawObject"] unsignedLongLongValue]]];
    }

    NSMutableDictionary *final = [current mutableCopy];
    final[@"immediateChainV2"] = @YES;
    final[@"chainNodeCount"] = @(nodes.count + 1);
    final[@"chainTrace"] = trace;
    final[@"chainFinalValue"] = current[@"returnValue"] ?: @"?";
    if (error) *error = nil;
    return [final copy];
}

@end

@interface ZNRuntimeMenuControllerV040 : NSObject
@property(nonatomic,strong) UIWindow *hostWindow;
- (NSArray<NSString *> *)znm43_argumentValues:(NSDictionary *)candidate;
- (void)zn60v3_setStatus:(NSString *)status;
- (void)renderPage;
- (void)zn51_chainTapped:(UIButton *)sender;
@end

static UIViewController *ZNM52Top(UIWindow *window) {
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static NSDictionary *ZNM52NodeFromFields(UIAlertController *alert, NSString **error) {
    if (alert.textFields.count < 6) { if (error) *error = @"链节点表单不完整"; return nil; }
    NSString *assembly = ZNM52Trim(alert.textFields[0].text);
    NSString *ns = ZNM52Trim(alert.textFields[1].text);
    NSString *cls = ZNM52Trim(alert.textFields[2].text);
    NSString *method = ZNM52Trim(alert.textFields[3].text);
    NSArray<NSString *> *types = ZNM52CSV(alert.textFields[4].text);
    NSArray<NSString *> *values = ZNM52CSV(alert.textFields[5].text);
    if (!assembly.length) assembly = @"Assembly-CSharp.dll";
    if (!cls.length || !method.length) { if (error) *error = @"Class / Method 不能为空"; return nil; }
    if (types.count != values.count) { if (error) *error = [NSString stringWithFormat:@"Parameter Types 数量(%lu)与 Args 数量(%lu)不一致", (unsigned long)types.count, (unsigned long)values.count]; return nil; }
    if (types.count > ZN_RUNTIME_ACTION_MAX_ARGUMENTS) { if (error) *error = @"单节点参数超过 /8 上限"; return nil; }

    NSString *resolveError = nil;
    NSDictionary *resolved = [[ZNIL2CPPFullSignatureResolver sharedResolver] resolveAssembly:assembly namespace:ns className:cls method:method parameterTypeNames:types error:&resolveError];
    if (!resolved) { if (error) *error = resolveError ?: @"目标方法完整签名解析失败"; return nil; }
    uintptr_t methodInfo = [resolved[@"methodInfo"] unsignedLongLongValue];
    uint32_t token = ZNM52MethodToken(methodInfo);
    NSString *returnType = ZNM52MethodReturnType(methodInfo);
    return @{
        @"assembly": assembly,
        @"namespace": ns ?: @"",
        @"class": cls,
        @"method": method,
        @"argumentCount": @(values.count),
        @"argumentValues": values,
        @"parameterTypeNames": types,
        @"signatureAvailable": @YES,
        @"token": @(token),
        @"returnType": returnType ?: @"",
    };
}

static BOOL ZNM52SaveChain(ZNRuntimeMenuControllerV040 *controller, NSDictionary *candidate, NSArray<NSDictionary *> *nodes, NSString **error) {
    NSArray<NSString *> *rootValues = [controller znm43_argumentValues:candidate] ?: @[];
    ZNRuntimeMethodAction *created = [[ZNRuntimeActionStore sharedStore] addMethodCandidate:candidate title:candidate[@"method"] argumentValues:rootValues error:error];
    if (!created) return NO;
    NSArray<ZNRuntimeMethodAction *> *actions = [[ZNRuntimeActionStore sharedStore] actionsSnapshot];
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < actions.count; i++) if (actions[i].actionID == created.actionID) { index = i; break; }
    if (index == NSNotFound) { if (error) *error = @"无法定位新建 Runtime Action"; return NO; }
    NSDictionary *chain = @{
        @"version": @2,
        @"atomic": @YES,
        @"maxNodes": @(kZNM52MaxChainNodes),
        @"nodes": nodes ?: @[],
    };
    return [[ZNRuntimeActionStore sharedStore] updateImmediateChain:chain atIndex:index error:error];
}

static void ZNM52PresentNodeEditor(ZNRuntimeMenuControllerV040 *controller,
                                   NSDictionary *candidate,
                                   NSMutableArray<NSDictionary *> *nodes,
                                   NSString *defaultNamespace,
                                   NSString *defaultClass,
                                   NSUInteger level) {
    UIViewController *top = ZNM52Top(controller.hostWindow);
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Immediate Chain V2 · Level %lu", (unsigned long)level]
                                                                    message:@"Parameter Types 与 Args 使用英文逗号分隔；/0 两项都留空。每个节点按完整参数签名 fail-closed 解析。"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f){ f.placeholder=@"Assembly"; f.text=candidate[@"assembly"] ?: @"Assembly-CSharp.dll"; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f){ f.placeholder=@"Namespace（可空）"; f.text=defaultNamespace ?: @""; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f){ f.placeholder=@"Class"; f.text=defaultClass ?: @""; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f){ f.placeholder=@"Method"; f.text=(level > 1 ? @"ToString" : @""); }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f){ f.placeholder=@"Parameter Types，例如 K 或 System.Int32,System.Boolean"; }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f){ f.placeholder=@"Args，例如 0 或 100,true"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    __weak ZNRuntimeMenuControllerV040 *weakController = controller;
    void (^commit)(BOOL) = ^(BOOL continueEditing) {
        ZNRuntimeMenuControllerV040 *strong = weakController;
        if (!strong) return;
        NSString *nodeError = nil;
        NSDictionary *node = ZNM52NodeFromFields(alert, &nodeError);
        if (!node) { [strong zn60v3_setStatus:nodeError ?: @"链节点无效"]; [strong renderPage]; return; }
        [nodes addObject:node];
        if (continueEditing) {
            if (nodes.count >= kZNM52MaxChainNodes) { [strong zn60v3_setStatus:@"Immediate Chain V2 已达到 8 个后续节点上限"]; [strong renderPage]; return; }
            ZNM52PresentNodeEditor(strong, candidate, nodes, @"", @"", level + 1);
            return;
        }
        NSString *saveError = nil;
        if (!ZNM52SaveChain(strong, candidate, nodes, &saveError)) { [strong zn60v3_setStatus:saveError ?: @"保存 Chain V2 失败"]; [strong renderPage]; return; }
        [strong zn60v3_setStatus:[NSString stringWithFormat:@"Immediate Chain V2 已创建：%lu levels（原子执行）", (unsigned long)nodes.count + 1]];
        [strong renderPage];
    };
    [alert addAction:[UIAlertAction actionWithTitle:@"完成链" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ commit(NO); }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"继续添加" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){ commit(YES); }]];
    [top presentViewController:alert animated:YES completion:nil];
}

@interface ZNRuntimeMenuControllerV040 (ZNM52ImmediateChainV2)
- (void)zn52_chainTapped:(UIButton *)sender;
@end

@implementation ZNRuntimeMenuControllerV040 (ZNM52ImmediateChainV2)
- (void)zn52_chainTapped:(UIButton *)sender {
    NSDictionary *candidate = objc_getAssociatedObject(sender, kZNM52CandidateKey);
    // M5.1 used a private associated-object key. If our key is absent, infer the
    // candidate from the existing M5.1 button by invoking its original handler only
    // for non-V2 fallback is impossible. Therefore M5.2 mirrors the candidate binding
    // at render time in a separate swizzle below.
    if (!candidate) { [self zn60v3_setStatus:@"Chain V2：当前按钮缺少 candidate 绑定，请重新进入方法查找页面"]; [self renderPage]; return; }
    NSDictionary *abi = ZNIL2CPPDescribeMethodABI(candidate);
    NSDictionary *ret = [abi[@"return"] isKindOfClass:NSDictionary.class] ? abi[@"return"] : @{};
    if ((ZNIL2CPPABIValueKind)[ret[@"kind"] integerValue] != ZNIL2CPPABIValueKindObjectReference) {
        [self zn60v3_setStatus:[NSString stringWithFormat:@"Chain V2 需要 managed-reference 起点；当前返回=%@", ret[@"name"] ?: @"?"]];
        [self renderPage];
        return;
    }
    NSString *returnType = [ret[@"name"] isKindOfClass:NSString.class] ? ret[@"name"] : @"";
    NSString *targetNS = @"", *targetClass = returnType;
    NSRange dot = [returnType rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound) { targetNS=[returnType substringToIndex:dot.location]; targetClass=[returnType substringFromIndex:dot.location+1]; }
    ZNM52PresentNodeEditor(self, candidate, [NSMutableArray array], targetNS, targetClass, 1);
}
@end

// Rebind every existing M5.1 "链式调用" button after Finder render. This avoids
// depending on M5.1's file-private associated-object key while preserving button placement.
@interface ZNRuntimeMenuControllerV040 (ZNM52FinderBinding)
- (void)zn60v3_renderResultsAtWidth:(CGFloat)width;
- (void)zn52_renderResultsAtWidth:(CGFloat)width;
- (NSArray<NSDictionary *> *)zn60v3_candidates;
- (NSInteger)znm42_filter;
@end

static void ZNM52CollectChainButtons(UIView *root, NSMutableArray<UIButton *> *buttons) {
    for (UIView *view in root.subviews) {
        if ([view isKindOfClass:UIButton.class] && [[(UIButton *)view titleForState:UIControlStateNormal] isEqualToString:@"链式调用"]) [buttons addObject:(UIButton *)view];
        ZNM52CollectChainButtons(view, buttons);
    }
}

@implementation ZNRuntimeMenuControllerV040 (ZNM52FinderBinding)
- (void)zn52_renderResultsAtWidth:(CGFloat)width {
    [self zn52_renderResultsAtWidth:width];
    NSArray<NSDictionary *> *all = [self zn60v3_candidates] ?: @[];
    NSInteger filter = [self znm42_filter];
    NSMutableArray<NSDictionary *> *visible = [NSMutableArray array];
    for (NSDictionary *candidate in all) if (filter < 0 || [candidate[@"argumentCount"] integerValue] == filter) [visible addObject:candidate];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    ZNM52CollectChainButtons([(id)self contentView], buttons);
    if (buttons.count != visible.count) return;
    for (NSUInteger i = 0; i < buttons.count; i++) {
        UIButton *button = buttons[i];
        objc_setAssociatedObject(button, kZNM52CandidateKey, visible[i], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [button removeTarget:self action:@selector(zn51_chainTapped:) forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:self action:@selector(zn52_chainTapped:) forControlEvents:UIControlEventTouchUpInside];
    }
}
@end

static void ZNM52Swap(Class cls, SEL a, SEL b) {
    Method ma=class_getInstanceMethod(cls,a), mb=class_getInstanceMethod(cls,b);
    if (ma && mb) method_exchangeImplementations(ma,mb);
}

extern "C" void ZNInstallM52ImmediateChainV2Deferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZNM52Swap(ZNIL2CPPInvokeEngine.class, @selector(executeAction:error:), @selector(znm52_executeAction:error:));
        Class menu = NSClassFromString(@"ZNRuntimeMenuControllerV040");
        if (menu) ZNM52Swap(menu, @selector(zn60v3_renderResultsAtWidth:), @selector(zn52_renderResultsAtWidth:));
        [[ZNRuntimeLogger sharedLogger] log:@"[m5.2-chain] Immediate Chain V2 installed: atomic multi-level /0-/8 + exact signatures + token guard + string decode + per-level trace"];
    });
}
