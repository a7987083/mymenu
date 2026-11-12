#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <cmath>
#import "ZNCustomerAdapter.h"

@interface ZNCustomerWindow : UIWindow
@end
@implementation ZNCustomerWindow
// Keep the game key window intact. Other overlays may attach to keyWindow.
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if(![super pointInside:point withEvent:event]) return NO;
    UIView *root=self.rootViewController.view;
    if(!root)return NO;
    UIView *panel=[root viewWithTag:0x5A4E];
    if(panel && !panel.hidden && panel.alpha>0.01 && panel.userInteractionEnabled) {
        CGPoint local=[self convertPoint:point toView:panel];
        if([panel pointInside:local withEvent:event])return YES;
    }
    // Do not intercept transparent scene areas. Preserve any sibling overlays
    // attached by other code without incorporating them into panel dragging.
    for(UIView *sibling in self.subviews) {
        if(sibling==root || sibling.hidden || sibling.alpha<=0.01 || !sibling.userInteractionEnabled)continue;
        CGPoint local=[self convertPoint:point toView:sibling];
        if([sibling hitTest:local withEvent:event])return YES;
    }
    return NO;
}
@end

@interface ZNCustomerController : UIViewController
@property(nonatomic,strong) UIStackView *rows;
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UIView *toastView;
@property(nonatomic,strong) UILabel *toastLabel;
@property(nonatomic,strong) NSDictionary<NSString *, NSString *> *featureTitles;
@property(nonatomic,assign) NSUInteger toastSequence;
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSString *> *numberDrafts;
- (void)placePanelInBounds:(CGRect)bounds center:(CGPoint)center;
@property(nonatomic,weak) UIViewController *gameOrientationController;
@property(nonatomic,copy) void (^onClose)(void);
@property(nonatomic,copy) void (^onMove)(void);
@end
@implementation ZNCustomerController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIViewController *game=self.gameOrientationController;
    if(!game || game==self)return UIInterfaceOrientationMaskAll;
    // Follow the host game's controller, never impose an independent overlay mask.
    return game.supportedInterfaceOrientations;
}
- (BOOL)shouldAutorotate {
    UIViewController *game=self.gameOrientationController;
    return game && game!=self ? game.shouldAutorotate : YES;
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    UIViewController *game=self.gameOrientationController;
    return game && game!=self ? game.preferredInterfaceOrientationForPresentation :
        [super preferredInterfaceOrientationForPresentation];
}
- (void)loadView {
    UIView *root=[UIView new];
    root.backgroundColor=UIColor.clearColor;
    self.view=root;
    UIView *panel=[UIView new];
    panel.tag=0x5A4E;
    panel.backgroundColor=[UIColor colorWithRed:.035 green:.045 blue:.12 alpha:.96];
    panel.layer.cornerRadius=14;
    panel.layer.masksToBounds=YES;
    [root addSubview:panel];
    self.panel=panel;
}
- (void)placePanelInBounds:(CGRect)bounds center:(CGPoint)center {
    CGFloat width=fmin(300,fmax(120,bounds.size.width-28));
    CGFloat height=fmin(260,fmax(60,bounds.size.height-16));
    CGFloat x=fmax(8,fmin(center.x-width/2,CGRectGetMaxX(bounds)-width-8));
    CGFloat y=fmax(8,fmin(center.y-height/2,CGRectGetMaxY(bounds)-height-8));
    self.panel.frame=CGRectMake(x,y,width,height);
    [self.panel setNeedsLayout];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.numberDrafts=[NSMutableDictionary dictionary];
    CAGradientLayer *stroke=[CAGradientLayer layer];
    stroke.colors=@[(id)[UIColor colorWithRed:.92 green:.20 blue:1 alpha:1].CGColor,
                    (id)[UIColor colorWithRed:.20 green:.78 blue:1 alpha:1].CGColor,
                    (id)[UIColor colorWithRed:.65 green:.21 blue:1 alpha:1].CGColor];
    stroke.startPoint=CGPointMake(0,0);
    stroke.endPoint=CGPointMake(1,1);
    stroke.frame=self.panel.bounds;
    CAShapeLayer *mask=[CAShapeLayer layer];
    mask.fillColor=UIColor.clearColor.CGColor;
    mask.strokeColor=UIColor.whiteColor.CGColor;
    mask.lineWidth=2.5;
    stroke.mask=mask;
    [self.panel.layer addSublayer:stroke];
    UIStackView *stack=[UIStackView new];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.spacing=0;
    stack.layoutMargins=UIEdgeInsetsMake(8,10,8,10);
    stack.layoutMarginsRelativeArrangement=YES;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.panel addSubview:stack];
    // One reusable, non-interactive notification; never one view per feature.
    UIView *toast=[UIView new];
    toast.translatesAutoresizingMaskIntoConstraints=NO;
    toast.layer.cornerRadius=10;
    toast.clipsToBounds=YES;
    toast.userInteractionEnabled=NO;
    toast.hidden=YES;
    UILabel *toastText=[UILabel new];
    toastText.translatesAutoresizingMaskIntoConstraints=NO;
    toastText.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    toastText.textColor=UIColor.whiteColor;
    toastText.textAlignment=NSTextAlignmentCenter;
    toastText.numberOfLines=2;
    toastText.lineBreakMode=NSLineBreakByTruncatingTail;
    [toast addSubview:toastText];
    [self.panel addSubview:toast];
    [NSLayoutConstraint activateConstraints:@[
        [toast.centerXAnchor constraintEqualToAnchor:self.panel.centerXAnchor],
        [toast.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor constant:-10],
        [toast.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.panel.leadingAnchor constant:12],
        [toast.trailingAnchor constraintLessThanOrEqualToAnchor:self.panel.trailingAnchor constant:-12],
        [toastText.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:12],
        [toastText.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-12],
        [toastText.topAnchor constraintEqualToAnchor:toast.topAnchor constant:8],
        [toastText.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor constant:-8]
    ]];
    self.toastView=toast;
    self.toastLabel=toastText;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.panel.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.panel.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.panel.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.panel.bottomAnchor]
    ]];
    UIStackView *header=[UIStackView new];
    header.axis=UILayoutConstraintAxisHorizontal;
    header.alignment=UIStackViewAlignmentCenter;
    [stack addArrangedSubview:header];
    [header.heightAnchor constraintEqualToConstant:42].active=YES;
    UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(drag:)];
    pan.cancelsTouchesInView=NO;
    [header addGestureRecognizer:pan];
    UILabel *title=[UILabel new];
    title.text=@"ZonoePatch";
    title.textColor=UIColor.whiteColor;
    title.font=[UIFont boldSystemFontOfSize:17];
    [header addArrangedSubview:title];
    UIButton *close=[UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"✕" forState:UIControlStateNormal];
    close.tintColor=UIColor.whiteColor;
    [close addTarget:self action:@selector(closePressed) forControlEvents:UIControlEventTouchUpInside];
    [header addArrangedSubview:close];
    [close.widthAnchor constraintEqualToConstant:34].active=YES;
    UIView *divider=[UIView new];
    divider.backgroundColor=[UIColor colorWithRed:.62 green:.30 blue:.96 alpha:.62];
    [stack addArrangedSubview:divider];
    [divider.heightAnchor constraintEqualToConstant:1].active=YES;
    UIScrollView *scroll=[UIScrollView new];
    [stack addArrangedSubview:scroll];
    self.rows=[UIStackView new];
    self.rows.axis=UILayoutConstraintAxisVertical;
    self.rows.spacing=9;
    self.rows.translatesAutoresizingMaskIntoConstraints=NO;
    [scroll addSubview:self.rows];
    [NSLayoutConstraint activateConstraints:@[
        [self.rows.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [self.rows.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [self.rows.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:12],
        [self.rows.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-12],
        [self.rows.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]
    ]];
    [self reload];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CAGradientLayer *gradient=(CAGradientLayer *)self.panel.layer.sublayers.firstObject;
    if(![gradient isKindOfClass:CAGradientLayer.class]) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gradient.frame=self.panel.bounds;
    CAShapeLayer *mask=(CAShapeLayer *)gradient.mask;
    mask.frame=gradient.bounds;
    mask.path=[UIBezierPath bezierPathWithRoundedRect:CGRectInset(gradient.bounds,1.5,1.5) cornerRadius:13].CGPath;
    [CATransaction commit];
    // After rotation/scene resizing, keep the panel within the stationary
    // root and preserve its relative center without moving sibling windows.
    CGRect bounds=self.view.bounds,frame=self.panel.frame;
    if(bounds.size.width>0 && bounds.size.height>0 && frame.size.width>0 &&
       (CGRectGetMaxX(frame)>CGRectGetMaxX(bounds)-8 ||
        CGRectGetMaxY(frame)>CGRectGetMaxY(bounds)-8 ||
        CGRectGetMinX(frame)<8 || CGRectGetMinY(frame)<8)) {
        [self placePanelInBounds:bounds center:CGPointMake(CGRectGetMidX(frame),CGRectGetMidY(frame))];
        if(self.onMove)self.onMove();
    }
}
- (void)reload {
    for(UIView *row in [self.rows.arrangedSubviews copy]) {
        [self.rows removeArrangedSubview:row]; [row removeFromSuperview];
    }
    NSArray<ZNCustomerItem *> *items=[[ZNCustomerAdapter shared] snapshot];
    NSMutableDictionary<NSString *,NSString *> *titles=[NSMutableDictionary dictionaryWithCapacity:items.count];
    for(ZNCustomerItem *item in items) {
        if(item.identifier.length) titles[item.identifier]=item.title.length?item.title:@"未命名功能";
    }
    self.featureTitles=[titles copy];
    if(items.count==0){
        UILabel *empty=[UILabel new];
        empty.text=@"尚未接入客户端功能目录";
        empty.font=[UIFont systemFontOfSize:12];
        empty.textColor=[UIColor colorWithWhite:.75 alpha:1];
        empty.numberOfLines=2;
        empty.textAlignment=NSTextAlignmentCenter;
        [self.rows addArrangedSubview:empty];
        return;
    }
    for(ZNCustomerItem *item in items) {
        UIStackView *line=[UIStackView new];
        line.axis=UILayoutConstraintAxisHorizontal;
        line.alignment=UIStackViewAlignmentCenter;
        line.spacing=8;
        [line.heightAnchor constraintGreaterThanOrEqualToConstant:36].active=YES;
        UILabel *label=[UILabel new];
        label.text=item.title;
        label.textColor=UIColor.whiteColor;
        label.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        label.numberOfLines=1;
        label.lineBreakMode=NSLineBreakByTruncatingTail;
        [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [line addArrangedSubview:label];
        UIView *flexibleSpace=[UIView new];
        [flexibleSpace setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [line addArrangedSubview:flexibleSpace];
        if(item.kind==ZNCustomerControlSwitch){
            UISwitch *toggle=[UISwitch new];toggle.on=item.enabled;
            toggle.accessibilityIdentifier=item.identifier;
            [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            [line addArrangedSubview:toggle];
        } else if(item.kind==ZNCustomerControlSlider) {
            UISlider *slider=[UISlider new];
            slider.minimumValue=(float)item.minimum;
            slider.maximumValue=(float)(item.maximum>item.minimum?item.maximum:item.minimum+1);
            slider.value=(float)fmax(item.minimum,fmin(item.value,item.maximum));
            slider.accessibilityIdentifier=item.identifier;
            [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];
            [line addArrangedSubview:slider];
            [slider.widthAnchor constraintGreaterThanOrEqualToConstant:90].active=YES;
        } else if(item.kind==ZNCustomerControlNumber) {
            // Inline draft value: do not invoke the method until the user taps "执行".
            NSString *identifier=item.identifier?:@"";
            if(!self.numberDrafts[identifier])
                self.numberDrafts[identifier]=[NSString stringWithFormat:@"%.15g",item.value];
            UIStackView *inputColumn=[UIStackView new];
            inputColumn.axis=UILayoutConstraintAxisVertical;
            inputColumn.spacing=2;
            UITextField *field=[UITextField new];
            field.accessibilityIdentifier=identifier;
            field.text=self.numberDrafts[identifier];
            field.placeholder=@"数量";
            field.textColor=UIColor.whiteColor;
            field.tintColor=[UIColor colorWithRed:.20 green:.78 blue:1 alpha:1];
            field.font=[UIFont systemFontOfSize:13];
            field.textAlignment=NSTextAlignmentCenter;
            field.keyboardType=UIKeyboardTypeNumbersAndPunctuation;
            field.autocorrectionType=UITextAutocorrectionTypeNo;
            field.returnKeyType=UIReturnKeyDone;
            [field addTarget:self action:@selector(numberTextChanged:) forControlEvents:UIControlEventEditingChanged];
            [field addTarget:self action:@selector(numberEditingDone:) forControlEvents:UIControlEventEditingDidEndOnExit];
            [inputColumn addArrangedSubview:field];
            UIView *underline=[UIView new];
            underline.backgroundColor=[UIColor colorWithRed:.35 green:.66 blue:1 alpha:.9];
            [underline.heightAnchor constraintEqualToConstant:1].active=YES;
            [inputColumn addArrangedSubview:underline];
            [inputColumn.widthAnchor constraintEqualToConstant:70].active=YES;
            [line addArrangedSubview:inputColumn];
            UIButton *apply=[UIButton buttonWithType:UIButtonTypeSystem];
            [apply setTitle:@"执行" forState:UIControlStateNormal];
            apply.accessibilityIdentifier=identifier;
            [apply addTarget:self action:@selector(numberExecutePressed:) forControlEvents:UIControlEventTouchUpInside];
            [apply.widthAnchor constraintEqualToConstant:44].active=YES;
            [line addArrangedSubview:apply];
        } else {
            UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:@"触发" forState:UIControlStateNormal];
            button.accessibilityIdentifier=item.identifier;
            [button addTarget:self action:@selector(executePressed:) forControlEvents:UIControlEventTouchUpInside];
            [line addArrangedSubview:button];
            [button.widthAnchor constraintEqualToConstant:52].active=YES;
        }
        [self.rows addArrangedSubview:line];
    }
}
- (NSString *)featureTitle:(NSString *)identifier {
    return self.featureTitles[identifier?:@""]?:@"当前功能";
}
- (void)dismissToast {
    ++self.toastSequence; // Invalidate any outstanding delayed hide.
    self.toastView.hidden=YES;
}
- (void)showToast:(NSString *)message success:(BOOL)success {
    NSAssert(NSThread.isMainThread, @"Toast UI must be updated on main thread");
    NSUInteger token=++self.toastSequence;
    self.toastLabel.text=message;
    self.toastView.backgroundColor=success?
        [UIColor colorWithRed:.10 green:.39 blue:.28 alpha:.96]:
        [UIColor colorWithRed:.49 green:.16 blue:.20 alpha:.96];
    self.toastView.hidden=NO;
    [self.panel bringSubviewToFront:self.toastView];
    __weak typeof(self) weakSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ZNCustomerController *owner=weakSelf;
        if(owner && owner.toastSequence==token)owner.toastView.hidden=YES;
    });
}
- (void)reportResult:(BOOL)success identifier:(NSString *)identifier verb:(NSString *)verb error:(NSString *)error {
    NSString *title=[self featureTitle:identifier];
    if(success) {
        [self showToast:[NSString stringWithFormat:@"%@功能%@成功",title,verb] success:YES];
    } else {
        NSString *reason=error.length?error:@"未知错误";
        [self showToast:[NSString stringWithFormat:@"%@功能%@失败：%@",title,verb,reason] success:NO];
    }
}
- (void)switchChanged:(UISwitch *)sender {
    NSString *identifier=sender.accessibilityIdentifier?:@"";
    BOOL enabled=sender.on;
    NSString *err=nil;
    BOOL success=[[ZNCustomerAdapter shared]setEnabled:enabled identifier:identifier error:&err];
    if(!success)sender.on=!enabled;
    [self reportResult:success identifier:identifier verb:enabled?@"开启":@"关闭" error:err];
}
- (void)executePressed:(UIButton *)sender {
    NSString *identifier=sender.accessibilityIdentifier?:@"";
    NSString *err=nil;
    BOOL success=[[ZNCustomerAdapter shared]execute:identifier value:nil error:&err];
    [self reportResult:success identifier:identifier verb:@"执行" error:err];
}
- (void)sliderChanged:(UISlider *)sender {
    NSString *identifier=sender.accessibilityIdentifier?:@"";
    NSString *err=nil;
    BOOL success=[[ZNCustomerAdapter shared]execute:identifier value:@(sender.value) error:&err];
    [self reportResult:success identifier:identifier verb:@"执行" error:err];
    if(!success)[self reload];
}
- (void)numberTextChanged:(UITextField *)field {
    if(field.accessibilityIdentifier.length)
        self.numberDrafts[field.accessibilityIdentifier]=field.text?:@"";
}
- (void)numberEditingDone:(UITextField *)field {
    [field resignFirstResponder];
}
- (void)numberExecutePressed:(UIButton *)sender {
    NSString *identifier=sender.accessibilityIdentifier?:@"";
    NSString *raw=[self.numberDrafts[identifier]?:@"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSScanner *scanner=[NSScanner scannerWithString:raw];
    double number=0;
    if(!raw.length || ![scanner scanDouble:&number] || !scanner.isAtEnd || !std::isfinite(number)){
        [self reportResult:NO identifier:identifier verb:@"执行" error:@"请输入有效的有限数值"];
        return;
    }
    NSString *err=nil;
    BOOL success=[[ZNCustomerAdapter shared] execute:identifier value:@(number) error:&err];
    [self reportResult:success identifier:identifier verb:@"执行" error:err];
    if(!success)return;
    [self.view endEditing:YES];
    [self reload];
}
- (void)closePressed { [self dismissToast]; if(self.onClose)self.onClose(); }
- (void)drag:(UIPanGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateBegan && gesture.state!=UIGestureRecognizerStateChanged)return;
    // A stationary root is the coordinate space; never move the UIWindow.
    CGPoint delta=[gesture translationInView:self.view];
    [gesture setTranslation:CGPointZero inView:self.view];
    CGRect bounds=self.view.bounds;
    CGRect frame=self.panel.frame;
    frame.origin.x=fmax(CGRectGetMinX(bounds)+8,fmin(frame.origin.x+delta.x,CGRectGetMaxX(bounds)-frame.size.width-8));
    frame.origin.y=fmax(CGRectGetMinY(bounds)+8,fmin(frame.origin.y+delta.y,CGRectGetMaxY(bounds)-frame.size.height-8));
    self.panel.frame=frame;
    if(self.onMove)self.onMove();
}
@end

@interface ZNCustomerHost : NSObject
@property(nonatomic,strong) ZNCustomerWindow *window;
@property(nonatomic,strong) ZNCustomerController *controller;
@property(nonatomic,weak) UIWindow *source;
@property(nonatomic,assign) CGPoint normalizedCenter;
@property(nonatomic,assign) BOOL moved;
+ (instancetype)shared;
- (void)toggle:(UIWindow *)host;
@end
@implementation ZNCustomerHost
+ (instancetype)shared {static ZNCustomerHost *s;static dispatch_once_t once;dispatch_once(&once,^{s=[ZNCustomerHost new];});return s;}
- (void)toggle:(UIWindow *)host {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self toggle:host];});return;}
    if(self.window&&!self.window.hidden){[self.controller dismissToast];self.window.hidden=YES;return;}
    if(!host||host.hidden||host.windowLevel!=UIWindowLevelNormal)return;
    if(self.window&&self.window.windowScene!=host.windowScene){
        self.window.hidden=YES;self.window.rootViewController=nil;self.window=nil;self.controller=nil;self.moved=NO;
    }
    self.source=host;
    if(self.controller) {
        self.controller.gameOrientationController=host.rootViewController;
        if(@available(iOS 16.0,*))
            [self.controller setNeedsUpdateOfSupportedInterfaceOrientations];
    }
    if(!self.window){
        ZNCustomerWindow *w=nil;
        if(@available(iOS 13.0,*)) w=[[ZNCustomerWindow alloc]initWithWindowScene:host.windowScene];
        else w=[[ZNCustomerWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];
        w.windowLevel=UIWindowLevelAlert-1;
        w.backgroundColor=UIColor.clearColor;
        self.controller=[ZNCustomerController new];
        self.controller.gameOrientationController=host.rootViewController;
        __weak ZNCustomerHost *weakSelf=self;
        self.controller.onClose=^{weakSelf.window.hidden=YES;};
        self.controller.onMove=^{
            ZNCustomerHost *owner=weakSelf;
            if(!owner)return;
            CGRect bounds=owner.controller.view.bounds,frame=owner.controller.panel.frame;
            if(bounds.size.width<=0||bounds.size.height<=0)return;
            owner.normalizedCenter=CGPointMake(CGRectGetMidX(frame)/bounds.size.width,CGRectGetMidY(frame)/bounds.size.height);
            owner.moved=YES;
        };
        w.rootViewController=self.controller;
        self.window=w;
    }
    CGRect bounds=host.bounds;
    if(@available(iOS 13.0,*)){if(host.windowScene)bounds=host.windowScene.coordinateSpace.bounds;}
    // This frame is set only on opening/scene change, not during dragging.
    self.window.frame=bounds;
    [self.controller loadViewIfNeeded];
    CGFloat cx=self.moved?self.normalizedCenter.x*bounds.size.width:CGRectGetMidX(bounds);
    CGFloat cy=self.moved?self.normalizedCenter.y*bounds.size.height:CGRectGetMidY(bounds);
    [self.controller placePanelInBounds:CGRectMake(0,0,bounds.size.width,bounds.size.height)
                                center:CGPointMake(cx,cy)];
    [self.controller reload];
    self.window.hidden=NO;
}
@end

// Customer activation is deliberately separate from the developer's swizzled UI.
// The two-finger triple-tap recognizer is installed once on the host key window.
@interface ZNCustomerBootstrap : NSObject
+ (void)install;
@end
@implementation ZNCustomerBootstrap
+ (void)install {
    UIWindow *window=nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if(![scene isKindOfClass:UIWindowScene.class] || scene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow *candidate in ((UIWindowScene *)scene).windows){
            if(candidate.isKeyWindow && candidate.windowLevel==UIWindowLevelNormal){window=candidate;break;}
        }
        if(window)break;
    }
    if(!window||window.windowLevel!=UIWindowLevelNormal)return;
    for(UIGestureRecognizer *g in window.gestureRecognizers)
        if([g.name isEqualToString:@"mymenu.customer.open"])return;
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc]initWithTarget:self action:@selector(open:)];
    tap.numberOfTouchesRequired=2;
    tap.numberOfTapsRequired=3;
    tap.cancelsTouchesInView=NO;
    tap.name=@"mymenu.customer.open";
    [window addGestureRecognizer:tap];
}
+ (void)open:(UITapGestureRecognizer *)tap {
    if(tap.state==UIGestureRecognizerStateRecognized)[[ZNCustomerHost shared]toggle:(UIWindow *)tap.view];
}
@end
extern "C" void ZNCustomerInstallReceiverLifecycle(void);
extern "C" void ZNInstallM47MultiArgInvokeDeferred(void);
__attribute__((constructor)) static void ZNCustomerInit(void) {
    // Customer-only runtime receiver binding; developer bootstrap is not linked.
    ZNCustomerInstallReceiverLifecycle();
    // Client Runtime Method actions use the same /2-/8 engine as developer authoring.
    ZNInstallM47MultiArgInvokeDeferred();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){(void)n;[ZNCustomerBootstrap install];}];
        [ZNCustomerBootstrap install];
    });
}
