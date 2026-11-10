#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <cmath>
#import "ZNCustomerAdapter.h"

@interface ZNCustomerWindow : UIWindow
@end
@implementation ZNCustomerWindow
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if(![super pointInside:point withEvent:event]) return NO;
    return [[UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:14] containsPoint:point];
}
@end

@interface ZNCustomerController : UIViewController
@property(nonatomic,strong) UIStackView *rows;
@property(nonatomic,copy) void (^onClose)(void);
@property(nonatomic,copy) void (^onMove)(void);
@end
@implementation ZNCustomerController
- (void)loadView {
    UIView *view=[UIView new];
    view.backgroundColor=[UIColor colorWithRed:.035 green:.045 blue:.12 alpha:.96];
    view.layer.cornerRadius=14;
    view.layer.masksToBounds=YES;
    self.view=view;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    CAGradientLayer *stroke=[CAGradientLayer layer];
    stroke.colors=@[(id)[UIColor colorWithRed:.92 green:.20 blue:1 alpha:1].CGColor,
                    (id)[UIColor colorWithRed:.20 green:.78 blue:1 alpha:1].CGColor,
                    (id)[UIColor colorWithRed:.65 green:.21 blue:1 alpha:1].CGColor];
    stroke.startPoint=CGPointMake(0,0);
    stroke.endPoint=CGPointMake(1,1);
    stroke.frame=self.view.bounds;
    CAShapeLayer *mask=[CAShapeLayer layer];
    mask.fillColor=UIColor.clearColor.CGColor;
    mask.strokeColor=UIColor.whiteColor.CGColor;
    mask.lineWidth=2.5;
    stroke.mask=mask;
    [self.view.layer addSublayer:stroke];
    UIStackView *stack=[UIStackView new];
    stack.axis=UILayoutConstraintAxisVertical;
    stack.spacing=0;
    stack.layoutMargins=UIEdgeInsetsMake(8,10,8,10);
    stack.layoutMarginsRelativeArrangement=YES;
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
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
    CAGradientLayer *gradient=(CAGradientLayer *)self.view.layer.sublayers.firstObject;
    if(![gradient isKindOfClass:CAGradientLayer.class]) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gradient.frame=self.view.bounds;
    CAShapeLayer *mask=(CAShapeLayer *)gradient.mask;
    mask.frame=gradient.bounds;
    mask.path=[UIBezierPath bezierPathWithRoundedRect:CGRectInset(gradient.bounds,1.5,1.5) cornerRadius:13].CGPath;
    [CATransaction commit];
}
- (void)reload {
    for(UIView *row in [self.rows.arrangedSubviews copy]) {
        [self.rows removeArrangedSubview:row]; [row removeFromSuperview];
    }
    NSArray<ZNCustomerItem *> *items=[[ZNCustomerAdapter shared] snapshot];
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
        UILabel *label=[UILabel new];
        label.text=item.title;
        label.textColor=UIColor.whiteColor;
        label.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        [line addArrangedSubview:label];
        if(item.kind==ZNCustomerControlSwitch){
            UISwitch *toggle=[UISwitch new];toggle.on=item.enabled;
            toggle.accessibilityIdentifier=item.identifier;
            [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            [line addArrangedSubview:toggle];
        } else {
            UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:@"执行" forState:UIControlStateNormal];
            button.accessibilityIdentifier=item.identifier;
            [button addTarget:self action:@selector(executePressed:) forControlEvents:UIControlEventTouchUpInside];
            [line addArrangedSubview:button];
        }
        [self.rows addArrangedSubview:line];
    }
}
- (void)error:(NSString *)description {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"操作失败" message:description preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)switchChanged:(UISwitch *)sender {
    NSString *err=nil;
    if(![[ZNCustomerAdapter shared]setEnabled:sender.on identifier:sender.accessibilityIdentifier?:@"" error:&err]){
        sender.on=!sender.on;
        [self error:err?:@"执行失败"];
    }
}
- (void)executePressed:(UIButton *)sender {
    NSString *err=nil;
    if(![[ZNCustomerAdapter shared]execute:sender.accessibilityIdentifier?:@"" value:nil error:&err])
        [self error:err?:@"执行失败"];
}
- (void)closePressed { if(self.onClose)self.onClose(); }
- (void)drag:(UIPanGestureRecognizer *)gesture {
    if(gesture.state!=UIGestureRecognizerStateBegan && gesture.state!=UIGestureRecognizerStateChanged)return;
    UIWindow *window=self.view.window;
    if(!window)return;
    CGPoint delta=[gesture translationInView:self.view];
    [gesture setTranslation:CGPointZero inView:self.view];
    CGRect bounds=UIScreen.mainScreen.bounds;
    if(@available(iOS 13.0,*)){if(window.windowScene)bounds=window.windowScene.coordinateSpace.bounds;}
    CGRect frame=window.frame;
    frame.origin.x=fmax(CGRectGetMinX(bounds)+8,fmin(frame.origin.x+delta.x,CGRectGetMaxX(bounds)-frame.size.width-8));
    frame.origin.y=fmax(CGRectGetMinY(bounds)+8,fmin(frame.origin.y+delta.y,CGRectGetMaxY(bounds)-frame.size.height-8));
    window.frame=frame;
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
    if(self.window&&!self.window.hidden){self.window.hidden=YES;return;}
    if(!host||host.hidden||host.windowLevel!=UIWindowLevelNormal)return;
    if(self.window&&self.window.windowScene!=host.windowScene){
        self.window.hidden=YES;self.window.rootViewController=nil;self.window=nil;self.controller=nil;self.moved=NO;
    }
    self.source=host;
    if(!self.window){
        ZNCustomerWindow *w=nil;
        if(@available(iOS 13.0,*)) w=[[ZNCustomerWindow alloc]initWithWindowScene:host.windowScene];
        else w=[[ZNCustomerWindow alloc]initWithFrame:UIScreen.mainScreen.bounds];
        w.windowLevel=UIWindowLevelAlert-1;
        w.backgroundColor=UIColor.clearColor;
        self.controller=[ZNCustomerController new];
        __weak ZNCustomerHost *weakSelf=self;
        self.controller.onClose=^{weakSelf.window.hidden=YES;};
        self.controller.onMove=^{
            ZNCustomerHost *owner=weakSelf;
            if(!owner)return;
            CGRect bounds=owner.source.bounds,frame=owner.window.frame;
            if(bounds.size.width<=0||bounds.size.height<=0)return;
            owner.normalizedCenter=CGPointMake(CGRectGetMidX(frame)/bounds.size.width,CGRectGetMidY(frame)/bounds.size.height);
            owner.moved=YES;
        };
        w.rootViewController=self.controller;
        self.window=w;
    }
    CGRect bounds=host.bounds;
    CGFloat width=fmin(300,fmax(120,bounds.size.width-28));
    CGFloat height=fmin(260,fmax(60,bounds.size.height-16));
    CGFloat cx=self.moved?self.normalizedCenter.x*bounds.size.width:CGRectGetMidX(bounds);
    CGFloat cy=self.moved?self.normalizedCenter.y*bounds.size.height:CGRectGetMidY(bounds);
    self.window.frame=CGRectMake(fmax(8,fmin(cx-width/2,bounds.size.width-width-8)),
                                 fmax(8,fmin(cy-height/2,bounds.size.height-height-8)),width,height);
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
__attribute__((constructor)) static void ZNCustomerInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){(void)n;[ZNCustomerBootstrap install];}];
        [ZNCustomerBootstrap install];
    });
}
