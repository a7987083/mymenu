#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

#include "../../logintcppayload/vendor/fishhook.h"

#define ORIGINAL_IP "118.145.146.208"
#define PREF_KEY @"LoginIPRedirectV9.TargetIPv4"

static UIWindow *gWindow;
static UIButton *gFloatButton;
static UIView *gPanel;
static UILabel *gStatusLabel;
static UITextField *gIPField;
static UITextView *gTextView;
static NSMutableArray *gEvents;
static NSString *gLogPath;
static BOOL gUIReady = NO;
static BOOL gHooksInstalled = NO;
static NSInteger gHookDelayTicks = 0;
static unsigned long long gSeq = 0;
static unsigned long long gRedirectCount = 0;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gIPLock = PTHREAD_MUTEX_INITIALIZER;
static __thread int gInsideHook = 0;
static char gRedirectIP[INET_ADDRSTRLEN] = {0};

typedef int (*ConnectFn)(int, const struct sockaddr *, socklen_t);
static ConnectFn gOrigConnect;

static NSString *NowText(void) {
    NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    return [fmt stringFromDate:[NSDate date]];
}

static void AppendFileLine(NSString *line) {
    if (!gLogPath || !line.length) return;
    pthread_mutex_lock(&gLogLock);
    FILE *f = fopen(gLogPath.fileSystemRepresentation, "a");
    if (f) {
        NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        fwrite(d.bytes, 1, d.length, f);
        fflush(f);
        fclose(f);
    }
    pthread_mutex_unlock(&gLogLock);
}

static NSString *CurrentTargetString(void) {
    char ip[INET_ADDRSTRLEN] = {0};
    pthread_mutex_lock(&gIPLock);
    snprintf(ip, sizeof(ip), "%s", gRedirectIP);
    pthread_mutex_unlock(&gIPLock);
    return ip[0] ? [NSString stringWithUTF8String:ip] : @"未设置";
}

static BOOL SetTargetIPv4String(NSString *value, BOOL persist) {
    NSString *trim = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trim.length) return NO;
    struct in_addr addr;
    if (inet_pton(AF_INET, trim.UTF8String, &addr) != 1) return NO;

    pthread_mutex_lock(&gIPLock);
    snprintf(gRedirectIP, sizeof(gRedirectIP), "%s", trim.UTF8String);
    pthread_mutex_unlock(&gIPLock);

    if (persist) {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:trim forKey:PREF_KEY];
        [ud synchronize];
    }
    return YES;
}

static void ClearTargetIPv4(BOOL persist) {
    pthread_mutex_lock(&gIPLock);
    memset(gRedirectIP, 0, sizeof(gRedirectIP));
    pthread_mutex_unlock(&gIPLock);
    if (persist) {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud removeObjectForKey:PREF_KEY];
        [ud synchronize];
    }
}

static void RefreshUI(void) {
    if (!gStatusLabel || !gTextView) return;
    gStatusLabel.text = [NSString stringWithFormat:@"Hook: %@   重定向=%llu\n目标IP: %@   端口: 10003 / 7000-7010",
                         gHooksInstalled ? @"ACTIVE" : @"WAITING",
                         gRedirectCount,
                         CurrentTargetString()];
    NSString *text = [gEvents componentsJoinedByString:@"\n"];
    gTextView.text = text;
    if (text.length) [gTextView scrollRangeToVisible:NSMakeRange(text.length, 0)];
}

static void PushEvent(NSString *summary, NSString *detail) {
    if (!summary.length) return;
    unsigned long long seq = __sync_add_and_fetch(&gSeq, 1);
    NSString *line = [NSString stringWithFormat:@"[%@] #%llu %@", NowText(), seq, summary];
    AppendFileLine(line);
    if (detail.length) AppendFileLine([NSString stringWithFormat:@"    %@", detail]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gEvents) gEvents = [[NSMutableArray alloc] init];
        [gEvents addObject:line];
        if (gEvents.count > 30) [gEvents removeObjectAtIndex:0];
        RefreshUI();
    });
}

static BOOL IsTargetPort(uint16_t port) {
    return port == 10003 || (port >= 7000 && port <= 7010);
}

static BOOL ShouldRedirect(const struct sockaddr *addr, socklen_t len, uint16_t *portOut) {
    if (!addr || len < sizeof(struct sockaddr_in) || addr->sa_family != AF_INET) return NO;
    const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
    uint16_t port = ntohs(sin->sin_port);
    if (!IsTargetPort(port)) return NO;
    char ip[INET_ADDRSTRLEN] = {0};
    if (!inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip))) return NO;
    if (strcmp(ip, ORIGINAL_IP) != 0) return NO;
    if (portOut) *portOut = port;
    return YES;
}

static BOOL CopyCurrentTarget(char out[INET_ADDRSTRLEN]) {
    pthread_mutex_lock(&gIPLock);
    snprintf(out, INET_ADDRSTRLEN, "%s", gRedirectIP);
    pthread_mutex_unlock(&gIPLock);
    if (!out[0]) return NO;
    struct in_addr tmp;
    return inet_pton(AF_INET, out, &tmp) == 1;
}

static int HookConnect(int fd, const struct sockaddr *addr, socklen_t len) {
    if (!gOrigConnect) { errno = ENOSYS; return -1; }
    if (gInsideHook) return gOrigConnect(fd, addr, len);

    uint16_t port = 0;
    if (!ShouldRedirect(addr, len, &port)) return gOrigConnect(fd, addr, len);

    char target[INET_ADDRSTRLEN] = {0};
    if (!CopyCurrentTarget(target)) return gOrigConnect(fd, addr, len);

    struct sockaddr_in redirected = *(const struct sockaddr_in *)addr;
    if (inet_pton(AF_INET, target, &redirected.sin_addr) != 1) return gOrigConnect(fd, addr, len);

    gInsideHook++;
    @autoreleasepool {
        __sync_add_and_fetch(&gRedirectCount, 1);
        PushEvent([NSString stringWithFormat:@"REDIRECT fd=%d %s:%u -> %s:%u", fd, ORIGINAL_IP, port, target, port],
                  @"目标IP来自菜单；端口保持不变");
    }

    int rc = gOrigConnect(fd, (const struct sockaddr *)&redirected, sizeof(redirected));
    int savedErrno = errno;

    @autoreleasepool {
        if (rc == 0) {
            PushEvent([NSString stringWithFormat:@"CONNECT-RESULT fd=%d %s:%u rc=0", fd, target, port], @"connected");
        } else {
            NSString *errText = [NSString stringWithUTF8String:strerror(savedErrno)] ?: @"unknown errno";
            PushEvent([NSString stringWithFormat:@"CONNECT-RESULT fd=%d %s:%u rc=%d errno=%d", fd, target, port, rc, savedErrno], errText);
        }
    }
    gInsideHook--;
    errno = savedErrno;
    return rc;
}

static void InstallRedirectHook(void) {
    if (gHooksInstalled) return;
    gOrigConnect = (ConnectFn)dlsym(RTLD_DEFAULT, "connect");
    if (!gOrigConnect) {
        PushEvent(@"HOOK-ERROR connect symbol not found", @"");
        return;
    }
    struct rebinding bind = {"connect", (void *)HookConnect, (void **)&gOrigConnect};
    int rc = rebind_symbols(&bind, 1);
    gHooksInstalled = (rc == 0 && gOrigConnect != NULL);
    PushEvent([NSString stringWithFormat:@"HOOKS rc=%d installed=%@ delayed-after-UI", rc, gHooksInstalled ? @"YES" : @"NO"],
              @"connect() exact-IP redirect; target IPv4 is runtime-configurable");
}

@interface LoginIPRedirectV9Target : NSObject
+ (instancetype)shared;
- (void)tick:(NSTimer *)timer;
- (void)tap:(id)sender;
- (void)applyIP:(id)sender;
- (void)clearIP:(id)sender;
- (void)editingDone:(id)sender;
- (void)panButton:(UIPanGestureRecognizer *)g;
- (void)panPanel:(UIPanGestureRecognizer *)g;
@end

@implementation LoginIPRedirectV9Target
+ (instancetype)shared {
    static LoginIPRedirectV9Target *s;
    if (!s) s = [[self alloc] init];
    return s;
}

- (UIWindow *)currentWindow {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *w = app.keyWindow;
    if (w) return w;
    return app.windows.lastObject;
}

- (void)makeUI:(UIWindow *)w {
    if (gUIReady || !w) return;
    gWindow = w;
    gEvents = [[NSMutableArray alloc] init];

    gFloatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    gFloatButton.frame = CGRectMake(18, 165, 62, 54);
    gFloatButton.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
    gFloatButton.layer.cornerRadius = 27;
    [gFloatButton setTitle:@"IP9" forState:UIControlStateNormal];
    gFloatButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [gFloatButton addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *bp = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panButton:)] autorelease];
    [gFloatButton addGestureRecognizer:bp];
    [w addSubview:gFloatButton];

    gPanel = [[[UIView alloc] initWithFrame:CGRectMake(30, 70, 390, 430)] autorelease];
    gPanel.backgroundColor = [UIColor colorWithWhite:0.035 alpha:0.97];
    gPanel.layer.cornerRadius = 14;
    UIPanGestureRecognizer *pp = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panPanel:)] autorelease];
    pp.cancelsTouchesInView = NO;
    [gPanel addGestureRecognizer:pp];

    UILabel *title = [[[UILabel alloc] initWithFrame:CGRectMake(12, 8, 366, 42)] autorelease];
    title.textColor = [UIColor whiteColor];
    title.numberOfLines = 2;
    title.font = [UIFont boldSystemFontOfSize:16];
    title.text = @"Login IP Redirect v9\n运行时输入目标 IPv4";
    [gPanel addSubview:title];

    gStatusLabel = [[[UILabel alloc] initWithFrame:CGRectMake(12, 52, 366, 48)] autorelease];
    gStatusLabel.textColor = [UIColor colorWithWhite:0.86 alpha:1];
    gStatusLabel.numberOfLines = 2;
    gStatusLabel.font = [UIFont systemFontOfSize:11];
    [gPanel addSubview:gStatusLabel];

    gIPField = [[[UITextField alloc] initWithFrame:CGRectMake(12, 106, 246, 40)] autorelease];
    gIPField.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    gIPField.textColor = [UIColor whiteColor];
    gIPField.layer.cornerRadius = 8;
    gIPField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    gIPField.returnKeyType = UIReturnKeyDone;
    gIPField.autocorrectionType = UITextAutocorrectionTypeNo;
    gIPField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    gIPField.placeholder = @"输入目标IP，例如 192.168.1.100";
    gIPField.clearButtonMode = UITextFieldViewModeWhileEditing;
    UIView *pad = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 1)] autorelease];
    gIPField.leftView = pad;
    gIPField.leftViewMode = UITextFieldViewModeAlways;
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:PREF_KEY];
    if (saved.length) gIPField.text = saved;
    [gIPField addTarget:self action:@selector(editingDone:) forControlEvents:UIControlEventEditingDidEndOnExit];
    [gPanel addSubview:gIPField];

    UIButton *apply = [UIButton buttonWithType:UIButtonTypeSystem];
    apply.frame = CGRectMake(266, 106, 54, 40);
    [apply setTitle:@"应用" forState:UIControlStateNormal];
    apply.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    apply.layer.cornerRadius = 8;
    [apply addTarget:self action:@selector(applyIP:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:apply];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(326, 106, 52, 40);
    [clear setTitle:@"清除" forState:UIControlStateNormal];
    clear.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    clear.layer.cornerRadius = 8;
    [clear addTarget:self action:@selector(clearIP:) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:clear];

    UILabel *note = [[[UILabel alloc] initWithFrame:CGRectMake(12, 150, 366, 34)] autorelease];
    note.textColor = [UIColor colorWithWhite:0.70 alpha:1];
    note.numberOfLines = 2;
    note.font = [UIFont systemFontOfSize:10];
    note.text = @"拦截原地址 118.145.146.208；仅重定向 10003 和 7000-7010。修改IP后，新连接立即使用新值。";
    [gPanel addSubview:note];

    gTextView = [[[UITextView alloc] initWithFrame:CGRectMake(10, 190, 370, 228)] autorelease];
    gTextView.backgroundColor = [UIColor colorWithWhite:0.01 alpha:1];
    gTextView.textColor = [UIColor colorWithWhite:0.93 alpha:1];
    gTextView.font = [UIFont systemFontOfSize:10];
    gTextView.editable = NO;
    gTextView.selectable = YES;
    [gPanel addSubview:gTextView];

    gPanel.hidden = YES;
    [w addSubview:gPanel];
    gUIReady = YES;
    gHookDelayTicks = 2;
    PushEvent(@"UI-READY; redirect hook will install after delay", [NSString stringWithFormat:@"saved target=%@", CurrentTargetString()]);
    RefreshUI();
}

- (void)applyIP:(id)sender {
    (void)sender;
    [gIPField resignFirstResponder];
    if (SetTargetIPv4String(gIPField.text, YES)) {
        PushEvent([NSString stringWithFormat:@"TARGET-APPLIED %@", CurrentTargetString()], @"已保存；后续新连接立即生效");
    } else {
        PushEvent(@"TARGET-INVALID", @"请输入合法 IPv4，例如 192.168.1.100");
    }
    RefreshUI();
}

- (void)clearIP:(id)sender {
    (void)sender;
    [gIPField resignFirstResponder];
    gIPField.text = @"";
    ClearTargetIPv4(YES);
    PushEvent(@"TARGET-CLEARED", @"未设置目标IP时不会执行重定向");
    RefreshUI();
}

- (void)editingDone:(id)sender {
    (void)sender;
    [self applyIP:nil];
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    UIWindow *w = [self currentWindow];
    if (!w) return;
    if (!gUIReady) [self makeUI:w];
    if (gUIReady && gWindow != w) {
        [w addSubview:gPanel];
        [w addSubview:gFloatButton];
        gWindow = w;
    }
    if (gUIReady && !gHooksInstalled) {
        if (gHookDelayTicks > 0) gHookDelayTicks--;
        else InstallRedirectHook();
    }
    if (gUIReady) {
        [w bringSubviewToFront:gPanel];
        [w bringSubviewToFront:gFloatButton];
    }
}

- (void)tap:(id)sender {
    (void)sender;
    gPanel.hidden = !gPanel.hidden;
    if (!gPanel.hidden) {
        NSString *current = CurrentTargetString();
        if (![current isEqualToString:@"未设置"]) gIPField.text = current;
    } else {
        [gIPField resignFirstResponder];
    }
    RefreshUI();
}

- (void)panButton:(UIPanGestureRecognizer *)g {
    if (!gWindow) return;
    CGPoint tr = [g translationInView:gWindow];
    CGPoint c = gFloatButton.center;
    c.x += tr.x; c.y += tr.y;
    CGRect b = gWindow.bounds;
    c.x = MAX(31, MIN(b.size.width - 31, c.x));
    c.y = MAX(27, MIN(b.size.height - 27, c.y));
    gFloatButton.center = c;
    [g setTranslation:CGPointZero inView:gWindow];
}

- (void)panPanel:(UIPanGestureRecognizer *)g {
    if (!gWindow) return;
    if ([gIPField isFirstResponder]) return;
    CGPoint tr = [g translationInView:gWindow];
    CGPoint c = gPanel.center;
    c.x += tr.x; c.y += tr.y;
    gPanel.center = c;
    [g setTranslation:CGPointZero inView:gWindow];
}
@end

__attribute__((constructor)) static void LoginIPRedirectV9Init(void) {
    @autoreleasepool {
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:PREF_KEY];
        if (saved.length) SetTargetIPv4String(saved, NO);
        NSString *home = NSHomeDirectory();
        if (home.length) gLogPath = [[home stringByAppendingPathComponent:@"Documents/LoginIPRedirect_v9.log"] retain];
        AppendFileLine(@"\n[LoginIPRedirect v9] loaded; runtime target IPv4; waiting for UI before connect hook");
        AppendFileLine([NSString stringWithFormat:@"[RULE] original=%s ports=10003,7000-7010 savedTarget=%@", ORIGINAL_IP, CurrentTargetString()]);
        dispatch_async(dispatch_get_main_queue(), ^{
            LoginIPRedirectV9Target *t = [LoginIPRedirectV9Target shared];
            [NSTimer scheduledTimerWithTimeInterval:0.5 target:t selector:@selector(tick:) userInfo:nil repeats:YES];
        });
    }
}
