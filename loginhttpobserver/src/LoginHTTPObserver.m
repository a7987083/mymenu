#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define MAX_DELEGATE_HOOKS 32
#define MAX_CAPTURE_BYTES (256 * 1024)

typedef struct {
    Class cls;
    IMP responseIMP;
    IMP dataIMP;
    IMP completeIMP;
    BOOL responseHooked;
    BOOL dataHooked;
    BOOL completeHooked;
} DelegateHook;

static UIWindow *gWindow;
static UIButton *gFloatButton;
static UIView *gPanel;
static UITextView *gTextView;
static UILabel *gStatusLabel;
static NSMutableArray *gEvents;
static NSMutableDictionary *gTaskStates;
static NSString *gLogPath;
static BOOL gUIReady = NO;
static BOOL gHooksInstalled = NO;
static NSInteger gHookDelayTicks = 0;
static unsigned long long gSeq = 0;
static unsigned long long gDelegateResponses = 0;
static DelegateHook gDelegateHooks[MAX_DELEGATE_HOOKS];
static NSUInteger gDelegateHookCount = 0;

static IMP gDataTaskReqIMP;
static IMP gDataTaskReqCompletionIMP;
static IMP gDataTaskURLIMP;
static IMP gDataTaskURLCompletionIMP;
static IMP gUploadReqDataIMP;
static IMP gUploadReqDataCompletionIMP;
static IMP gMutableSetURLIMP;
static IMP gSyncRequestIMP;
static IMP gAsyncRequestIMP;

static NSString *NowText(void) {
    NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
    fmt.dateFormat = @"HH:mm:ss.SSS";
    return [fmt stringFromDate:[NSDate date]];
}

static NSString *DataPreview(NSData *data, NSUInteger limit) {
    if (!data || data.length == 0) return @"";
    NSUInteger n = MIN(data.length, limit);
    NSData *slice = [data subdataWithRange:NSMakeRange(0, n)];
    NSString *utf8 = [[[NSString alloc] initWithData:slice encoding:NSUTF8StringEncoding] autorelease];
    if (utf8) {
        NSString *s = [utf8 stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
        s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
        if (data.length > n) s = [s stringByAppendingFormat:@" ... <truncated %lu/%lu>", (unsigned long)n, (unsigned long)data.length];
        return s;
    }
    const unsigned char *p = slice.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:n * 2];
    for (NSUInteger i = 0; i < n; i++) [hex appendFormat:@"%02x", p[i]];
    if (data.length > n) [hex appendFormat:@"...<truncated %lu/%lu>", (unsigned long)n, (unsigned long)data.length];
    return [NSString stringWithFormat:@"<binary hex=%@>", hex];
}

static BOOL IsTargetURL(NSString *url) {
    if (!url.length) return NO;
    return [url containsString:@"118.145.146.208"] || [url containsString:@"/master/GM/"];
}

static void AppendFile(NSString *line) {
    if (!gLogPath || !line) return;
    @synchronized([NSFileHandle class]) {
        FILE *f = fopen(gLogPath.fileSystemRepresentation, "a");
        if (!f) return;
        NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        fwrite(d.bytes, 1, d.length, f);
        fflush(f);
        fclose(f);
    }
}

static void RefreshUI(void) {
    if (!gTextView || !gStatusLabel) return;
    NSString *text = [gEvents componentsJoinedByString:@"\n"];
    gTextView.text = text;
    NSRange r = NSMakeRange(text.length, 0);
    if (text.length) [gTextView scrollRangeToVisible:r];
    gStatusLabel.text = [NSString stringWithFormat:@"HTTP v6: %@  events=%llu  delegate-resp=%llu\nLog: Documents/LoginHTTPTrace_v6.log",
                         gHooksInstalled ? @"ACTIVE" : @"WAITING", gSeq, gDelegateResponses];
}

static void PushEvent(NSString *summary, NSString *detail) {
    if (!summary) return;
    unsigned long long seq = ++gSeq;
    NSString *line = [NSString stringWithFormat:@"[%@] #%llu %@", NowText(), seq, summary];
    AppendFile(line);
    if (detail.length) AppendFile([NSString stringWithFormat:@"    %@", detail]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gEvents) gEvents = [[NSMutableArray alloc] init];
        [gEvents addObject:line];
        if (gEvents.count > 30) [gEvents removeObjectAtIndex:0];
        RefreshUI();
    });
}

static NSString *RequestDetail(NSURLRequest *req) {
    if (!req) return @"request=(null)";
    NSMutableString *s = [NSMutableString string];
    NSDictionary *headers = req.allHTTPHeaderFields;
    if (headers.count) [s appendFormat:@"headers=%@", headers];
    NSData *body = req.HTTPBody;
    if (body.length) {
        if (s.length) [s appendString:@" | "];
        [s appendFormat:@"body=%@", DataPreview(body, 4096)];
    }
    return s;
}

static void LogRequest(NSURLRequest *req, NSString *source) {
    if (!req) return;
    NSString *method = req.HTTPMethod.length ? req.HTTPMethod : @"GET";
    NSString *url = req.URL.absoluteString ?: @"(null-url)";
    NSString *tag = IsTargetURL(url) ? @" TARGET" : @"";
    PushEvent([NSString stringWithFormat:@"REQ%@ %@ %@ [%@]", tag, method, url, source ?: @"?"], RequestDetail(req));
}

static void LogURL(NSURL *url, NSString *source) {
    if (!url) return;
    NSString *u = url.absoluteString ?: @"(null-url)";
    NSString *tag = IsTargetURL(u) ? @" TARGET" : @"";
    PushEvent([NSString stringWithFormat:@"URL%@ %@ [%@]", tag, u, source ?: @"?"], @"");
}

static void LogResponse(NSURLResponse *resp, NSData *data, NSError *err, NSString *source) {
    NSInteger status = 0;
    NSDictionary *headers = nil;
    if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
        status = [(NSHTTPURLResponse *)resp statusCode];
        headers = [(NSHTTPURLResponse *)resp allHeaderFields];
    }
    NSString *url = resp.URL.absoluteString ?: @"(null-url)";
    NSString *tag = IsTargetURL(url) ? @" TARGET" : @"";
    NSMutableString *detail = [NSMutableString string];
    if (headers.count) [detail appendFormat:@"headers=%@", headers];
    if (err) {
        if (detail.length) [detail appendString:@" | "];
        [detail appendFormat:@"error=%@", err];
    }
    if (data.length) {
        if (detail.length) [detail appendString:@" | "];
        [detail appendFormat:@"response=%@", DataPreview(data, 65536)];
    }
    PushEvent([NSString stringWithFormat:@"RESP%@ status=%ld %@ [%@]", tag, (long)status, url, source ?: @"?"], detail);
}

static NSString *TaskKey(NSURLSession *session, NSURLSessionTask *task) {
    if (!session || !task) return nil;
    return [NSString stringWithFormat:@"%p:%lu", session, (unsigned long)task.taskIdentifier];
}

static NSMutableDictionary *MakeTaskState(NSURLRequest *req) {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    NSString *url = req.URL.absoluteString ?: @"";
    NSString *method = req.HTTPMethod.length ? req.HTTPMethod : @"GET";
    [state setObject:url forKey:@"url"];
    [state setObject:method forKey:@"method"];
    [state setObject:[NSMutableData data] forKey:@"data"];
    [state setObject:@0 forKey:@"chunks"];
    [state setObject:@0 forKey:@"truncated"];
    return state;
}

static NSMutableDictionary *EnsureTaskState(NSURLSession *session, NSURLSessionTask *task) {
    if (!session || !task) return nil;
    NSURLRequest *req = task.currentRequest ?: task.originalRequest;
    NSString *url = req.URL.absoluteString ?: task.response.URL.absoluteString ?: @"";
    if (!IsTargetURL(url)) return nil;
    NSString *key = TaskKey(session, task);
    if (!key) return nil;
    @synchronized(gTaskStates) {
        NSMutableDictionary *state = [gTaskStates objectForKey:key];
        if (!state) {
            state = MakeTaskState(req ?: [NSURLRequest requestWithURL:task.response.URL]);
            [gTaskStates setObject:state forKey:key];
        }
        return state;
    }
}

static void RegisterTask(NSURLSession *session, NSURLSessionTask *task, NSURLRequest *req) {
    if (!session || !task || !req) return;
    NSString *url = req.URL.absoluteString ?: @"";
    if (!IsTargetURL(url)) return;
    NSString *key = TaskKey(session, task);
    if (!key) return;
    @synchronized(gTaskStates) {
        if (![gTaskStates objectForKey:key]) [gTaskStates setObject:MakeTaskState(req) forKey:key];
    }
    PushEvent([NSString stringWithFormat:@"TRACK TARGET task=%lu %@ %@", (unsigned long)task.taskIdentifier,
               req.HTTPMethod.length ? req.HTTPMethod : @"GET", url], @"delegate body capture armed");
}

static DelegateHook *FindDelegateHook(Class cls) {
    if (!cls) return NULL;
    for (NSUInteger i = 0; i < gDelegateHookCount; i++) if (gDelegateHooks[i].cls == cls) return &gDelegateHooks[i];
    return NULL;
}

static IMP InstallDelegateMethod(Class cls, SEL sel, IMP hook) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP old = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (class_addMethod(cls, sel, hook, types)) return old;
    Method own = class_getInstanceMethod(cls, sel);
    if (!own) return NULL;
    return method_setImplementation(own, hook);
}

typedef void (*DidReceiveResponseFn)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSURLResponse *, void (^)(NSURLSessionResponseDisposition));
typedef void (*DidReceiveDataFn)(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *);
typedef void (*DidCompleteFn)(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *);

static void HookDelegateDidReceiveResponse(id self, SEL _cmd, NSURLSession *session, NSURLSessionDataTask *task,
                                           NSURLResponse *response, void (^completionHandler)(NSURLSessionResponseDisposition)) {
    NSMutableDictionary *state = EnsureTaskState(session, task);
    if (state) {
        NSInteger status = 0;
        NSDictionary *headers = nil;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            status = [(NSHTTPURLResponse *)response statusCode];
            headers = [(NSHTTPURLResponse *)response allHeaderFields];
        }
        [state setObject:@(status) forKey:@"status"];
        if (response.URL.absoluteString.length) [state setObject:response.URL.absoluteString forKey:@"url"];
        PushEvent([NSString stringWithFormat:@"DELEGATE RESPONSE TARGET task=%lu status=%ld %@",
                   (unsigned long)task.taskIdentifier, (long)status, response.URL.absoluteString ?: @""],
                  headers.count ? [NSString stringWithFormat:@"headers=%@", headers] : @"");
    }
    DelegateHook *h = FindDelegateHook(object_getClass(self));
    if (h && h->responseIMP) ((DidReceiveResponseFn)h->responseIMP)(self, _cmd, session, task, response, completionHandler);
}

static void HookDelegateDidReceiveData(id self, SEL _cmd, NSURLSession *session, NSURLSessionDataTask *task, NSData *data) {
    NSMutableDictionary *state = EnsureTaskState(session, task);
    if (state && data.length) {
        @synchronized(gTaskStates) {
            NSMutableData *buffer = [state objectForKey:@"data"];
            NSUInteger room = buffer.length < MAX_CAPTURE_BYTES ? (MAX_CAPTURE_BYTES - buffer.length) : 0;
            NSUInteger take = MIN(room, data.length);
            if (take) [buffer appendData:[data subdataWithRange:NSMakeRange(0, take)]];
            if (take < data.length) [state setObject:@1 forKey:@"truncated"];
            NSUInteger chunks = [[state objectForKey:@"chunks"] unsignedIntegerValue] + 1;
            [state setObject:@(chunks) forKey:@"chunks"];
        }
    }
    DelegateHook *h = FindDelegateHook(object_getClass(self));
    if (h && h->dataIMP) ((DidReceiveDataFn)h->dataIMP)(self, _cmd, session, task, data);
}

static void HookDelegateDidComplete(id self, SEL _cmd, NSURLSession *session, NSURLSessionTask *task, NSError *error) {
    NSMutableDictionary *state = EnsureTaskState(session, task);
    if (state) {
        NSString *key = TaskKey(session, task);
        NSData *body = nil;
        NSString *url = nil;
        NSString *method = nil;
        NSUInteger chunks = 0;
        BOOL truncated = NO;
        NSInteger status = 0;
        @synchronized(gTaskStates) {
            body = [[[state objectForKey:@"data"] copy] autorelease];
            url = [[[state objectForKey:@"url"] copy] autorelease];
            method = [[[state objectForKey:@"method"] copy] autorelease];
            chunks = [[state objectForKey:@"chunks"] unsignedIntegerValue];
            truncated = [[state objectForKey:@"truncated"] boolValue];
            status = [[state objectForKey:@"status"] integerValue];
            if (!status && [task.response isKindOfClass:[NSHTTPURLResponse class]]) status = [(NSHTTPURLResponse *)task.response statusCode];
            if (key) [gTaskStates removeObjectForKey:key];
        }
        gDelegateResponses++;
        NSMutableString *detail = [NSMutableString stringWithFormat:@"method=%@ chunks=%lu bytes=%lu%@",
                                   method ?: @"GET", (unsigned long)chunks, (unsigned long)body.length,
                                   truncated ? @" capture-truncated" : @""];
        if (error) [detail appendFormat:@" | error=%@", error];
        if (body.length) [detail appendFormat:@" | response=%@", DataPreview(body, 65536)];
        PushEvent([NSString stringWithFormat:@"DELEGATE COMPLETE TARGET task=%lu status=%ld %@",
                   (unsigned long)task.taskIdentifier, (long)status, url ?: @""], detail);
    }
    DelegateHook *h = FindDelegateHook(object_getClass(self));
    if (h && h->completeIMP) ((DidCompleteFn)h->completeIMP)(self, _cmd, session, task, error);
}

static void InstallDelegateHooksForSession(NSURLSession *session) {
    id delegate = session.delegate;
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if (!cls || FindDelegateHook(cls) || gDelegateHookCount >= MAX_DELEGATE_HOOKS) return;

    DelegateHook *h = &gDelegateHooks[gDelegateHookCount++];
    memset(h, 0, sizeof(*h));
    h->cls = cls;

    SEL responseSel = @selector(URLSession:dataTask:didReceiveResponse:completionHandler:);
    SEL dataSel = @selector(URLSession:dataTask:didReceiveData:);
    SEL completeSel = @selector(URLSession:task:didCompleteWithError:);

    h->responseIMP = InstallDelegateMethod(cls, responseSel, (IMP)HookDelegateDidReceiveResponse);
    h->dataIMP = InstallDelegateMethod(cls, dataSel, (IMP)HookDelegateDidReceiveData);
    h->completeIMP = InstallDelegateMethod(cls, completeSel, (IMP)HookDelegateDidComplete);
    h->responseHooked = h->responseIMP != NULL;
    h->dataHooked = h->dataIMP != NULL;
    h->completeHooked = h->completeIMP != NULL;

    PushEvent([NSString stringWithFormat:@"DELEGATE-HOOK class=%@ response=%d data=%d complete=%d",
               NSStringFromClass(cls), h->responseHooked, h->dataHooked, h->completeHooked], @"");
}

typedef NSURLSessionDataTask *(*DataTaskReqFn)(id, SEL, NSURLRequest *);
typedef NSURLSessionDataTask *(*DataTaskReqCompletionFn)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*DataTaskURLFn)(id, SEL, NSURL *);
typedef NSURLSessionDataTask *(*DataTaskURLCompletionFn)(id, SEL, NSURL *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionUploadTask *(*UploadReqDataFn)(id, SEL, NSURLRequest *, NSData *);
typedef NSURLSessionUploadTask *(*UploadReqDataCompletionFn)(id, SEL, NSURLRequest *, NSData *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef void (*SetURLFn)(id, SEL, NSURL *);
typedef NSData *(*SyncRequestFn)(id, SEL, NSURLRequest *, NSURLResponse **, NSError **);
typedef void (*AsyncRequestFn)(id, SEL, NSURLRequest *, NSOperationQueue *, void (^)(NSURLResponse *, NSData *, NSError *));

static NSURLSessionDataTask *HookDataTaskWithRequest(id self, SEL _cmd, NSURLRequest *req) {
    InstallDelegateHooksForSession((NSURLSession *)self);
    LogRequest(req, @"NSURLSession dataTaskWithRequest");
    NSURLSessionDataTask *task = ((DataTaskReqFn)gDataTaskReqIMP)(self, _cmd, req);
    RegisterTask((NSURLSession *)self, task, req);
    return task;
}

static NSURLSessionDataTask *HookDataTaskWithRequestCompletion(id self, SEL _cmd, NSURLRequest *req,
                                                               void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    InstallDelegateHooksForSession((NSURLSession *)self);
    LogRequest(req, @"NSURLSession dataTaskWithRequest:completion");
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        LogResponse(resp, data, err, @"NSURLSession completion");
        if (completion) completion(data, resp, err);
    };
    return ((DataTaskReqCompletionFn)gDataTaskReqCompletionIMP)(self, _cmd, req, wrapped);
}

static NSURLSessionDataTask *HookDataTaskWithURL(id self, SEL _cmd, NSURL *url) {
    InstallDelegateHooksForSession((NSURLSession *)self);
    LogURL(url, @"NSURLSession dataTaskWithURL");
    NSURLSessionDataTask *task = ((DataTaskURLFn)gDataTaskURLIMP)(self, _cmd, url);
    if (url) RegisterTask((NSURLSession *)self, task, [NSURLRequest requestWithURL:url]);
    return task;
}

static NSURLSessionDataTask *HookDataTaskWithURLCompletion(id self, SEL _cmd, NSURL *url,
                                                           void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    InstallDelegateHooksForSession((NSURLSession *)self);
    LogURL(url, @"NSURLSession dataTaskWithURL:completion");
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        LogResponse(resp, data, err, @"NSURLSession URL completion");
        if (completion) completion(data, resp, err);
    };
    return ((DataTaskURLCompletionFn)gDataTaskURLCompletionIMP)(self, _cmd, url, wrapped);
}

static NSURLSessionUploadTask *HookUploadWithRequestData(id self, SEL _cmd, NSURLRequest *req, NSData *body) {
    InstallDelegateHooksForSession((NSURLSession *)self);
    LogRequest(req, @"NSURLSession uploadTaskWithRequest");
    if (body.length) PushEvent([NSString stringWithFormat:@"UPLOAD body-bytes=%lu", (unsigned long)body.length], DataPreview(body, 4096));
    return ((UploadReqDataFn)gUploadReqDataIMP)(self, _cmd, req, body);
}

static NSURLSessionUploadTask *HookUploadWithRequestDataCompletion(id self, SEL _cmd, NSURLRequest *req, NSData *body,
                                                                   void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    InstallDelegateHooksForSession((NSURLSession *)self);
    LogRequest(req, @"NSURLSession uploadTaskWithRequest:completion");
    if (body.length) PushEvent([NSString stringWithFormat:@"UPLOAD body-bytes=%lu", (unsigned long)body.length], DataPreview(body, 4096));
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        LogResponse(resp, data, err, @"NSURLSession upload completion");
        if (completion) completion(data, resp, err);
    };
    return ((UploadReqDataCompletionFn)gUploadReqDataCompletionIMP)(self, _cmd, req, body, wrapped);
}

static void HookMutableSetURL(id self, SEL _cmd, NSURL *url) {
    if (url.absoluteString.length && IsTargetURL(url.absoluteString)) LogURL(url, @"NSMutableURLRequest setURL");
    ((SetURLFn)gMutableSetURLIMP)(self, _cmd, url);
}

static NSData *HookSyncRequest(id self, SEL _cmd, NSURLRequest *req, NSURLResponse **resp, NSError **err) {
    LogRequest(req, @"NSURLConnection sync");
    NSData *data = ((SyncRequestFn)gSyncRequestIMP)(self, _cmd, req, resp, err);
    LogResponse(resp ? *resp : nil, data, err ? *err : nil, @"NSURLConnection sync");
    return data;
}

static void HookAsyncRequest(id self, SEL _cmd, NSURLRequest *req, NSOperationQueue *queue,
                             void (^completion)(NSURLResponse *, NSData *, NSError *)) {
    LogRequest(req, @"NSURLConnection async");
    void (^wrapped)(NSURLResponse *, NSData *, NSError *) = ^(NSURLResponse *resp, NSData *data, NSError *err) {
        LogResponse(resp, data, err, @"NSURLConnection async");
        if (completion) completion(resp, data, err);
    };
    ((AsyncRequestFn)gAsyncRequestIMP)(self, _cmd, req, queue, wrapped);
}

static BOOL InstallOneInstance(Class cls, SEL sel, IMP hook, IMP *originalOut) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP old = method_setImplementation(m, hook);
    if (originalOut) *originalOut = old;
    return old != NULL;
}

static BOOL InstallOneClass(Class cls, SEL sel, IMP hook, IMP *originalOut) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return NO;
    IMP old = method_setImplementation(m, hook);
    if (originalOut) *originalOut = old;
    return old != NULL;
}

static void InstallHTTPHooks(void) {
    if (gHooksInstalled) return;
    NSUInteger installed = 0;
    installed += InstallOneInstance([NSURLSession class], @selector(dataTaskWithRequest:), (IMP)HookDataTaskWithRequest, &gDataTaskReqIMP);
    installed += InstallOneInstance([NSURLSession class], @selector(dataTaskWithRequest:completionHandler:), (IMP)HookDataTaskWithRequestCompletion, &gDataTaskReqCompletionIMP);
    installed += InstallOneInstance([NSURLSession class], @selector(dataTaskWithURL:), (IMP)HookDataTaskWithURL, &gDataTaskURLIMP);
    installed += InstallOneInstance([NSURLSession class], @selector(dataTaskWithURL:completionHandler:), (IMP)HookDataTaskWithURLCompletion, &gDataTaskURLCompletionIMP);
    installed += InstallOneInstance([NSURLSession class], @selector(uploadTaskWithRequest:fromData:), (IMP)HookUploadWithRequestData, &gUploadReqDataIMP);
    installed += InstallOneInstance([NSURLSession class], @selector(uploadTaskWithRequest:fromData:completionHandler:), (IMP)HookUploadWithRequestDataCompletion, &gUploadReqDataCompletionIMP);
    installed += InstallOneInstance([NSMutableURLRequest class], @selector(setURL:), (IMP)HookMutableSetURL, &gMutableSetURLIMP);
    installed += InstallOneClass([NSURLConnection class], @selector(sendSynchronousRequest:returningResponse:error:), (IMP)HookSyncRequest, &gSyncRequestIMP);
    installed += InstallOneClass([NSURLConnection class], @selector(sendAsynchronousRequest:queue:completionHandler:), (IMP)HookAsyncRequest, &gAsyncRequestIMP);
    gHooksInstalled = installed > 0;
    PushEvent([NSString stringWithFormat:@"HOOKS v6 installed=%lu delayed-after-UI", (unsigned long)installed],
              @"Read-only. Delegate response/data/complete hooks are installed lazily per NSURLSession delegate class.");
}

@interface LoginHTTPObserverTarget : NSObject
+ (instancetype)shared;
- (void)tick:(NSTimer *)timer;
- (void)tap:(id)sender;
- (void)panButton:(UIPanGestureRecognizer *)g;
- (void)panPanel:(UIPanGestureRecognizer *)g;
@end

@implementation LoginHTTPObserverTarget
+ (instancetype)shared {
    static LoginHTTPObserverTarget *s;
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
    gTaskStates = [[NSMutableDictionary alloc] init];

    gFloatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    gFloatButton.frame = CGRectMake(18, 165, 58, 52);
    gFloatButton.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    gFloatButton.layer.cornerRadius = 26;
    [gFloatButton setTitle:@"HTTP6" forState:UIControlStateNormal];
    gFloatButton.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [gFloatButton addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *bp = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panButton:)] autorelease];
    [gFloatButton addGestureRecognizer:bp];
    [w addSubview:gFloatButton];

    gPanel = [[[UIView alloc] initWithFrame:CGRectMake(52, 82, 360, 380)] autorelease];
    gPanel.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.97];
    gPanel.layer.cornerRadius = 14;
    UIPanGestureRecognizer *pp = [[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panPanel:)] autorelease];
    pp.cancelsTouchesInView = NO;
    [gPanel addGestureRecognizer:pp];

    UILabel *title = [[[UILabel alloc] initWithFrame:CGRectMake(12, 8, 336, 44)] autorelease];
    title.textColor = [UIColor whiteColor];
    title.numberOfLines = 2;
    title.font = [UIFont boldSystemFontOfSize:16];
    title.text = @"Login HTTP Observer v6\nDelegate Response Capture";
    [gPanel addSubview:title];

    gStatusLabel = [[[UILabel alloc] initWithFrame:CGRectMake(12, 54, 336, 42)] autorelease];
    gStatusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    gStatusLabel.numberOfLines = 2;
    gStatusLabel.font = [UIFont systemFontOfSize:11];
    [gPanel addSubview:gStatusLabel];

    gTextView = [[[UITextView alloc] initWithFrame:CGRectMake(10, 100, 340, 270)] autorelease];
    gTextView.backgroundColor = [UIColor colorWithWhite:0.015 alpha:1];
    gTextView.textColor = [UIColor colorWithWhite:0.92 alpha:1];
    gTextView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    gTextView.editable = NO;
    gTextView.selectable = YES;
    [gPanel addSubview:gTextView];

    gPanel.hidden = YES;
    [w addSubview:gPanel];
    gUIReady = YES;
    gHookDelayTicks = 2;
    PushEvent(@"UI-READY; v6 HTTP hooks will install after delay", @"");
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
        else InstallHTTPHooks();
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
    c.x = MAX(29, MIN(b.size.width - 29, c.x));
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

__attribute__((constructor)) static void LoginHTTPObserverInit(void) {
    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        if (home.length) gLogPath = [[home stringByAppendingPathComponent:@"Documents/LoginHTTPTrace_v6.log"] retain];
        AppendFile(@"\n[LoginHTTPObserver v6 Delegate Response Capture] loaded; waiting for UI before hooks");
        dispatch_async(dispatch_get_main_queue(), ^{
            LoginHTTPObserverTarget *t = [LoginHTTPObserverTarget shared];
            [NSTimer scheduledTimerWithTimeInterval:0.5 target:t selector:@selector(tick:) userInfo:nil repeats:YES];
        });
    }
}
