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
#define REDIRECT_IP "43.242.203.214"

static UIWindow *gWindow;
static UIButton *gFloatButton;
static UIView *gPanel;
static UILabel *gStatusLabel;
static UITextView *gTextView;
static NSMutableArray *gEvents;
static NSString *gLogPath;
static BOOL gUIReady = NO;
static BOOL gHooksInstalled = NO;
static NSInteger gHookDelayTicks = 0;
static unsigned long long gSeq = 0;
static unsigned long long gRedirectCount = 0;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static __thread int gInsideHook = 0;

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

static void RefreshUI(void) {
    if (!gStatusLabel || !gTextView) return;
    gStatusLabel.text = [NSString stringWithFormat:@"Redirect: %@  count=%llu\n%s -> %s   ports 10003 / 7000-7999",
                         gHooksInstalled ? @"ACTIVE" : @"WAITING",
                         gRedirectCount, ORIGINAL_IP, REDIRECT_IP];
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
        if (gEvents.count > 28) [gEvents removeObjectAtIndex:0];
        RefreshUI();
    });
}

static BOOL IsTargetPort(uint16_t port) {
    return port == 10003 || (port >= 7000 && port <= 7999);
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

static int HookConnect(int fd, const struct sockaddr *addr, socklen_t len) {
    if (!gOrigConnect) { errno = ENOSYS; return -1; }
    if (gInsideHook) return gOrigConnect(fd, addr, len);

    uint16_t port = 0;
    if (!ShouldRedirect(addr, len, &port)) return gOrigConnect(fd, addr, len);

    struct sockaddr_in redirected = *(const struct sockaddr_in *)addr;
    if (inet_pton(AF_INET, REDIRECT_IP, &redirected.sin_addr) != 1) {
        return gOrigConnect(fd, addr, len);
    }

    gInsideHook++;
    @autoreleasepool {
        __sync_add_and_fetch(&gRedirectCount, 1);
        PushEvent([NSString stringWithFormat:@"REDIRECT fd=%d %s:%u -> %s:%u",
                   fd, ORIGINAL_IP, port, REDIRECT_IP, port],
                  @"connect target rewritten; port preserved");
    }

    int rc = gOrigConnect(fd, (const struct sockaddr *)&redirected, sizeof(redirected));
    int savedErrno = errno;

    @autoreleasepool {
        if (rc == 0) {
            PushEvent([NSString stringWithFormat:@"CONNECT-RESULT fd=%d %s:%u rc=0", fd, REDIRECT_IP, port], @"connected");
        } else {
            PushEvent([NSString stringWithFormat:@"CONNECT-RESULT fd=%d %s:%u rc=%d errno=%d", fd, REDIRECT_IP, port, rc, savedErrno],
                      [NSString stringWithUTF8String:strerror(savedErrno)] ?: @"unknown errno");
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
              [NSString stringWithFormat:@"Only connect() exact-IP redirect: %s -> %s; ports 10003/7000-7999", ORIGINAL_IP, REDIRECT_IP]);
}

@interface LoginIPRedirectTarget : NSObject
+ (instancetype)shared;
- (void)tick:(NSTimer *)timer;
- (void)tap:(id)sender;
- (void)panButton:(UIPanGestureRecognizer *)g;
- (void)panPanel:(UIPanGestureRecognizer *)g;
@end

@implementation LoginIPRedirectTarget
+ (instancetype)shared {
    static LoginIPRedirectTarget *s;
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
    [gFloatButton setTitle:@"IP8" forState:UIControlStateNormal];
    gFloatButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [gFloatButton addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *bp = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panButton:)] autorelease];
    [gFloatButton addGestureRecognizer:bp];
    [w addSubview:gFloatButton];

    gPanel = [[[UIView alloc] initWithFrame:CGRectMake(42, 78, 375, 350)] autorelease];
    gPanel.backgroundColor = [UIColor colorWithWhite:0.035 alpha:0.97];
    gPanel.layer.cornerRadius = 14;
    UIPanGestureRecognizer *pp = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panPanel:)] autorelease];
    pp.cancelsTouchesInView = NO;
    [gPanel addGestureRecognizer:pp];

    UILabel *title = [[[UILabel alloc] initWithFrame:CGRectMake(12, 8, 351, 46)] autorelease];
    title.textColor = [UIColor whiteColor];
    title.numberOfLines = 2;
    title.font = [UIFont boldSystemFontOfSize:16];
    title.text = @"Login IP Redirect v8\nDelayed connect() redirect test";
    [gPanel addSubview:title];

    gStatusLabel = [[[UILabel alloc] initWithFrame:CGRectMake(12, 56, 351, 48)] autorelease];
    gStatusLabel.textColor = [UIColor colorWithWhite:0.86 alpha:1];
    gStatusLabel.numberOfLines = 2;
    gStatusLabel.font = [UIFont systemFontOfSize:11];
    [gPanel addSubview:gStatusLabel];

    gTextView = [[[UITextView alloc] initWithFrame:CGRectMake(10, 108, 355, 232)] autorelease];
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
    PushEvent(@"UI-READY; redirect hook will install after delay", @"");
    RefreshUI();
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
    CGPoint tr = [g translationInView:gWindow];
    CGPoint c = gPanel.center;
    c.x += tr.x; c.y += tr.y;
    gPanel.center = c;
    [g setTranslation:CGPointZero inView:gWindow];
}
@end

__attribute__((constructor)) static void LoginIPRedirectInit(void) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        if (home.length) gLogPath = [[home stringByAppendingPathComponent:@"Documents/LoginIPRedirect_v8.log"] retain];
        AppendFileLine(@"\n[LoginIPRedirect v8] loaded; waiting for UI before connect hook");
        AppendFileLine([NSString stringWithFormat:@"[RULE] %s -> %s ports=10003,7000-7999", ORIGINAL_IP, REDIRECT_IP]);
        dispatch_async(dispatch_get_main_queue(), ^{
            LoginIPRedirectTarget *t = [LoginIPRedirectTarget shared];
            [NSTimer scheduledTimerWithTimeInterval:0.5 target:t selector:@selector(tick:) userInfo:nil repeats:YES];
        });
    }
}

// Reuse the fishhook implementation already carried by the v7 branch.
#include "../../logintcppayload/vendor/fishhook.c"
