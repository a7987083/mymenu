// v0.5.3 current UI layer. One swizzle set owns active menu behavior instead of
// chaining V040/V0401/V0402/V042/V043/V044/V045/V048/V049 wrappers.
@interface ZNRuntimeMenuControllerV040 (V053Current)
- (instancetype)zn53_init;
- (void)zn53_makeUI:(UIWindow *)window;
- (void)zn53_tick:(NSTimer *)timer;
- (void)zn53_togglePanel:(id)sender;
- (void)zn53_renderPage;
- (void)zn53_renderFullPage;
- (void)zn53_renderDebug;
- (CGSize)zn53_fullSizeForWindow:(UIWindow *)window;
- (void)zn53_themeTapped:(id)sender;
- (UIButton *)zn53_button:(NSString *)title selector:(SEL)selector frame:(CGRect)frame;
- (void)zn53_addInfoCard:(NSString *)title lines:(NSArray<NSString *> *)lines y:(CGFloat *)y width:(CGFloat)width;
- (void)zn53_selfTest:(id)sender;
@end

@implementation ZNRuntimeMenuControllerV040 (V053Current)

- (instancetype)zn53_init {
    id obj = [self zn53_init];
    if (!obj) return nil;
    [ZNPatchManager sharedManager];
    [[ZNDeveloperGate sharedGate] refresh];
    [self zn40_refreshDeveloperCategories:NO];
    return obj;
}

- (void)zn53_applyTouchPolicy {
    NSString *cat = (self.selectedCategory >= 0 && self.selectedCategory < self.categories.count)
        ? self.categories[self.selectedCategory] : @"";
    BOOL developerPage = [cat isEqualToString:@"诊断"] || [cat isEqualToString:@"Debug"];
    self.contentScroll.delaysContentTouches = !developerPage;
    self.contentScroll.canCancelContentTouches = YES;
}

- (void)zn53_makeUI:(UIWindow *)window {
    [self zn53_makeUI:window];
    [self zn40_refreshDeveloperCategories:YES];
    [self zn40_updateSubtitle];
    [self zn53_applyTouchPolicy];
    self.footerLabel.text = [NSString stringWithFormat:@"PatchCore 0.5.3    Current UI    iOS %@", UIDevice.currentDevice.systemVersion];
}

- (void)zn53_tick:(NSTimer *)timer {
    [self zn53_tick:timer];
    // Developer authorization is a process-start snapshot in v0.5.2+; no
    // marker re-read or category mutation occurs on the periodic UI tick.
    [self zn40_updateSubtitle];
    if (self.uiReady) self.footerLabel.text = [NSString stringWithFormat:@"PatchCore 0.5.3    Current UI    iOS %@", UIDevice.currentDevice.systemVersion];
}

- (void)zn53_togglePanel:(id)sender {
    [self zn53_togglePanel:sender];
    [self zn40_updateSubtitle];
}

- (void)zn53_renderPage {
    [self zn53_applyTouchPolicy];
    [self zn53_renderPage];
}

- (void)zn53_renderDebug {
    [self zn40_renderDebug];

    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat y = MAX(CGRectGetHeight(self.contentView.frame), CGRectGetHeight(self.contentScroll.bounds)) + 4.0;
    ZNPatchRuntimeValidator *validator = [ZNPatchRuntimeValidator sharedValidator];

    [self addSection:@"Patch 实机验证"
            subtitle:@"开发者工具 · target + offset + patch · Live Original · 临时应用 / 精确恢复"
                   y:&y width:width];
    [self zn40_addInfoCard:@"当前验证会话" lines:[validator diagnosticLines] y:&y width:width];
    [self zn40_addActionCardY:&y width:width titles:@[@"配置 Patch", @"读取 / 验证"] selectors:@[@"zn43_configureRuntimePatch:", @"zn43_validateRuntimePatch:"]];
    [self zn40_addActionCardY:&y width:width titles:@[@"临时应用", @"恢复原始"] selectors:@[@"zn43_applyRuntimePatch:", @"zn43_restoreRuntimePatch:"]];
    [self zn40_addActionCardY:&y width:width titles:@[@"复制验证报告", @"清除会话"] selectors:@[@"zn43_copyRuntimeValidation:", @"zn43_clearRuntimeValidation:"]];
    [self zn40_updateContentHeight:y];

    y = MAX(CGRectGetHeight(self.contentView.frame), CGRectGetHeight(self.contentScroll.bounds)) + 4.0;
    ZNSharedSiteProbe *probe = [ZNSharedSiteProbe sharedProbe];
    [self addSection:@"Shared-Site Probe"
            subtitle:@"开发者专项探针 · MdhpNuX -setActive: · Posters(5) / Prestige(10) · 只读共享地址"
                   y:&y width:width];
    [self zn40_addInfoCard:@"0x2E25904 专项状态" lines:[probe diagnosticLines] y:&y width:width];
    NSString *toggleTitle = probe.isLoggingEnabled ? @"暂停 Probe" : @"启用 Probe";
    [self zn40_addActionCardY:&y width:width titles:@[toggleTitle, @"记录当前状态"] selectors:@[@"zn49_toggleSharedSiteProbe:", @"zn49_snapshotSharedSiteProbe:"]];
    [self zn40_addActionCardY:&y width:width titles:@[@"清除 Probe 日志", @"复制 Probe 日志"] selectors:@[@"zn49_clearSharedSiteProbe:", @"zn49_copySharedSiteProbe:"]];
    [self zn40_updateContentHeight:y];
}

- (void)zn53_renderFullPage {
    NSString *cat = (self.selectedCategory >= 0 && self.selectedCategory < self.categories.count)
        ? self.categories[self.selectedCategory] : @"";
    if ([cat isEqualToString:@"诊断"]) { [self zn40_renderDiagnostics]; return; }
    if ([cat isEqualToString:@"Debug"]) { [self zn53_renderDebug]; return; }
    if ([cat isEqualToString:@"其他"]) { [self zn44_renderOther]; return; }
    [self zn53_renderFullPage];
}

- (CGSize)zn53_fullSizeForWindow:(UIWindow *)window {
    CGSize size = [self zn53_fullSizeForWindow:window];
    NSString *cat = (self.selectedCategory >= 0 && self.selectedCategory < self.categories.count)
        ? self.categories[self.selectedCategory] : @"";
    CGFloat desired = size.height;
    if ([cat isEqualToString:@"功能"]) desired = MAX(desired, 390.0);
    else if ([cat isEqualToString:@"其他"]) desired = MAX(desired, 500.0);
    else if ([cat isEqualToString:@"设置"]) desired = MAX(desired, 415.0);
    else if ([cat isEqualToString:@"主题"]) {
        BOOL landscape = CGRectGetWidth(window.bounds) >= CGRectGetHeight(window.bounds);
        desired = MAX(desired, landscape ? 410.0 : 430.0);
    } else if ([cat isEqualToString:@"诊断"] || [cat isEqualToString:@"Debug"]) {
        desired = MAX(desired, 470.0);
    }
    UIEdgeInsets insets = window.safeAreaInsets;
    CGFloat available = MAX(300.0, CGRectGetHeight(window.bounds)-insets.top-insets.bottom-20.0);
    size.height = MIN(desired, available);
    return size;
}

- (void)zn53_themeTapped:(id)sender {
    (void)sender;
    if (self.compactMode) return;
    NSInteger idx = [self.categories indexOfObject:@"主题"];
    if (idx == NSNotFound) return;
    self.selectedCategory = idx;
    [NSUserDefaults.standardUserDefaults setInteger:idx forKey:@"ZonoePatch.SelectedCategory"];
    self.contentScroll.contentOffset = CGPointZero;
    [self layoutForWindow:self.hostWindow initial:NO];
    [self updateSidebar];
    [self renderPage];
}

- (UIButton *)zn53_button:(NSString *)title selector:(SEL)selector frame:(CGRect)frame {
    UIButton *button = [self zn53_button:title selector:selector frame:frame];
    button.showsTouchWhenHighlighted = YES;
    button.exclusiveTouch = YES;
    return button;
}

- (void)zn53_addInfoCard:(NSString *)title lines:(NSArray<NSString *> *)lines y:(CGFloat *)y width:(CGFloat)width {
    CGFloat cardWidth = MAX(0.0, width - 20.0);
    CGFloat textWidth = MAX(20.0, cardWidth - 26.0);
    UIFont *font = [self menuFont:9.8 weight:UIFontWeightRegular];
    NSMutableArray<NSNumber *> *heights = [NSMutableArray arrayWithCapacity:lines.count];
    CGFloat bodyHeight = 0.0;
    for (NSString *line in lines) {
        CGRect r = [line boundingRectWithSize:CGSizeMake(textWidth, CGFLOAT_MAX)
                                      options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                   attributes:@{NSFontAttributeName:font} context:nil];
        CGFloat h = MAX(17.0, ceil(CGRectGetHeight(r)) + 3.0);
        [heights addObject:@(h)];
        bodyHeight += h;
    }
    CGFloat h = 30.0 + bodyHeight + 8.0;
    UIView *card = [self cardAtY:*y height:h width:width compact:NO];
    UILabel *t = [self label:title size:12.8 weight:UIFontWeightSemibold color:self.theme.primaryTextColor];
    t.frame = CGRectMake(13,7,card.bounds.size.width-26,19);
    [card addSubview:t];
    CGFloat ly = 28.0;
    for (NSUInteger i=0; i<lines.count; i++) {
        UILabel *l = [self label:lines[i] size:9.8 weight:UIFontWeightRegular color:self.theme.secondaryTextColor];
        CGFloat lineHeight = heights[i].doubleValue;
        l.frame = CGRectMake(13,ly,card.bounds.size.width-26,lineHeight);
        l.numberOfLines = 0;
        l.lineBreakMode = NSLineBreakByWordWrapping;
        l.adjustsFontSizeToFitWidth = NO;
        [card addSubview:l];
        ly += lineHeight;
    }
    [self.contentView addSubview:card];
    *y += h + 8.0;
}

- (void)zn53_selfTest:(id)sender {
    [self zn53_selfTest:sender];
    CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
    BOOL supported = [[ZNExecutablePageProbe sharedProbe] runProbe];
    double totalMs = (CFAbsoluteTimeGetCurrent() - begin) * 1000.0;
    [[ZNRuntimeLogger sharedLogger] log:[NSString stringWithFormat:@"[probe][%@] __TEXT RX→RW→RX %@ total=%.2fms detail=%@",
        NSThread.isMainThread?@"main":@"bg", supported?@"PASS":@"UNSUPPORTED/FAIL", totalMs,
        [ZNExecutablePageProbe sharedProbe].lastResult ?: @""]];
    [self renderPage];
}

@end

static void ZNSwapV053(Class cls, SEL a, SEL b) {
    Method x = class_getInstanceMethod(cls,a), y = class_getInstanceMethod(cls,b);
    if (x && y) method_exchangeImplementations(x,y);
}

static void ZNInstallV053CurrentUI(void) {
    Class cls = NSClassFromString(@"ZNRuntimeMenuControllerV040");
    if (!cls) return;
    ZNSwapV053(cls,@selector(init),@selector(zn53_init));
    ZNSwapV053(cls,@selector(enabledForFeature:),@selector(zn40_enabledForFeature:));
    ZNSwapV053(cls,@selector(setFeature:enabled:),@selector(zn40_setFeature:enabled:));
    ZNSwapV053(cls,@selector(valueForFeature:fallback:),@selector(zn40_valueForFeature:fallback:));
    ZNSwapV053(cls,@selector(setFeature:value:),@selector(zn40_setFeature:value:));
    ZNSwapV053(cls,@selector(makeUI:),@selector(zn53_makeUI:));
    ZNSwapV053(cls,@selector(tick:),@selector(zn53_tick:));
    ZNSwapV053(cls,@selector(togglePanel:),@selector(zn53_togglePanel:));
    ZNSwapV053(cls,@selector(renderPage),@selector(zn53_renderPage));
    ZNSwapV053(cls,@selector(renderFullPage),@selector(zn53_renderFullPage));
    ZNSwapV053(cls,@selector(fullSizeForWindow:),@selector(zn53_fullSizeForWindow:));
    ZNSwapV053(cls,@selector(themeTapped:),@selector(zn53_themeTapped:));
    ZNSwapV053(cls,@selector(zn40_button:selector:frame:),@selector(zn53_button:selector:frame:));
    ZNSwapV053(cls,@selector(zn40_addInfoCard:lines:y:width:),@selector(zn53_addInfoCard:lines:y:width:));
    ZNSwapV053(cls,@selector(zn40_selfTest:),@selector(zn53_selfTest:));
    ZNSwapV053(cls,@selector(zn44_importJSON:),@selector(zn48_importJSON:));
}

__attribute__((constructor(119))) static void ZNRuntimeMenuBootstrapV053(void) {
    @autoreleasepool {
        [ZNPatchManager sharedManager];
        [[ZNDeveloperGate sharedGate] refresh];
        [[ZNIL2CPPResolver sharedResolver] refresh];
        ZNInstallV053CurrentUI();
        [[ZNRuntimeLogger sharedLogger] log:@"[bootstrap][main] v0.5.3 direct current UI layer installed"];
        ZonoePatchStart();
    }
}
