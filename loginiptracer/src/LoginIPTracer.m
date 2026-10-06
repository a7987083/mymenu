#include <sys/types.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * LoginIPTracer v4 RealTime
 * Stable injection/UI lifecycle is kept from the proven HFAMap v1.8.7 shell:
 * constructor -> NSObject target -> NSTimer -> wait for UIWindow -> floating button.
 *
 * Important behavior:
 * - No connect/getaddrinfo hook/interpose.
 * - No socket scan before the floating UI exists.
 * - Capture starts automatically about one timer tick AFTER the floating button is visible.
 * - Tapping the floating "IP" button only opens/closes the realtime panel.
 */

typedef unsigned long size_t_hfa;
typedef unsigned long long u64;
typedef signed char BOOL;
typedef struct objc_object* id;
typedef struct objc_class* Class;
typedef struct objc_selector* SEL;
typedef void(*IMP)(void);
typedef struct { double x,y; } CGPoint;
typedef struct { double width,height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

extern Class objc_getClass(const char*);
extern SEL sel_registerName(const char*);
extern void objc_msgSend(void);
extern Class objc_allocateClassPair(Class,const char*,size_t_hfa);
extern BOOL class_addMethod(Class,SEL,IMP,const char*);
extern void objc_registerClassPair(Class);

#define M0(r,o,s) ((r(*)(id,SEL))objc_msgSend)((id)(o),sel_registerName(s))
#define M1(r,o,s,t,a) ((r(*)(id,SEL,t))objc_msgSend)((id)(o),sel_registerName(s),(a))
#define M2(r,o,s,t,a,u,b) ((r(*)(id,SEL,t,u))objc_msgSend)((id)(o),sel_registerName(s),(a),(b))
#define M3(r,o,s,t,a,u,b,v,c) ((r(*)(id,SEL,t,u,v))objc_msgSend)((id)(o),sel_registerName(s),(a),(b),(c))
#define M4(r,o,s,t,a,u,b,v,c,w,d) ((r(*)(id,SEL,t,u,v,w))objc_msgSend)((id)(o),sel_registerName(s),(a),(b),(c),(d))
#define M5(r,o,s,t,a,u,b,v,c,w,d,x,e) ((r(*)(id,SEL,t,u,v,w,x))objc_msgSend)((id)(o),sel_registerName(s),(a),(b),(c),(d),(e))
#define TOUCHUP (1ULL<<6)

#define MAX_CONN 256
#define MAX_FD_SCAN 1024
#define LIVE_LINES 12
#define LIVE_LINE_CAP 192

typedef struct {
    int used;
    int active;
    int present;
    int longReported;
    int fd;
    int type;
    unsigned int seq;
    char local[128];
    char remote[128];
    char kind[24];
    double firstSeen;
    double lastSeen;
} ConnEntry;

static id gTarget=0,gButton=0,gPanel=0,gWindow=0,gStatus=0,gLive=0;
static int gMade=0,gCapturing=0,gTickPhase=0,gAutoStartCountdown=0;
static char gLogPath[768];
static ConnEntry gConn[MAX_CONN];
static unsigned int gConnSeq=0,gNewCount=0,gGoneCount=0,gLongCount=0;
static double gCaptureStart=0.0;
static char gLastPublic[128];
static char gLiveLines[LIVE_LINES][LIVE_LINE_CAP];
static unsigned int gLiveCount=0;

static id ns(const char*s){
    Class c=objc_getClass("NSString");
    return c?M1(id,(id)c,"stringWithUTF8String:",const char*,s?s:""):0;
}

static id color(double r,double g,double b,double a){
    Class c=objc_getClass("UIColor");
    return c?M4(id,(id)c,"colorWithRed:green:blue:alpha:",double,r,double,g,double,b,double,a):0;
}

static double now_sec(void){
    struct timeval tv;
    if(gettimeofday(&tv,0)!=0)return 0.0;
    return (double)tv.tv_sec + ((double)tv.tv_usec/1000000.0);
}

static double rel_sec(double t){
    if(gCaptureStart<=0.0||t<gCaptureStart)return 0.0;
    return t-gCaptureStart;
}

static void logf0(const char*fmt,...){
    if(!gLogPath[0])return;
    FILE*f=fopen(gLogPath,"a");
    if(!f)return;
    __builtin_va_list ap;
    __builtin_va_start(ap,fmt);
    vfprintf(f,fmt,ap);
    __builtin_va_end(ap);
    fflush(f);
    fclose(f);
}

static void initlog(void){
    char*h=getenv("HOME");
    if(!h)return;
    snprintf(gLogPath,sizeof(gLogPath),"%s/Documents/LoginIPTrace.log",h);
    logf0("\n[LoginIPTracer v4 RealTime HFAMap187] loaded pid=%d epoch=%.3f\n",getpid(),now_sec());
}

static void copyc(char*d,const char*s,size_t_hfa cap){
    if(!d||!cap)return;
    size_t_hfa i=0;
    if(s)for(;s[i]&&i+1<cap;i++)d[i]=s[i];
    d[i]=0;
}

static int ceq(const char*a,const char*b){
    if(!a||!b)return 0;
    while(*a&&*b&&*a==*b){a++;b++;}
    return *a==0&&*b==0;
}

static int is_public_kind(const char*k){return k&&ceq(k,"public");}
static int is_live_kind(const char*k){return k&&(ceq(k,"public")||ceq(k,"benchmark/fake")||ceq(k,"private"));}

static const char* addr_kind(const struct sockaddr*sa){
    if(!sa)return "unknown";
    if(sa->sa_family==AF_INET){
        const struct sockaddr_in*a=(const struct sockaddr_in*)sa;
        unsigned long ip=(unsigned long)ntohl(a->sin_addr.s_addr);
        unsigned int b1=(unsigned int)((ip>>24)&255);
        unsigned int b2=(unsigned int)((ip>>16)&255);
        if(b1==127)return "loopback";
        if(b1==10)return "private";
        if(b1==172&&b2>=16&&b2<=31)return "private";
        if(b1==192&&b2==168)return "private";
        if(b1==169&&b2==254)return "linklocal";
        if(b1==198&&(b2==18||b2==19))return "benchmark/fake";
        return "public";
    }
    if(sa->sa_family==AF_INET6){
        const struct sockaddr_in6*a=(const struct sockaddr_in6*)sa;
        static const unsigned char loop[16]={0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1};
        if(memcmp(&a->sin6_addr,loop,16)==0)return "loopback";
        return "ipv6";
    }
    return "other";
}

static int format_addr(const struct sockaddr*sa,char*out,size_t_hfa cap){
    if(!sa||!out||cap<8)return 0;
    out[0]=0;
    char ip[INET6_ADDRSTRLEN]={0};
    if(sa->sa_family==AF_INET){
        const struct sockaddr_in*a=(const struct sockaddr_in*)sa;
        if(!inet_ntop(AF_INET,&a->sin_addr,ip,sizeof(ip)))return 0;
        snprintf(out,cap,"%s:%u",ip,(unsigned)ntohs(a->sin_port));
        return 1;
    }
    if(sa->sa_family==AF_INET6){
        const struct sockaddr_in6*a=(const struct sockaddr_in6*)sa;
        if(!inet_ntop(AF_INET6,&a->sin6_addr,ip,sizeof(ip)))return 0;
        snprintf(out,cap,"[%s]:%u",ip,(unsigned)ntohs(a->sin6_port));
        return 1;
    }
    return 0;
}

static void settext(id l,const char*s){if(l)M1(void,l,"setText:",id,ns(s));}

static void refresh_live(void){
    if(!gLive)return;
    char out[2600];
    size_t_hfa used=0;
    out[0]=0;
    for(unsigned int i=0;i<gLiveCount;i++){
        int n=snprintf(out+used,sizeof(out)-used,"%s%s",i?"\n":"",gLiveLines[i]);
        if(n<=0)break;
        if((size_t_hfa)n>=sizeof(out)-used){used=sizeof(out)-1;break;}
        used+=(size_t_hfa)n;
    }
    out[sizeof(out)-1]=0;
    settext(gLive,out);
}

static void live_push(const char*fmt,...){
    char line[LIVE_LINE_CAP];
    __builtin_va_list ap;
    __builtin_va_start(ap,fmt);
    vsnprintf(line,sizeof(line),fmt,ap);
    __builtin_va_end(ap);
    line[sizeof(line)-1]=0;

    if(gLiveCount<LIVE_LINES){
        copyc(gLiveLines[gLiveCount++],line,LIVE_LINE_CAP);
    }else{
        for(unsigned int i=1;i<LIVE_LINES;i++)copyc(gLiveLines[i-1],gLiveLines[i],LIVE_LINE_CAP);
        copyc(gLiveLines[LIVE_LINES-1],line,LIVE_LINE_CAP);
    }
    refresh_live();
}

static ConnEntry* find_active(int fd,const char*remote){
    for(unsigned int i=0;i<MAX_CONN;i++){
        ConnEntry*e=&gConn[i];
        if(e->used&&e->active&&e->fd==fd&&ceq(e->remote,remote))return e;
    }
    return 0;
}

static ConnEntry* alloc_entry(void){
    for(unsigned int i=0;i<MAX_CONN;i++)if(!gConn[i].used)return &gConn[i];
    for(unsigned int i=0;i<MAX_CONN;i++)if(!gConn[i].active)return &gConn[i];
    return 0;
}

static unsigned int active_count(void){
    unsigned int n=0;
    for(unsigned int i=0;i<MAX_CONN;i++)if(gConn[i].used&&gConn[i].active)n++;
    return n;
}

static unsigned int active_public_count(void){
    unsigned int n=0;
    for(unsigned int i=0;i<MAX_CONN;i++){
        ConnEntry*e=&gConn[i];
        if(e->used&&e->active&&is_public_kind(e->kind))n++;
    }
    return n;
}

static void update_status(void){
    if(!gStatus)return;
    char s[640];
    if(gCapturing){
        snprintf(s,sizeof(s),
            "AUTO CAPTURE  +%.1fs\nActive=%u   Public=%u   NEW=%u   GONE=%u   LONG=%u\nLast public: %s\nFull log: Documents/LoginIPTrace.log",
            rel_sec(now_sec()),active_count(),active_public_count(),gNewCount,gGoneCount,gLongCount,
            gLastPublic[0]?gLastPublic:"(none)");
    }else if(gAutoStartCountdown>0){
        snprintf(s,sizeof(s),"UI ready. Auto capture starts after the floating button is visible...\nFull log: Documents/LoginIPTrace.log");
    }else{
        snprintf(s,sizeof(s),"Waiting for auto capture...\nFull log: Documents/LoginIPTrace.log");
    }
    settext(gStatus,s);
}

static void scan_sockets(void){
    if(!gCapturing)return;
    double t=now_sec();
    for(unsigned int i=0;i<MAX_CONN;i++)if(gConn[i].used&&gConn[i].active)gConn[i].present=0;

    for(int fd=0;fd<MAX_FD_SCAN;fd++){
        struct sockaddr_storage peer;
        socklen_t plen=(socklen_t)sizeof(peer);
        memset(&peer,0,sizeof(peer));
        if(getpeername(fd,(struct sockaddr*)&peer,&plen)!=0)continue;
        if(peer.ss_family!=AF_INET&&peer.ss_family!=AF_INET6)continue;

        char remote[128]={0};
        if(!format_addr((const struct sockaddr*)&peer,remote,sizeof(remote)))continue;

        int type=0;
        socklen_t tlen=(socklen_t)sizeof(type);
        getsockopt(fd,SOL_SOCKET,SO_TYPE,&type,&tlen);

        struct sockaddr_storage local;
        socklen_t llen=(socklen_t)sizeof(local);
        memset(&local,0,sizeof(local));
        char localText[128]={0};
        if(getsockname(fd,(struct sockaddr*)&local,&llen)==0)
            format_addr((const struct sockaddr*)&local,localText,sizeof(localText));

        ConnEntry*e=find_active(fd,remote);
        if(!e){
            e=alloc_entry();
            if(!e)continue;
            memset(e,0,sizeof(*e));
            e->used=1;e->active=1;e->present=1;e->fd=fd;e->type=type;
            e->seq=++gConnSeq;e->firstSeen=t;e->lastSeen=t;
            copyc(e->remote,remote,sizeof(e->remote));
            copyc(e->local,localText,sizeof(e->local));
            copyc(e->kind,addr_kind((const struct sockaddr*)&peer),sizeof(e->kind));
            gNewCount++;
            logf0("[NEW] +%.3fs seq=%u fd=%d type=%d kind=%s local=%s remote=%s\n",
                  rel_sec(t),e->seq,e->fd,e->type,e->kind,e->local[0]?e->local:"?",e->remote);
            if(is_public_kind(e->kind)){
                copyc(gLastPublic,e->remote,sizeof(gLastPublic));
                live_push("+%.2fs  NEW   %s",rel_sec(t),e->remote);
            }else if(is_live_kind(e->kind)){
                live_push("+%.2fs  %-5s %s",rel_sec(t),e->kind,e->remote);
            }
        }else{
            e->present=1;e->lastSeen=t;e->type=type;
            if(localText[0])copyc(e->local,localText,sizeof(e->local));
        }
    }

    for(unsigned int i=0;i<MAX_CONN;i++){
        ConnEntry*e=&gConn[i];
        if(e->used&&e->active&&!e->present){
            double dur=t-e->firstSeen;
            if(dur<0)dur=0;
            logf0("[GONE] +%.3fs seq=%u fd=%d duration=%.3fs kind=%s remote=%s reason=closed-or-reused\n",
                  rel_sec(t),e->seq,e->fd,dur,e->kind,e->remote);
            if(is_public_kind(e->kind))live_push("+%.2fs  GONE  %s  %.1fs",rel_sec(t),e->remote,dur);
            e->active=0;
            gGoneCount++;
        }
    }

    for(unsigned int i=0;i<MAX_CONN;i++){
        ConnEntry*e=&gConn[i];
        if(!e->used||!e->active||e->longReported||!is_public_kind(e->kind))continue;
        double dur=t-e->firstSeen;
        if(dur>=10.0){
            e->longReported=1;
            gLongCount++;
            logf0("[LONG] +%.3fs seq=%u fd=%d duration=%.3fs remote=%s\n",
                  rel_sec(t),e->seq,e->fd,dur,e->remote);
            live_push("+%.2fs  LONG  %s  %.1fs",rel_sec(t),e->remote,dur);
        }
    }
    update_status();
}

static void start_auto_capture(void){
    if(gCapturing)return;
    memset(gConn,0,sizeof(gConn));
    memset(gLiveLines,0,sizeof(gLiveLines));
    gLiveCount=0;
    gConnSeq=0;gNewCount=0;gGoneCount=0;gLongCount=0;
    gLastPublic[0]=0;
    gCaptureStart=now_sec();
    gCapturing=1;
    logf0("[CAPTURE-AUTO-START] epoch=%.3f after-ui=1\n",gCaptureStart);
    live_push("AUTO capture started after UI ready");
    update_status();
    scan_sockets();
}

static id win(void){
    Class ac=objc_getClass("UIApplication");
    if(!ac)return 0;
    id app=M0(id,(id)ac,"sharedApplication");
    if(!app)return 0;
    id w=M0(id,app,"keyWindow");
    if(w)return w;
    id a=M0(id,app,"windows");
    if(!a)return 0;
    u64 n=M0(u64,a,"count");
    return n?M1(id,a,"objectAtIndex:",u64,n-1):0;
}

static id mklabel(CGRect r,double fs){
    Class lc=objc_getClass("UILabel");
    if(!lc)return 0;
    id l=M0(id,(id)lc,"alloc");
    l=M1(id,l,"initWithFrame:",CGRect,r);
    M1(void,l,"setTextColor:",id,color(.95,.95,.98,1));
    M1(void,l,"setNumberOfLines:",long long,0);
    Class fc=objc_getClass("UIFont");
    if(fc)M1(void,l,"setFont:",id,M1(id,(id)fc,"systemFontOfSize:",double,fs));
    return l;
}

static void pan(id self,SEL c,id g){
    (void)self;(void)c;
    if(!gButton||!gWindow)return;
    long long st=M0(long long,g,"state");
    if(st==1||st==2){
        CGPoint tr=M1(CGPoint,g,"translationInView:",id,gWindow);
        CGPoint ce=M0(CGPoint,gButton,"center");
        ce.x+=tr.x;ce.y+=tr.y;
        CGRect b=M0(CGRect,gWindow,"bounds");
        double h=26;
        if(ce.x<h)ce.x=h;if(ce.x>b.size.width-h)ce.x=b.size.width-h;
        if(ce.y<h)ce.y=h;if(ce.y>b.size.height-h)ce.y=b.size.height-h;
        M1(void,gButton,"setCenter:",CGPoint,ce);
        CGPoint z={0,0};
        M2(void,g,"setTranslation:inView:",CGPoint,z,id,gWindow);
    }
}

static void panelpan(id self,SEL c,id g){
    (void)self;(void)c;
    if(!gPanel||!gWindow)return;
    long long st=M0(long long,g,"state");
    if(st==1||st==2){
        CGPoint tr=M1(CGPoint,g,"translationInView:",id,gWindow);
        CGPoint ce=M0(CGPoint,gPanel,"center");
        ce.x+=tr.x;ce.y+=tr.y;
        M1(void,gPanel,"setCenter:",CGPoint,ce);
        CGPoint z={0,0};
        M2(void,g,"setTranslation:inView:",CGPoint,z,id,gWindow);
    }
}

static void tap(id self,SEL c,id s){
    (void)self;(void)c;(void)s;
    if(gPanel){
        BOOL h=M0(BOOL,gPanel,"isHidden");
        M1(void,gPanel,"setHidden:",BOOL,!h);
        if(h){update_status();refresh_live();}
    }
}

static void mkui(id w){
    if(gMade||!w)return;
    Class bc=objc_getClass("UIButton"),vc=objc_getClass("UIView");
    if(!bc||!vc)return;

    id b=M0(id,(id)bc,"alloc");
    b=M1(id,b,"initWithFrame:",CGRect,((CGRect){{18,165},{52,52}}));
    M2(void,b,"setTitle:forState:",id,ns("IP"),u64,0);
    M1(void,b,"setBackgroundColor:",id,color(.12,.12,.15,.94));
    id ly=M0(id,b,"layer");
    if(ly)M1(void,ly,"setCornerRadius:",double,26);
    M3(void,b,"addTarget:action:forControlEvents:",id,gTarget,SEL,sel_registerName("tap:"),u64,TOUCHUP);

    Class pc=objc_getClass("UIPanGestureRecognizer");
    if(pc){
        id pg=M0(id,(id)pc,"alloc");
        pg=M2(id,pg,"initWithTarget:action:",id,gTarget,SEL,sel_registerName("pan:"));
        M1(void,b,"addGestureRecognizer:",id,pg);
    }
    M1(void,w,"addSubview:",id,b);
    gButton=b;

    id p=M0(id,(id)vc,"alloc");
    p=M1(id,p,"initWithFrame:",CGRect,((CGRect){{60,80},{350,410}}));
    M1(void,p,"setBackgroundColor:",id,color(.055,.06,.075,.97));
    ly=M0(id,p,"layer");
    if(ly)M1(void,ly,"setCornerRadius:",double,14);
    if(pc){
        id pg=M0(id,(id)pc,"alloc");
        pg=M2(id,pg,"initWithTarget:action:",id,gTarget,SEL,sel_registerName("panelpan:"));
        M1(void,pg,"setCancelsTouchesInView:",BOOL,0);
        M1(void,p,"addGestureRecognizer:",id,pg);
    }

    id title=mklabel((CGRect){{14,10},{322,44}},18);
    settext(title,"Login IP Tracer v4 RealTime");
    M1(void,p,"addSubview:",id,title);

    gStatus=mklabel((CGRect){{14,52},{322,92}},11);
    settext(gStatus,"UI ready. Auto capture will start after this floating window is visible.");
    M1(void,p,"addSubview:",id,gStatus);

    id sep=mklabel((CGRect){{14,145},{322,22}},11);
    settext(sep,"Realtime endpoint events (full log includes loopback):");
    M1(void,p,"addSubview:",id,sep);

    gLive=mklabel((CGRect){{14,170},{322,222}},10);
    settext(gLive,"Waiting for auto capture...");
    M1(void,p,"addSubview:",id,gLive);

    M1(void,p,"setHidden:",BOOL,1);
    M1(void,w,"addSubview:",id,p);
    gPanel=p;gWindow=w;gMade=1;

    /* One full timer tick delay guarantees the floating button exists first. */
    gAutoStartCountdown=2;
    logf0("[UI-READY] epoch=%.3f auto-start-countdown=%d\n",now_sec(),gAutoStartCountdown);
    update_status();
}

static void tick(id self,SEL c,id timer){
    (void)self;(void)c;(void)timer;
    id w=win();
    if(!w)return;
    if(!gMade)mkui(w);
    if(gMade&&gWindow!=w){
        M1(void,w,"addSubview:",id,gPanel);
        M1(void,w,"addSubview:",id,gButton);
        gWindow=w;
    }

    if(gMade&&!gCapturing&&gAutoStartCountdown>0){
        gAutoStartCountdown--;
        update_status();
        if(gAutoStartCountdown==0)start_auto_capture();
    }

    if(gCapturing){
        gTickPhase++;
        if((gTickPhase&1)==0)scan_sockets();
    }

    if(gMade){
        M1(void,w,"bringSubviewToFront:",id,gPanel);
        M1(void,w,"bringSubviewToFront:",id,gButton);
    }
}

__attribute__((constructor)) static void init(void){
    initlog();
    Class base=objc_getClass("NSObject");
    if(!base)return;
    Class c=objc_allocateClassPair(base,"LoginIPTracerTarget187V4",0);
    if(!c)c=objc_getClass("LoginIPTracerTarget187V4");
    if(!c)return;
    class_addMethod(c,sel_registerName("tick:"),(IMP)tick,"v@:@");
    class_addMethod(c,sel_registerName("tap:"),(IMP)tap,"v@:@");
    class_addMethod(c,sel_registerName("pan:"),(IMP)pan,"v@:@");
    class_addMethod(c,sel_registerName("panelpan:"),(IMP)panelpan,"v@:@");
    objc_registerClassPair(c);
    gTarget=M0(id,(id)c,"new");
    Class t=objc_getClass("NSTimer");
    if(t&&gTarget)M5(id,(id)t,"scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",double,.5,id,gTarget,SEL,sel_registerName("tick:"),id,(id)0,BOOL,1);
}
