#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

#import "ZNIL2CPPABIMetadata.h"
#import "ZNIL2CPPInvokeEngine.h"
#import "ZNIL2CPPResolver.h"
#import "ZNRuntimeActionModel.h"
#import "ZNPatchCore.h"

typedef void *(*ZNM48ObjectUnboxFn)(void *obj);

static NSString *gZNM48PendingReturnSummary = nil;

static void *ZNM48Symbol(NSString *path, const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p || !path.length) return p;
#ifdef RTLD_NOLOAD
    void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
#else
    void *h = dlopen(path.fileSystemRepresentation, RTLD_LAZY);
#endif
    return h ? dlsym(h, name) : NULL;
}

static NSString *ZNM48PointerString(uintptr_t value) {
    return [NSString stringWithFormat:@"0x%llX", (unsigned long long)value];
}

static NSDictionary<NSString *, id> *ZNM48DecodeReturn(NSDictionary<NSString *, id> *abi,
                                                         uintptr_t rawObject,
                                                         NSString *unityPath) {
    NSDictionary *ret = [abi[@"return"] isKindOfClass:NSDictionary.class] ? abi[@"return"] : @{};
    NSString *typeName = [ret[@"name"] isKindOfClass:NSString.class] ? ret[@"name"] : @"?";
    ZNIL2CPPABIValueKind kind = (ZNIL2CPPABIValueKind)[ret[@"kind"] integerValue];
    NSString *kindName = ZNIL2CPPABIValueKindName(kind);

    NSMutableDictionary *out = [@{
        @"returnType": typeName ?: @"?",
        @"returnKind": kindName ?: @"unknown",
        @"returnRawObject": @(rawObject),
        @"returnDecoded": @NO,
        @"returnValue": rawObject ? ZNM48PointerString(rawObject) : @"0x0",
    } mutableCopy];

    if (kind == ZNIL2CPPABIValueKindVoid) {
        out[@"returnDecoded"] = @YES;
        out[@"returnValue"] = @"void";
        return out;
    }

    if (kind == ZNIL2CPPABIValueKindObjectReference) {
        out[@"returnDecoded"] = @YES;
        out[@"returnValue"] = rawObject ? [NSString stringWithFormat:@"object %@", ZNM48PointerString(rawObject)] : @"null";
        return out;
    }

    if (!rawObject) {
        out[@"returnValue"] = @"null/0x0";
        return out;
    }

    ZNM48ObjectUnboxFn objectUnbox = (ZNM48ObjectUnboxFn)ZNM48Symbol(unityPath, "il2cpp_object_unbox");
    if (!objectUnbox) {
        out[@"returnValue"] = [NSString stringWithFormat:@"boxed %@ (il2cpp_object_unbox unavailable)", ZNM48PointerString(rawObject)];
        return out;
    }

    void *data = objectUnbox((void *)rawObject);
    if (!data) {
        out[@"returnValue"] = [NSString stringWithFormat:@"boxed %@ (unbox failed)", ZNM48PointerString(rawObject)];
        return out;
    }

    switch (kind) {
        case ZNIL2CPPABIValueKindBool: {
            uint8_t v = 0; memcpy(&v, data, sizeof(v));
            out[@"returnValue"] = v ? @"true" : @"false";
            out[@"returnDecoded"] = @YES;
            break;
        }
        case ZNIL2CPPABIValueKindSigned32: {
            int32_t v = 0; memcpy(&v, data, sizeof(v));
            out[@"returnValue"] = [NSString stringWithFormat:@"%d", v];
            out[@"returnDecoded"] = @YES;
            break;
        }
        case ZNIL2CPPABIValueKindUnsigned32: {
            uint32_t v = 0; memcpy(&v, data, sizeof(v));
            out[@"returnValue"] = [NSString stringWithFormat:@"%u", v];
            out[@"returnDecoded"] = @YES;
            break;
        }
        case ZNIL2CPPABIValueKindSigned64: {
            int64_t v = 0; memcpy(&v, data, sizeof(v));
            out[@"returnValue"] = [NSString stringWithFormat:@"%lld", (long long)v];
            out[@"returnDecoded"] = @YES;
            break;
        }
        case ZNIL2CPPABIValueKindUnsigned64: {
            uint64_t v = 0; memcpy(&v, data, sizeof(v));
            out[@"returnValue"] = [NSString stringWithFormat:@"%llu", (unsigned long long)v];
            out[@"returnDecoded"] = @YES;
            break;
        }
        case ZNIL2CPPABIValueKindFloat32: {
            float v = 0; memcpy(&v, data, sizeof(v));
            out[@"returnValue"] = [NSString stringWithFormat:@"%.9g", v];
            out[@"returnDecoded"] = @YES;
            break;
        }
        case ZNIL2CPPABIValueKindFloat64: {
            double v = 0; memcpy(&v, data, sizeof(v));
            out[@"returnValue"] = [NSString stringWithFormat:@"%.17g", v];
            out[@"returnDecoded"] = @YES;
            break;
        }
        case ZNIL2CPPABIValueKindPointer: {
            uintptr_t v = 0; memcpy(&v, data, sizeof(v));
            out[@"returnValue"] = ZNM48PointerString(v);
            out[@"returnDecoded"] = @YES;
            break;
        }
        case ZNIL2CPPABIValueKindComplexValueType:
            out[@"returnValue"] = [NSString stringWithFormat:@"boxed %@ (complex value type; raw only)", ZNM48PointerString(rawObject)];
            break;
        default:
            out[@"returnValue"] = [NSString stringWithFormat:@"boxed %@ (unknown ABI)", ZNM48PointerString(rawObject)];
            break;
    }
    return out;
}

static NSDictionary<NSString *, id> *ZNM48ReturnMetadataForAction(ZNRuntimeMethodAction *action,
                                                                    NSDictionary<NSString *, id> *result) {
    uintptr_t methodInfo = [result[@"methodInfo"] unsignedLongLongValue];
    if (!methodInfo || !action) return @{};

    NSDictionary *candidate = @{
        @"methodInfo": @(methodInfo),
        @"methodPointer": result[@"methodPointer"] ?: @0,
        @"assembly": action.assembly ?: @"",
        @"namespace": action.namespaceName ?: @"",
        @"class": action.className ?: @"",
        @"method": action.methodName ?: @"",
        @"argumentCount": @(action.argumentCount),
        @"canonical": action.canonicalIdentity ?: @"",
    };
    NSDictionary *abi = ZNIL2CPPDescribeMethodABI(candidate);
    if (![abi[@"available"] boolValue]) {
        return @{
            @"returnType": @"?",
            @"returnKind": @"unknown",
            @"returnDecoded": @NO,
            @"returnValue": abi[@"reason"] ?: @"ABI unavailable",
            @"returnRawObject": @0,
        };
    }

    uintptr_t raw = 0;
    if ([result[@"returnObject"] respondsToSelector:@selector(unsignedLongLongValue)]) {
        raw = [result[@"returnObject"] unsignedLongLongValue];
    } else if ([result[@"result"] respondsToSelector:@selector(unsignedLongLongValue)]) {
        raw = [result[@"result"] unsignedLongLongValue];
    }

    ZNIL2CPPResolver *resolver = [ZNIL2CPPResolver sharedResolver];
    [resolver refresh];
    return ZNM48DecodeReturn(abi, raw, resolver.unityPath ?: @"");
}

@interface ZNIL2CPPInvokeEngine (ZNM48ReturnCapture)
- (NSDictionary<NSString *, id> *)znm48_executeAction:(ZNRuntimeMethodAction *)action error:(NSString **)error;
@end

@implementation ZNIL2CPPInvokeEngine (ZNM48ReturnCapture)

- (NSDictionary<NSString *, id> *)znm48_executeAction:(ZNRuntimeMethodAction *)action error:(NSString **)error {
    NSDictionary *base = [self znm48_executeAction:action error:error];
    if (!base) return nil;

    NSDictionary *ret = ZNM48ReturnMetadataForAction(action, base);
    NSMutableDictionary *merged = [base mutableCopy];
    [merged addEntriesFromDictionary:ret];

    NSString *type = ret[@"returnType"] ?: @"?";
    NSString *value = ret[@"returnValue"] ?: @"?";
    uintptr_t raw = [ret[@"returnRawObject"] unsignedLongLongValue];
    NSString *summary = [NSString stringWithFormat:@"返回 %@ = %@ · raw=%@",
                         type,
                         value,
                         ZNM48PointerString(raw)];
    @synchronized (ZNIL2CPPInvokeEngine.class) {
        gZNM48PendingReturnSummary = summary;
    }

    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[m4.8-return] %@ decoded=%d kind=%@",
                                         summary,
                                         [ret[@"returnDecoded"] boolValue] ? 1 : 0,
                                         ret[@"returnKind"] ?: @"unknown"]];
    return [merged copy];
}

@end

@interface ZNRuntimeMenuControllerV040 : NSObject
- (void)zn60v3_setStatus:(NSString *)status;
@end

@interface ZNRuntimeMenuControllerV040 (ZNM48ReturnStatus)
- (void)znm48_setStatus:(NSString *)status;
@end

@implementation ZNRuntimeMenuControllerV040 (ZNM48ReturnStatus)

- (void)znm48_setStatus:(NSString *)status {
    NSString *finalStatus = status ?: @"";
    if ([finalStatus hasPrefix:@"Runtime Invoke SUCCESS"]) {
        NSString *summary = nil;
        @synchronized (ZNIL2CPPInvokeEngine.class) {
            summary = gZNM48PendingReturnSummary;
            gZNM48PendingReturnSummary = nil;
        }
        if (summary.length) finalStatus = summary;
    }
    [self znm48_setStatus:finalStatus];
}

@end

static void ZNM48Swap(Class cls, SEL a, SEL b) {
    Method ma = class_getInstanceMethod(cls, a);
    Method mb = class_getInstanceMethod(cls, b);
    if (ma && mb) method_exchangeImplementations(ma, mb);
}

extern "C" void ZNInstallM48ReturnCaptureDeferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ZNM48Swap(ZNIL2CPPInvokeEngine.class, @selector(executeAction:error:), @selector(znm48_executeAction:error:));
        Class menu = NSClassFromString(@"ZNRuntimeMenuControllerV040");
        if (menu) ZNM48Swap(menu, @selector(zn60v3_setStatus:), @selector(znm48_setStatus:));
        [[ZNRuntimeLogger sharedLogger] log:@"[m4.8-return] return type + runtime_invoke result decoder installed"];
    });
}
