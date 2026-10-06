from pathlib import Path

root = Path('iosruntimepatchmenu')
src = root / 'src'


def replace_once(path, old, new, label):
    p = Path(path)
    s = p.read_text()
    if new in s:
        return
    if old not in s:
        raise SystemExit(f'{label}: source pattern not found in {p}')
    p.write_text(s.replace(old, new, 1))


# Compile the cold launcher/deferred activation coordinator.
makefile = root / 'Makefile'
s = makefile.read_text()
if 'src/ZNDeferredBootstrap.mm' not in s:
    needle = 'ZonoePatchV03_FILES = src/ZonoeRuntimeMenu.mm '
    if needle not in s:
        raise SystemExit('Makefile source list anchor missing')
    s = s.replace(needle, needle + 'src/ZNDeferredBootstrap.mm ', 1)
    makefile.write_text(s)

(src / 'ZNDeferredBootstrap.h').write_text(r'''#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Cold means only the launcher exists. Loading/Ready are entered exclusively
// by the first launcher tap; feature/runtime modules must not initialize before it.
FOUNDATION_EXPORT BOOL ZNDeferredBootstrapIsActivated(void)
    __attribute__((visibility("hidden")));
FOUNDATION_EXPORT BOOL ZNDeferredBootstrapIsReady(void)
    __attribute__((visibility("hidden")));

#ifdef __cplusplus
}
#endif
''')

(src / 'ZNDeferredBootstrap.mm').write_text(r'''#import "ZNDeferredBootstrap.h"
#import <UIKit/UIKit.h>
#import <atomic>

extern "C" void ZNInstallSharedSiteExecutionProbeV3Deferred(void);
extern "C" void ZNInstallPublicCompactLayoutDeferred(void);
extern "C" void ZNInstallRuntimeExecutorV041Deferred(void);
extern "C" void ZNInstallRuntimeDiagnosticsV042Deferred(void);
extern "C" void ZNPrepareStaticDispatchRuntimeDeferred(void);
extern "C" void ZNInstallRuntimeMenuV055Deferred(void);
extern "C" void ZNInstallFeatureGroupUIDeferred(void);
extern "C" void ZNInstallPublicCompactDefaultsDeferred(void);
extern "C" void ZNInstallFeatureBuilderUIDeferred(void);

extern "C" void ZonoePatchStart(void);
extern "C" void ZonoePatchShow(void);

typedef NS_ENUM(int, ZNDeferredState) {
    ZNDeferredStateCold = 0,
    ZNDeferredStateLoading = 1,
    ZNDeferredStateReady = 2,
    ZNDeferredStateFailed = 3,
};

static std::atomic<int> gZNDeferredState{ZNDeferredStateCold};
static NSString * const kZNDeferredFloatPositionKey = @"ZonoePatch.FloatCenter";
static const CGFloat kZNDeferredFloatSize = 52.0;
static const CGFloat kZNDeferredMargin = 10.0;

extern "C" BOOL ZNDeferredBootstrapIsActivated(void) {
    int state = gZNDeferredState.load(std::memory_order_acquire);
    return state == ZNDeferredStateLoading || state == ZNDeferredStateReady;
}

extern "C" BOOL ZNDeferredBootstrapIsReady(void) {
    return gZNDeferredState.load(std::memory_order_acquire) == ZNDeferredStateReady;
}

static UIWindow *ZNDeferredCurrentWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        UIWindow *fallback = nil;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.hidden || window.alpha <= 0.01) continue;
                if (window.isKeyWindow) return window;
                if (!fallback && window.windowLevel == UIWindowLevelNormal && window.rootViewController) fallback = window;
            }
        }
        if (fallback) return fallback;
    }
    if (app.keyWindow && !app.keyWindow.hidden) return app.keyWindow;
    for (UIWindow *window in app.windows.reverseObjectEnumerator) {
        if (!window.hidden && window.windowLevel == UIWindowLevelNormal && window.rootViewController) return window;
    }
    return nil;
}

@interface ZNDeferredLauncher : NSObject
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,weak) UIWindow *hostWindow;
- (void)installIfPossible;
@end

@implementation ZNDeferredLauncher

+ (instancetype)sharedLauncher {
    static ZNDeferredLauncher *launcher;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ launcher = [ZNDeferredLauncher new]; });
    return launcher;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(zn_windowChanged:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(zn_windowChanged:) name:UIWindowDidBecomeKeyNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)zn_windowChanged:(NSNotification *)note {
    (void)note;
    [self installIfPossible];
}

- (CGPoint)zn_clamp:(CGPoint)center window:(UIWindow *)window {
    UIEdgeInsets safe = window.safeAreaInsets;
    CGFloat half = kZNDeferredFloatSize * 0.5;
    CGFloat left = safe.left + kZNDeferredMargin + half;
    CGFloat right = CGRectGetWidth(window.bounds) - safe.right - kZNDeferredMargin - half;
    CGFloat top = safe.top + kZNDeferredMargin + half;
    CGFloat bottom = CGRectGetHeight(window.bounds) - safe.bottom - kZNDeferredMargin - half;
    center.x = MIN(MAX(center.x, left), MAX(left, right));
    center.y = MIN(MAX(center.y, top), MAX(top, bottom));
    return center;
}

- (void)installIfPossible {
    if (gZNDeferredState.load(std::memory_order_acquire) == ZNDeferredStateReady) return;
    UIWindow *window = ZNDeferredCurrentWindow();
    if (!window) return;

    if (!self.button) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.bounds = CGRectMake(0, 0, kZNDeferredFloatSize, kZNDeferredFloatSize);
        button.layer.cornerRadius = kZNDeferredFloatSize * 0.5;
        button.layer.borderWidth = 1.5;
        button.layer.borderColor = [UIColor colorWithRed:0.42 green:0.55 blue:1.0 alpha:1.0].CGColor;
        button.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        [button setTitle:@"ZN" forState:UIControlStateNormal];
        [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        button.layer.shadowColor = UIColor.blackColor.CGColor;
        button.layer.shadowOpacity = 0.28;
        button.layer.shadowRadius = 8.0;
        button.layer.shadowOffset = CGSizeZero;
        [button addTarget:self action:@selector(zn_activate:) forControlEvents:UIControlEventTouchUpInside];
        [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(zn_pan:)]];
        self.button = button;
    }

    if (self.button.superview != window) {
        [self.button removeFromSuperview];
        self.hostWindow = window;
        NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kZNDeferredFloatPositionKey];
        UIEdgeInsets safe = window.safeAreaInsets;
        CGPoint fallback = CGPointMake(CGRectGetWidth(window.bounds) - safe.right - kZNDeferredMargin - kZNDeferredFloatSize * 0.5,
                                       CGRectGetMidY(window.bounds));
        self.button.center = [self zn_clamp:(stored.length ? CGPointFromString(stored) : fallback) window:window];
        [window addSubview:self.button];
    }
    [window bringSubviewToFront:self.button];
}

- (void)zn_pan:(UIPanGestureRecognizer *)gesture {
    if (gZNDeferredState.load(std::memory_order_acquire) != ZNDeferredStateCold) return;
    UIWindow *window = self.hostWindow;
    if (!window) return;
    CGPoint translation = [gesture translationInView:window];
    CGPoint center = self.button.center;
    center.x += translation.x;
    center.y += translation.y;
    self.button.center = [self zn_clamp:center window:window];
    [gesture setTranslation:CGPointZero inView:window];
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        [NSUserDefaults.standardUserDefaults setObject:NSStringFromCGPoint(self.button.center) forKey:kZNDeferredFloatPositionKey];
    }
}

- (void)zn_markFailed:(NSException *)exception {
    gZNDeferredState.store(ZNDeferredStateFailed, std::memory_order_release);
    self.button.enabled = NO;
    self.button.alpha = 1.0;
    [self.button setTitle:@"!" forState:UIControlStateNormal];
    NSLog(@"[ZonoPatch] v0.5.5 deferred activation failed: %@", exception.reason ?: @"unknown exception");
}

- (void)zn_finishActivation {
    @try {
        ZNInstallRuntimeMenuV055Deferred();
        ZNInstallFeatureGroupUIDeferred();
        ZNInstallPublicCompactDefaultsDeferred();
        ZNInstallFeatureBuilderUIDeferred();

        gZNDeferredState.store(ZNDeferredStateReady, std::memory_order_release);
        ZonoePatchStart();
        ZonoePatchShow();

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.button removeFromSuperview];
            self.button = nil;
            self.hostWindow = nil;
        });
    } @catch (NSException *exception) {
        [self zn_markFailed:exception];
    }
}

- (void)zn_beginActivation {
    @try {
        // Old +load-era wrappers, then former constructor priorities 104/106/109.
        ZNInstallSharedSiteExecutionProbeV3Deferred();
        ZNInstallPublicCompactLayoutDeferred();
        ZNInstallRuntimeExecutorV041Deferred();
        ZNInstallRuntimeDiagnosticsV042Deferred();
        ZNPrepareStaticDispatchRuntimeDeferred();

        // Static Dispatch historically waits 350 ms before refresh. Keep that
        // exact stage behavior. This continuation is queued later on the same
        // main queue, so the refresh must finish before the menu is revealed.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self zn_finishActivation];
        });
    } @catch (NSException *exception) {
        [self zn_markFailed:exception];
    }
}

- (void)zn_activate:(id)sender {
    (void)sender;
    int expected = ZNDeferredStateCold;
    if (!gZNDeferredState.compare_exchange_strong(expected,
                                                   ZNDeferredStateLoading,
                                                   std::memory_order_acq_rel)) {
        return;
    }

    self.button.enabled = NO;
    self.button.alpha = 0.78;
    [self.button setTitle:@"…" forState:UIControlStateNormal];

    // One UI beat makes the loading state visible before the original startup
    // chain begins. The menu appears only after all deferred stages complete.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self zn_beginActivation];
    });
}

@end

// The only v0.5.5 load-time constructor. It owns the cold launcher only and
// intentionally does not touch DeveloperGate, PatchManager, Resolver, Static
// Dispatch, Builder, Diagnostics, Probe, Feature UI, or the menu controller.
__attribute__((constructor(200))) static void ZNDeferredColdLauncherBootstrap(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ZNDeferredLauncher sharedLauncher] installIfPossible];
    });
}
''')

# Former automatic module installers become explicit deferred stages.
replace_once(src / 'ZNPatchCoreV041.mm',
             '__attribute__((constructor(104))) static void ZNInstallRuntimeExecutorV041(void) {',
             'extern "C" void ZNInstallRuntimeExecutorV041Deferred(void) {',
             'runtime executor installer')

replace_once(src / 'ZNRuntimeDiagnosticsV042.mm',
             '__attribute__((constructor(106))) static void ZNInstallRuntimeDiagnosticsV042(void) {',
             'extern "C" void ZNInstallRuntimeDiagnosticsV042Deferred(void) {',
             'runtime diagnostics installer')
d = (src / 'ZNRuntimeDiagnosticsV042.mm').read_text()
d = d.replace('File 1 is evaluated once by ZNDeveloperGate.', 'File 1 is evaluated once when deferred activation first reaches ZNDeveloperGate.')
d = d.replace('enabled from startup g permission', 'enabled from first-activation g permission')
(src / 'ZNRuntimeDiagnosticsV042.mm').write_text(d)

replace_once(src / 'ZNStaticDispatchRuntime.mm',
             '__attribute__((constructor(109))) static void ZN44StaticDispatchBootstrap(void) {',
             'extern "C" void ZNPrepareStaticDispatchRuntimeDeferred(void) {',
             'static dispatch installer')

# Shared-Site V3 used +load only to install two method wrappers.
p = src / 'ZNSharedSiteExecutionProbeV3Bootstrap.mm'
s = p.read_text()
if '+ (void)znssp3_installDeferredBootstrap' not in s:
    if '+ (void)load {' not in s:
        raise SystemExit('shared-site V3 +load anchor missing')
    s = s.replace('+ (void)load {', '+ (void)znssp3_installDeferredBootstrap {', 1)
if 'ZNInstallSharedSiteExecutionProbeV3Deferred' not in s:
    s = s.rstrip() + r'''

extern "C" void ZNInstallSharedSiteExecutionProbeV3Deferred(void) {
    [ZNSharedSiteProbe znssp3_installDeferredBootstrap];
}
'''
p.write_text(s)

# Public compact layout +load and constructor become explicit stages.
p = src / 'ZNPublicCompactUI.mm'
s = p.read_text()
if '+ (void)znpublic_installLayoutDeferred' not in s:
    if '+ (void)load {' not in s:
        raise SystemExit('public compact +load anchor missing')
    s = s.replace('+ (void)load {', '+ (void)znpublic_installLayoutDeferred {', 1)
if 'ZNInstallPublicCompactLayoutDeferred' not in s:
    marker = '\n@end\n\n__attribute__((constructor(121))) static void ZNInstallPublicCompactDefaults(void) {'
    if marker not in s:
        raise SystemExit('public compact constructor anchor missing')
    replacement = r'''
@end

extern "C" void ZNInstallPublicCompactLayoutDeferred(void) {
    [ZNRuntimeMenuControllerV040 znpublic_installLayoutDeferred];
}

extern "C" void ZNInstallPublicCompactDefaultsDeferred(void) {'''
    s = s.replace(marker, '\n' + replacement, 1)
s = s.replace('v0.5.4 Consolidation Phase 2', 'v0.5.5 Full Deferred Bootstrap')
s = s.replace('self.subtitleLabel.text = @"0.5.4"', 'self.subtitleLabel.text = @"0.5.5"')
s = s.replace('v0.5.4 public compact UI installed', 'v0.5.5 public compact UI installed after first activation')
p.write_text(s)

replace_once(src / 'ZNFeatureGroupUI.mm',
             '__attribute__((constructor(120))) static void ZNInstallFeatureGroupUI(void) {',
             'extern "C" void ZNInstallFeatureGroupUIDeferred(void) {',
             'feature group installer')
f = (src / 'ZNFeatureGroupUI.mm').read_text()
f = f.replace('v0.5.4 feature UI installed', 'v0.5.5 feature UI installed after first activation')
(src / 'ZNFeatureGroupUI.mm').write_text(f)

replace_once(src / 'ZNFeatureBuilderUI.mm',
             '__attribute__((constructor(121))) static void ZNInstallFeatureBuilderUI(void) {',
             'extern "C" void ZNInstallFeatureBuilderUIDeferred(void) {',
             'feature builder installer')

# Developer marker semantics move from process startup to first icon activation.
p = src / 'ZNDeveloperGate.mm'
s = p.read_text()
if '#import "ZNDeferredBootstrap.h"' not in s:
    s = s.replace('#import "ZNPatchCore.h"\n', '#import "ZNPatchCore.h"\n#import "ZNDeferredBootstrap.h"\n', 1)
s = s.replace('_startupEvaluated', '_activationEvaluated')
s = s.replace('启动时未找到开发者标记文件 1', '首次点击激活时未找到开发者标记文件 1')
s = s.replace('启动时读取标记文件失败', '首次点击激活时读取标记文件失败')
s = s.replace('v0.5.2 policy: developer permission is a process-start snapshot.', 'v0.5.5 policy: developer permission is a first-menu-activation snapshot.')
s = s.replace('[dev-gate] startup snapshot: public mode', '[dev-gate] first-activation snapshot: public mode')
s = s.replace('[dev-gate] startup snapshot cached:', '[dev-gate] first-activation snapshot cached:')
s = s.replace('case ZNIdentitySourceMarkerFile: return @"启动标记文件";', 'case ZNIdentitySourceMarkerFile: return @"首次点击标记文件";')
s = s.replace('启动检查: 已缓存，本进程不重新读取', '首次点击检查: 已缓存，本进程不重新读取')
old = '''extern "C" __attribute__((visibility("default"))) bool ZonoePatchDeveloperAuthorized(void) {
    return [ZNDeveloperGate sharedGate].authorized;
}

extern "C" __attribute__((visibility("default"))) bool ZonoePatchOtherAuthorized(void) {
    return [ZNDeveloperGate sharedGate].otherAuthorized;
}'''
new = '''extern "C" __attribute__((visibility("default"))) bool ZonoePatchDeveloperAuthorized(void) {
    if (!ZNDeferredBootstrapIsActivated()) return false;
    return [ZNDeveloperGate sharedGate].authorized;
}

extern "C" __attribute__((visibility("default"))) bool ZonoePatchOtherAuthorized(void) {
    if (!ZNDeferredBootstrapIsActivated()) return false;
    return [ZNDeveloperGate sharedGate].otherAuthorized;
}'''
if new not in s:
    if old not in s:
        raise SystemExit('developer exported authorization anchor missing')
    s = s.replace(old, new, 1)
s = s.replace('extern "C" __attribute__((visibility("default"))) void ZonoePatchRequestUDIDValidation(void) {\n    dispatch_async',
              'extern "C" __attribute__((visibility("default"))) void ZonoePatchRequestUDIDValidation(void) {\n    if (!ZNDeferredBootstrapIsActivated()) return;\n    dispatch_async', 1)
s = s.replace('extern "C" __attribute__((visibility("default"))) void ZonoePatchSubmitHostIdentity(const char *udid, bool authorized) {\n    (void)udid;',
              'extern "C" __attribute__((visibility("default"))) void ZonoePatchSubmitHostIdentity(const char *udid, bool authorized) {\n    if (!ZNDeferredBootstrapIsActivated()) return;\n    (void)udid;', 1)
p.write_text(s)

# Main runtime/menu constructor becomes explicit stage 119.
p = src / 'ZonoeRuntimeMenu.mm'
s = p.read_text()
if '#import "ZNDeferredBootstrap.h"' not in s:
    s = s.replace('#import "ZNIL2CPPResolver.h"\n', '#import "ZNIL2CPPResolver.h"\n#import "ZNDeferredBootstrap.h"\n', 1)
replacements = {
    'v0.5.4 current UI bootstrap consolidation': 'v0.5.5 full deferred bootstrap',
    'Runtime Patch Menu 0.5.4 consolidated bootstrap': 'Runtime Patch Menu 0.5.5 deferred bootstrap',
    '0.5.4-ui-core': '0.5.5-ui-core',
    '0.5.4-ui-consolidated': '0.5.5-ui-consolidated',
    'PatchCore 0.5.4': 'PatchCore 0.5.5',
    '// v0.5.4 current UI layer.': '// v0.5.5 current UI layer.',
}
for a, b in replacements.items():
    s = s.replace(a, b)

old_ctor = '''__attribute__((constructor(119))) static void ZNRuntimeMenuBootstrapV053(void) {
    @autoreleasepool {
        [ZNPatchManager sharedManager];
        [[ZNDeveloperGate sharedGate] refresh];
        [[ZNIL2CPPResolver sharedResolver] refresh];
        ZNInstallV053CurrentUI();
        [[ZNRuntimeLogger sharedLogger] log:@"[bootstrap][main] v0.5.4 current UI bootstrap active"];
        ZonoePatchStart();
    }
}'''
new_ctor = '''extern "C" void ZNInstallRuntimeMenuV055Deferred(void) {
    @autoreleasepool {
        [ZNPatchManager sharedManager];
        [[ZNDeveloperGate sharedGate] refresh];
        [[ZNIL2CPPResolver sharedResolver] refresh];
        ZNInstallV053CurrentUI();
        [[ZNRuntimeLogger sharedLogger] log:@"[bootstrap][deferred] v0.5.5 current UI installed after first launcher tap"];
    }
}'''
if new_ctor not in s:
    if old_ctor not in s:
        raise SystemExit('main runtime constructor anchor missing')
    s = s.replace(old_ctor, new_ctor, 1)

old_api = '''extern "C" __attribute__((visibility("default"))) void ZonoePatchStart(void) {
    [[ZNDeveloperGate sharedGate] refresh];
    [ZNPatchManager sharedManager];
    [[ZNIL2CPPResolver sharedResolver] refresh];
    ZonoePatchStartBaselineV024();
}
extern "C" __attribute__((visibility("default"))) void ZonoePatchShow(void) { ZonoePatchShowBaselineV024(); }
extern "C" __attribute__((visibility("default"))) void ZonoePatchHide(void) { ZonoePatchHideBaselineV024(); }
extern "C" __attribute__((visibility("default"))) bool ZonoePatchIsVisible(void) { return ZonoePatchIsVisibleBaselineV024(); }'''
new_api = '''extern "C" __attribute__((visibility("default"))) void ZonoePatchStart(void) {
    if (!ZNDeferredBootstrapIsActivated()) return;
    [[ZNDeveloperGate sharedGate] refresh];
    [ZNPatchManager sharedManager];
    [[ZNIL2CPPResolver sharedResolver] refresh];
    ZonoePatchStartBaselineV024();
}
extern "C" __attribute__((visibility("default"))) void ZonoePatchShow(void) {
    if (!ZNDeferredBootstrapIsActivated()) return;
    ZonoePatchShowBaselineV024();
}
extern "C" __attribute__((visibility("default"))) void ZonoePatchHide(void) {
    if (!ZNDeferredBootstrapIsActivated()) return;
    ZonoePatchHideBaselineV024();
}
extern "C" __attribute__((visibility("default"))) bool ZonoePatchIsVisible(void) {
    return ZNDeferredBootstrapIsActivated() && ZonoePatchIsVisibleBaselineV024();
}'''
if new_api not in s:
    if old_api not in s:
        raise SystemExit('current public menu API anchor missing')
    s = s.replace(old_api, new_api, 1)
p.write_text(s)

print('v0.5.5 deferred bootstrap transform complete')
