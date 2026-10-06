#import "ZNSharedSiteExecutionProbeV3.h"
#import "ZNSharedSiteProbe.h"
#import <objc/runtime.h>
#import <dlfcn.h>

static IMP gZNSSP3FeatureChainIMP = NULL;
static BOOL gZNSSP3Attached = NO;
static BOOL gZNSSP3AttachPolling = NO;

static IMP ZNSSP3AnchorIMPForClass(Class cls) {
    if (!cls) return NULL;
    SEL selectors[] = {@selector(identifier), @selector(address), @selector(setActive:)};
    for (unsigned i=0;i<sizeof(selectors)/sizeof(selectors[0]);i++) {
        Method m=class_getInstanceMethod(cls,selectors[i]);
        IMP imp=m?method_getImplementation(m):NULL;
        if (!imp) continue;
        Dl_info info={0};
        if (!dladdr((void *)imp,&info)||!info.dli_fname) continue;
        NSString *path=[NSString stringWithUTF8String:info.dli_fname]?:@"";
        if ([path.lastPathComponent rangeOfString:@"ZonoePatch" options:NSCaseInsensitiveSearch].location==NSNotFound)
            return imp;
    }
    return NULL;
}

static void ZNSSP3FeatureSetActive(id self, SEL _cmd, BOOL active) {
    ZNSharedSiteProbe *probe=[ZNSharedSiteProbe sharedProbe];
    BOOL logging=probe.isLoggingEnabled;
    if (logging) ZNSSPV3FeatureBegin(self,active);
    if (gZNSSP3FeatureChainIMP)
        ((void(*)(id,SEL,BOOL))gZNSSP3FeatureChainIMP)(self,_cmd,active);
    if (logging) ZNSSPV3FeatureEnd(self,active);
}

static BOOL ZNSSP3AttachIfReady(void) {
    if (gZNSSP3Attached) return YES;
    ZNSharedSiteProbe *probe=[ZNSharedSiteProbe sharedProbe];
    if (!probe.isInstalled) return NO;

    Class cls=NSClassFromString(probe.targetClassName.length?probe.targetClassName:@"MdhpNuX");
    if (!cls) cls=NSClassFromString(@"MdhpNuX");
    if (!cls) return NO;

    Method resolved=class_getInstanceMethod(cls,@selector(setActive:));
    if (!resolved) return NO;
    const char *types=method_getTypeEncoding(resolved);
    IMP current=method_getImplementation(resolved);
    if (!types||!current) return NO;

    IMP anchor=ZNSSP3AnchorIMPForClass(cls);
    if (anchor) ZNSSPV3InstallExecutionProbes(anchor);

    gZNSSP3FeatureChainIMP=current;
    BOOL added=class_addMethod(cls,@selector(setActive:),(IMP)ZNSSP3FeatureSetActive,types);
    if (!added) {
        Method direct=class_getInstanceMethod(cls,@selector(setActive:));
        if (!direct) return NO;
        method_setImplementation(direct,(IMP)ZNSSP3FeatureSetActive);
    }
    gZNSSP3Attached=YES;
    gZNSSP3AttachPolling=NO;
    return YES;
}

static void ZNSSP3PollAttachAfterExplicitEnable(NSUInteger remaining) {
    if (ZNSSP3AttachIfReady()) return;
    if (!remaining) {
        gZNSSP3AttachPolling=NO;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        ZNSSP3PollAttachAfterExplicitEnable(remaining-1);
    });
}

@implementation ZNSharedSiteProbe (ZNExecutionProbeV3Diagnostics)

+ (void)znssp3_installDeferredBootstrap {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        Method diagnostic=class_getInstanceMethod(self,@selector(diagnosticLines));
        Method diagnosticReplacement=class_getInstanceMethod(self,@selector(znssp3_diagnosticLines));
        if (diagnostic&&diagnosticReplacement) method_exchangeImplementations(diagnostic,diagnosticReplacement);

        Method install=class_getInstanceMethod(self,@selector(installAndEnable:));
        Method installReplacement=class_getInstanceMethod(self,@selector(znssp3_installAndEnable:));
        if (install&&installReplacement) method_exchangeImplementations(install,installReplacement);
    });
}

- (BOOL)znssp3_installAndEnable:(NSString **)error {
    // After swizzling, this selector calls the V2 explicit-enable implementation.
    BOOL ok=[self znssp3_installAndEnable:error];
    if (!ok) return NO;

    // v0.5.2 consolidation: V3 instrumentation is lazy. There is no startup
    // polling. A bounded attach retry starts only after the developer explicitly
    // presses "启用 Probe".
    if (!ZNSSP3AttachIfReady() && !gZNSSP3AttachPolling) {
        gZNSSP3AttachPolling=YES;
        dispatch_async(dispatch_get_main_queue(),^{ ZNSSP3PollAttachAfterExplicitEnable(20); });
    }
    return YES;
}

- (NSArray<NSString *> *)znssp3_diagnosticLines {
    NSArray<NSString *> *base=[self znssp3_diagnosticLines]?:@[];
    NSMutableArray<NSString *> *lines=[base mutableCopy];
    [lines addObjectsFromArray:ZNSSPV3DiagnosticLines()];
    [lines addObject:gZNSSP3Attached?@"Execution Probe V3: attached":@"Execution Probe V3: idle until explicit enable"];
    return lines;
}

@end

extern "C" void ZNInstallSharedSiteExecutionProbeV3Deferred(void) {
    [ZNSharedSiteProbe znssp3_installDeferredBootstrap];
}
