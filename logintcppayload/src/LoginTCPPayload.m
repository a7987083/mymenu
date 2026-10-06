#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include "../vendor/fishhook.h"

#define TARGET_IP "118.145.146.208"
#define MAX_TRACKED_FD 2048
#define MAX_EVENTS_PER_DIR 96
#define PREVIEW_BYTES 512

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
static unsigned long long gTxEvents = 0;
static unsigned long long gRxEvents = 0;
static double gStartTime = 0.0;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static __thread int gInsideHook = 0;

typedef ssize_t (*SendFn)(int, const void *, size_t, int);
typedef ssize_t (*RecvFn)(int, void *, size_t, int);
typedef ssize_t (*SendToFn)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
typedef ssize_t (*RecvFromFn)(int, void *, size_t, int, struct sockaddr *, socklen_t *);

static SendFn gOrigSend;
static RecvFn gOrigRecv;
static SendToFn gOrigSendTo;
static RecvFromFn gOrigRecvFrom;

typedef struct {
    int port;
    unsigned txEvents;
    unsigned rxEvents;
    unsigned txLimitLogged;
    unsigned rxLimitLogged;
} FDState;

static FDState gFDState[MAX_TRACKED_FD];

static double NowSeconds(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1000000.0;
}

static NSString *RelTime(void) {
    double now = NowSeconds();
    if (gStartTime <= 0.0) gStartTime = now;
    return [NSString stringWithFormat:@"+%.3fs", now - gStartTime];
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
    gStatusLabel.text = [NSString stringWithFormat:@"TCP payload: %@   TX=%llu RX=%llu\nTarget: %s :10003 / :7000-7999",
                         gHooksInstalled ? @"ACTIVE" : @"WAITING",
                         gTxEvents, gRxEvents, TARGET_IP];
    NSString *text = [gEvents componentsJoinedByString:@"\n"];
    gTextView.text = text;
    if (text.length) [gTextView scrollRangeToVisible:NSMakeRange(text.length, 0)];
}

static void PushEvent(NSString *summary, NSString *detail) {
    if (!summary.length) return;
    unsigned long long seq = __sync_add_and_fetch(&gSeq, 1);
    NSString *line = [NSString stringWithFormat:@"[%@] #%llu %@", RelTime(), seq, summary];
    AppendFileLine(line);
    if (detail.length) AppendFileLine([NSString stringWithFormat:@"    %@", detail]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gEvents) gEvents = [[NSMutableArray alloc] init];
        [gEvents addObject:line];
        if (gEvents.count > 24) [gEvents removeObjectAtIndex:0];
        RefreshUI();
    });
}

static BOOL IsTargetPort(uint16_t port) {
    return port == 10003 || (port >= 7000 && port <= 7999);
}

static BOOL DecodeSockaddr(const struct sockaddr *sa, socklen_t len, char *ip, size_t ipCap, uint16_t *portOut) {
    if (!sa || len < sizeof(struct sockaddr_in) || sa->sa_family != AF_INET) return NO;
    const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
    char tmp[INET_ADDRSTRLEN] = {0};
    if (!inet_ntop(AF_INET, &sin->sin_addr, tmp, sizeof(tmp))) return NO;
    if (ip && ipCap) snprintf(ip, ipCap, "%s", tmp);
    if (portOut) *portOut = ntohs(sin->sin_port);
    return YES;
}

static BOOL TargetForFD(int fd, char *ip, size_t ipCap, uint16_t *portOut) {
    struct sockaddr_storage ss;
    socklen_t sl = sizeof(ss);
    memset(&ss, 0, sizeof(ss));
    if (getpeername(fd, (struct sockaddr *)&ss, &sl) != 0) return NO;
    uint16_t port = 0;
    char addr[INET_ADDRSTRLEN] = {0};
    if (!DecodeSockaddr((struct sockaddr *)&ss, sl, addr, sizeof(addr), &port)) return NO;
    if (strcmp(addr, TARGET_IP) != 0 || !IsTargetPort(port)) return NO;
    if (ip && ipCap) snprintf(ip, ipCap, "%s", addr);
    if (portOut) *portOut = port;
    return YES;
}

static FDState *StateForFD(int fd, uint16_t port) {
    if (fd < 0 || fd >= MAX_TRACKED_FD) return NULL;
    FDState *s = &gFDState[fd];
    if (s->port != (int)port) {
        memset(s, 0, sizeof(*s));
        s->port = port;
        PushEvent([NSString stringWithFormat:@"SOCKET fd=%d target=%s:%u", fd, TARGET_IP, port],
                  @"new target fd or endpoint changed");
    }
    return s;
}

static BOOL ContainsBytes(const unsigned char *p, size_t n, const unsigned char *needle, size_t m) {
    if (!p || !needle || !m || n < m) return NO;
    for (size_t i = 0; i + m <= n; i++) {
        if (memcmp(p + i, needle, m) == 0) return YES;
    }
    return NO;
}

static NSString *PayloadDetail(const void *buf, size_t len) {
    if (!buf || !len) return @"";
    const unsigned char *p = (const unsigned char *)buf;
    size_t n = len < PREVIEW_BYTES ? len : PREVIEW_BYTES;

    NSMutableString *hex = [NSMutableString stringWithCapacity:n * 3];
    NSMutableString *ascii = [NSMutableString stringWithCapacity:n];
    for (size_t i = 0; i < n; i++) {
        [hex appendFormat:@"%02X", p[i]];
        if (i + 1 < n) [hex appendString:@" "];
        unsigned char c = p[i];
        [ascii appendFormat:@"%c", (c >= 32 && c <= 126) ? c : '.'];
    }

    NSMutableArray *hints = [NSMutableArray array];
    const char *ipText = TARGET_IP;
    if (ContainsBytes(p, len, (const unsigned char *)ipText, strlen(ipText))) [hints addObject:@"ascii-ip"];
    const unsigned char ipRaw[] = {0x76, 0x91, 0x92, 0xD0};
    if (ContainsBytes(p, len, ipRaw, sizeof(ipRaw))) [hints addObject:@"raw-ip-76-91-92-D0"];
    const char *p10003 = "10003";
    if (ContainsBytes(p, len, (const unsigned char *)p10003, strlen(p10003))) [hints addObject:@"ascii-10003"];
    const unsigned char be10003[] = {0x27, 0x13};
    const unsigned char le10003[] = {0x13, 0x27};
    if (ContainsBytes(p, len, be10003, 2)) [hints addObject:@"be-10003"];
    if (ContainsBytes(p, len, le10003, 2)) [hints addObject:@"le-10003"];

    for (uint16_t port = 7000; port <= 7999; port++) {
        unsigned char be[2] = {(unsigned char)(port >> 8), (unsigned char)(port & 0xFF)};
        unsigned char le[2] = {be[1], be[0]};
        if (ContainsBytes(p, len, be, 2)) {
            [hints addObject:[NSString stringWithFormat:@"be-port-%u", port]];
            break;
        }
        if (ContainsBytes(p, len, le, 2)) {
            [hints addObject:[NSString stringWithFormat:@"le-port-%u", port]];
            break;
        }
    }

    NSString *hintText = hints.count ? [hints componentsJoinedByString:@","] : @"none";
    return [NSString stringWithFormat:@"len=%lu preview=%lu hints=%@\n    ASCII: %@\n    HEX: %@%@",
            (unsigned long)len, (unsigned long)n, hintText, ascii, hex,
            len > n ? [NSString stringWithFormat:@" ... <truncated %lu/%lu>", (unsigned long)n, (unsigned long)len] : @""];
}

static void LogPayload(BOOL tx, int fd, uint16_t port, const void *buf, size_t len, NSString *api) {
    FDState *s = StateForFD(fd, port);
    if (!s || !len) return;

    unsigned *counter = tx ? &s->txEvents : &s->rxEvents;
    unsigned *limitLogged = tx ? &s->txLimitLogged : &s->rxLimitLogged;
    if (*counter >= MAX_EVENTS_PER_DIR) {
        if (!*limitLogged) {
            *limitLogged = 1;
            PushEvent([NSString stringWithFormat:@"CAPTURE-LIMIT %@ fd=%d %s:%u", tx ? @"TX" : @"RX", fd, TARGET_IP, port],
                      [NSString stringWithFormat:@"payload preview stopped after %d events in this direction", MAX_EVENTS_PER_DIR]);
        }
        return;
    }
    (*counter)++;
    if (tx) __sync_add_and_fetch(&gTxEvents, 1); else __sync_add_and_fetch(&gRxEvents, 1);
    PushEvent([NSString stringWithFormat:@"%@ fd=%d %s:%u bytes=%lu [%@]",
               tx ? @"TX" : @"RX", fd, TARGET_IP, port, (unsigned long)len, api ?: @"?"],
              PayloadDetail(buf, len));
}

static ssize_t HookSend(int fd, const void *buf, size_t len, int flags) {
    if (!gOrigSend) { errno = ENOSYS; return -1; }
    if (gInsideHook) return gOrigSend(fd, buf, len, flags);
    gInsideHook++;
    ssize_t r = gOrigSend(fd, buf, len, flags);
    int saved = errno;
    if (r > 0) {
        char ip[INET_ADDRSTRLEN] = {0}; uint16_t port = 0;
        if (TargetForFD(fd, ip, sizeof(ip), &port)) LogPayload(YES, fd, port, buf, (size_t)r, @"send");
    }
    gInsideHook--;
    errno = saved;
    return r;
}

static ssize_t HookRecv(int fd, void *buf, size_t len, int flags) {
    if (!gOrigRecv) { errno = ENOSYS; return -1; }
    if (gInsideHook) return gOrigRecv(fd, buf, len, flags);
    gInsideHook++;
    ssize_t r = gOrigRecv(fd, buf, len, flags);
    int saved = errno;
    if (r > 0) {
        char ip[INET_ADDRSTRLEN] = {0}; uint16_t port = 0;
        if (TargetForFD(fd, ip, sizeof(ip), &port)) LogPayload(NO, fd, port, buf, (size_t)r, @"recv");
    }
    gInsideHook--;
    errno = saved;
    return r;
}

static ssize_t HookSendTo(int fd, const void *buf, size_t len, int flags, const struct sockaddr *to, socklen_t tolen) {
    if (!gOrigSendTo) { errno = ENOSYS; return -1; }
    if (gInsideHook) return gOrigSendTo(fd, buf, len, flags, to, tolen);
    gInsideHook++;
    ssize_t r = gOrigSendTo(fd, buf, len, flags, to, tolen);
    int saved = errno;
    if (r > 0) {
        char ip[INET_ADDRSTRLEN] = {0}; uint16_t port = 0; BOOL target = NO;
        if (DecodeSockaddr(to, tolen, ip, sizeof(ip), &port)) target = strcmp(ip, TARGET_IP) == 0 && IsTargetPort(port);
        if (!target) target = TargetForFD(fd, ip, sizeof(ip), &port);
        if (target) LogPayload(YES, fd, port, buf, (size_t)r, @"sendto");
    }
    gInsideHook--;
    errno = saved;
    return r;
}

static ssize_t HookRecvFrom(int fd, void *buf, size_t len, int flags, struct sockaddr *from, socklen_t *fromlen) {
    if (!gOrigRecvFrom) { errno = ENOSYS; return -1; }
    if (gInsideHook) return gOrigRecvFrom(fd, buf, len, flags, from, fromlen);
    gInsideHook++;
    ssize_t r = gOrigRecvFrom(fd, buf, len, flags, from, fromlen);
    int saved = errno;
    if (r > 0) {
        char ip[INET_ADDRSTRLEN] = {0}; uint16_t port = 0; BOOL target = NO;
        if (from && fromlen && DecodeSockaddr(from, *fromlen, ip, sizeof(ip), &port)) target = strcmp(ip, TARGET_IP) == 0 && IsTargetPort(port);
        if (!target) target = TargetForFD(fd, ip, sizeof(ip), &port);
        if (target) LogPayload(NO, fd, port, buf, (size_t)r, @"recvfrom");
    }
    gInsideHook--;
    errno = saved;
    return r;
}

static void InstallTCPHooks(void) {
    if (gHooksInstalled) return;
    gOrigSend = (SendFn)dlsym(RTLD_DEFAULT, "send");
    gOrigRecv = (RecvFn)dlsym(RTLD_DEFAULT, "recv");
    gOrigSendTo = (SendToFn)dlsym(RTLD_DEFAULT, "sendto");
    gOrigRecvFrom = (RecvFromFn)dlsym(RTLD_DEFAULT, "recvfrom");

    struct rebinding binds[] = {
        {"send", (void *)HookSend, (void **)&gOrigSend},
        {"recv", (void *)HookRecv, (void **)&gOrigRecv},
        {"sendto", (void *)HookSendTo, (void **)&gOrigSendTo},
        {"recvfrom", (void *)HookRecvFrom, (void **)&gOrigRecvFrom},
    };
    int rc = rebind_symbols(binds, sizeof(binds) / sizeof(binds[0]));
    gHooksInstalled = (rc == 0 && gOrigSend && gOrigRecv);
    gStartTime = NowSeconds();
    PushEvent([NSString stringWithFormat:@"HOOKS rc=%d installed=%@ delayed-after-UI", rc, gHooksInstalled ? @"YES" : @"NO"],
              @"fishhook send/recv/sendto/recvfrom; read-only; target-filtered; no connect/getaddrinfo hook");
}

@interface LoginTCPPayloadTarget : NSObject
+ (instancetype)shared;
- (void)tick:(NSTimer *)timer;
- (void)tap:(id)sender;
- (void)panButton:(UIPanGestureRecognizer *)g;
- (void)panPanel:(UIPanGestureRecognizer *)g;
@end

@implementation LoginTCPPayloadTarget
+ (instancetype)shared {
    static LoginTCPPayloadTarget *s;
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
    gFloatButton.frame = CGRectMake(18, 165, 62, 52);
    gFloatButton.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    gFloatButton.layer.cornerRadius = 26;
    [gFloatButton setTitle:@"TCP7" forState:UIControlStateNormal];
    gFloatButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [gFloatButton addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *bp = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panButton:)] autorelease];
    [gFloatButton addGestureRecognizer:bp];
    [w addSubview:gFloatButton];

    gPanel = [[[UIView alloc] initWithFrame:CGRectMake(44, 76, 370, 390)] autorelease];
    gPanel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.97];
    gPanel.layer.cornerRadius = 14;
    UIPanGestureRecognizer *pp = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panPanel:)] autorelease];
    pp.cancelsTouchesInView = NO;
    [gPanel addGestureRecognizer:pp];

    UILabel *title = [[[UILabel alloc] initWithFrame:CGRectMake(12, 8, 346, 46)] autorelease];
    title.textColor = [UIColor whiteColor];
    title.numberOfLines = 2;
    title.font = [UIFont boldSystemFontOfSize:16];
    title.text = @"Login TCP Payload Observer v7\nUI-ready delayed fishhook / target-only";
    [gPanel addSubview:title];

    gStatusLabel = [[[UILabel alloc] initWithFrame:CGRectMake(12, 56, 346, 44)] autorelease];
    gStatusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
    gStatusLabel.numberOfLines = 2;
    gStatusLabel.font = [UIFont systemFontOfSize:11];
    [gPanel addSubview:gStatusLabel];

    gTextView = [[[UITextView alloc] initWithFrame:CGRectMake(10, 104, 350, 276)] autorelease];
    gTextView.backgroundColor = [UIColor colorWithWhite:0.015 alpha:1.0];
    gTextView.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    if (@available(iOS 13.0, *)) gTextView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    else gTextView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    gTextView.editable = NO;
    gTextView.selectable = YES;
    [gPanel addSubview:gTextView];

    gPanel.hidden = YES;
    [w addSubview:gPanel];
    gUIReady = YES;
    gHookDelayTicks = 2;
    PushEvent(@"UI-READY; TCP hooks will install after delay", @"start login/server-selection only after TCP7 button appears for best coverage");
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
        else InstallTCPHooks();
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
    c.y = MAX(26, MIN(b.size.height - 26, c.y));
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

__attribute__((constructor)) static void LoginTCPPayloadInit(void) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        if (home.length) gLogPath = [[home stringByAppendingPathComponent:@"Documents/LoginTCPPayload_v7.log"] retain];
        AppendFileLine(@"\n[LoginTCPPayload v7] loaded; waiting for UI before fishhook");
        dispatch_async(dispatch_get_main_queue(), ^{
            LoginTCPPayloadTarget *t = [LoginTCPPayloadTarget shared];
            [NSTimer scheduledTimerWithTimeInterval:0.5 target:t selector:@selector(tick:) userInfo:nil repeats:YES];
        });
    }
}
