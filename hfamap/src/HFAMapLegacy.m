typedef unsigned long size_t; typedef unsigned long long u64; typedef signed char BOOL; typedef struct __HF_FILE FILE; typedef void* pthread_t;
typedef struct objc_object* id; typedef struct objc_class* Class; typedef struct objc_selector* SEL; typedef void(*IMP)(void);
typedef struct { double x,y; } CGPoint; typedef struct { double width,height; } CGSize; typedef struct { CGPoint origin; CGSize size; } CGRect;
extern Class objc_getClass(const char*); extern SEL sel_registerName(const char*); extern void objc_msgSend(void);
extern Class objc_allocateClassPair(Class,const char*,size_t); extern BOOL class_addMethod(Class,SEL,IMP,const char*); extern void objc_registerClassPair(Class);
extern IMP class_replaceMethod(Class,SEL,IMP,const char*); extern const char* class_getName(Class); extern const char* sel_getName(SEL);
extern unsigned int _dyld_image_count(void); extern const char *_dyld_get_image_name(unsigned int); extern const void *_dyld_get_image_header(unsigned int);
extern int pthread_create(pthread_t*,const void*,void*(*)(void*),void*); extern char* getenv(const char*); extern size_t strlen(const char*); extern char* strcpy(char*,const char*);
extern char* strstr(const char*,const char*); extern void* memcpy(void*,const void*,size_t); extern void* malloc(size_t); extern void free(void*);
extern FILE* fopen(const char*,const char*); extern int fclose(FILE*); extern int fflush(FILE*); extern int vfprintf(FILE*,const char*,__builtin_va_list);
extern void HFAPatchTraceBeginEvent(unsigned int); extern void HFAPatchTraceSetFeature(const char*); extern void HFAPatchTraceConsiderString(const char*); extern void HFAPatchTraceSetTarget(const char*); extern void HFAPatchTraceSetIdentifier(const char*); extern void HFAPatchTraceObserveAction(id,SEL); extern void HFAPatchTraceArm(unsigned int); extern void HFAPatchTraceFinalizeEvent(unsigned int); extern unsigned int HFAPatchTraceFinalizeScan(void); extern const char* HFAPatchTraceDetectedTarget(void); extern void HFARegisterPatchObject(id,const char*); extern void HFARegisterPatchSecret(id,id,const char*); extern void HFARegisterPatchString(id,const char*); extern void HFARegisterFeatureDefinition(const char*,const char*); extern void HFARegisterCustomBlock(id,const char*);
#define M0(r,o,s) ((r(*)(id,SEL))objc_msgSend)((id)(o),sel_registerName(s))
#define M1(r,o,s,t,a) ((r(*)(id,SEL,t))objc_msgSend)((id)(o),sel_registerName(s),(a))
#define M2(r,o,s,t,a,u,b) ((r(*)(id,SEL,t,u))objc_msgSend)((id)(o),sel_registerName(s),(a),(b))
#define M3(r,o,s,t,a,u,b,v,c) ((r(*)(id,SEL,t,u,v))objc_msgSend)((id)(o),sel_registerName(s),(a),(b),(c))
#define M4(r,o,s,t,a,u,b,v,c,w,d) ((r(*)(id,SEL,t,u,v,w))objc_msgSend)((id)(o),sel_registerName(s),(a),(b),(c),(d))
#define M5(r,o,s,t,a,u,b,v,c,w,d,x,e) ((r(*)(id,SEL,t,u,v,w,x))objc_msgSend)((id)(o),sel_registerName(s),(a),(b),(c),(d),(e))
#define TOUCHUP (1ULL<<6)
static id gTarget=0,gButton=0,gPanel=0,gWindow=0,gStatus=0; static int gMade=0,gAttached=0,gHooked=0; static unsigned int gEvent=0;
static char gFound[768],gLogPath[768]; static IMP gOrigSend=0;
static id ns(const char*s){Class c=objc_getClass("NSString");return c?M1(id,(id)c,"stringWithUTF8String:",const char*,s?s:""):0;}
static id color(double r,double g,double b,double a){Class c=objc_getClass("UIColor");return c?M4(id,(id)c,"colorWithRed:green:blue:alpha:",double,r,double,g,double,b,double,a):0;}
static void logf(const char*fmt,...){if(!gLogPath[0])return;FILE*f=fopen(gLogPath,"a");if(!f)return;__builtin_va_list ap;__builtin_va_start(ap,fmt);vfprintf(f,fmt,ap);__builtin_va_end(ap);fflush(f);fclose(f);}
static void initlog(void){char*h=getenv("HOME");if(!h)return;strcpy(gLogPath,h);strcpy(gLogPath+strlen(gLogPath),"/Documents/HFAMap_Learn.log");logf("[HFALearn UI v1.8.7 KeyRegisterProbe] loaded\n");}
static int ceq(const char*a,const char*b){if(!a||!b)return 0;while(*a&&*b&&*a==*b){a++;b++;}return *a==0&&*b==0;}
static int starts(const char*s,const char*p){if(!s||!p)return 0;while(*p){if(*s++!=*p++)return 0;}return 1;}
static const char*cbase(const char*p){const char*q=p,*r=p;if(!p)return"";while(*q){if(*q=='/')r=q+1;q++;}return r;}
static void copyc(char*d,const char*s,size_t cap){if(!cap)return;size_t i=0;if(s)for(;s[i]&&i+1<cap;i++)d[i]=s[i];d[i]=0;}
static int customcn(const char*c){if(!c||!*c)return 0;return !(starts(c,"UI")||starts(c,"_UI")||starts(c,"NS")||starts(c,"__NS")||starts(c,"CA")||starts(c,"CG")||starts(c,"Unity")||starts(c,"HFAMap"));}
static u64 hexptr(const char*s){u64 v=0;int any=0;if(!s)return 0;if(s[0]=='0'&&s[1]=='x')s+=2;while(*s){int d=-1;char c=*s;if(c>='0'&&c<='9')d=c-'0';else if(c>='a'&&c<='f')d=c-'a'+10;else if(c>='A'&&c<='F')d=c-'A'+10;else break;v=(v<<4)|(u64)d;any=1;s++;}return any?v:0;}
static int resp(id o,const char*s){return o?((BOOL(*)(id,SEL,SEL))objc_msgSend)(o,sel_registerName("respondsToSelector:"),sel_registerName(s)):0;}
static const char* objtext(id o,const char*sel){if(!o||!resp(o,sel))return 0;id x=M0(id,o,sel);return x?(const char*)M0(void*,x,"UTF8String"):0;}
static const char* utf8(id o){return o&&resp(o,"UTF8String")?(const char*)M0(void*,o,"UTF8String"):0;}
static void dump_text(id o){if(!o)return;Class c=M0(Class,o,"class");const char*cn=c?class_getName(c):"?";const char*s=objtext(o,"text");if(!s||!*s)s=objtext(o,"currentTitle");if(!s||!*s)s=objtext(o,"accessibilityLabel");if(s&&*s){HFAPatchTraceSetFeature(s);size_t n=strlen(s);if(n>180)logf("  [TEXT] %s %.160s...[len=%llu]\n",cn,s,(u64)n);else logf("  [TEXT] %s %s\n",cn,s);}}
static void near_text(id sender){id p=sender;for(int d=0;d<3&&p;d++){dump_text(p);if(resp(p,"subviews")){id a=M0(id,p,"subviews");u64 n=a?M0(u64,a,"count"):0;if(n>16)n=16;for(u64 i=0;i<n;i++){id x=M1(id,a,"objectAtIndex:",u64,i);dump_text(x);}}p=M0(id,p,"superview");}}
static const char* findn(const char*s,const char*e,const char*pat){size_t n=strlen(pat);for(;s&&s+n<=e;s++){size_t i=0;for(;i<n&&s[i]==pat[i];i++);if(i==n)return s;}return 0;}
static void dump_own(id o,const char*tag,int depth);
static void dump_dictionary(id d,int depth){
    if(!d||depth>1||!resp(d,"allKeys")||!resp(d,"objectForKey:"))return;
    id keys=M0(id,d,"allKeys");u64 n=keys&&resp(keys,"count")?M0(u64,keys,"count"):0;
    if(n>64)n=64;
    char ident[96]={0},label[256]={0};
    for(u64 i=0;i<n;i++){
        id k=M1(id,keys,"objectAtIndex:",u64,i);id v=M1(id,d,"objectForKey:",id,k);
        const char*ks=utf8(k),*vs=utf8(v);
        if(ks&&vs&&ceq(ks,"identifier"))copyc(ident,vs,sizeof(ident));
        else if(ks&&vs&&ceq(ks,"label"))copyc(label,vs,sizeof(label));
    }
    if(label[0]&&ident[0])HFARegisterFeatureDefinition(label,ident);
    logf("      [DICTIONARY] ptr=%p count=%llu identifier=%s label=%s\n",d,n,ident[0]?ident:"?",label[0]?label:"?");
    for(u64 i=0;i<n;i++){
        id k=M1(id,keys,"objectAtIndex:",u64,i);id v=M1(id,d,"objectForKey:",id,k);
        const char*ks=utf8(k);Class vc=v?M0(Class,v,"class"):0;const char*vcn=vc?class_getName(vc):"(nil)";const char*vs=utf8(v);
        logf("        kv[%llu] key=%s valueClass=%s value=%s ptr=%p\n",i,ks?ks:"?",vcn,vs?vs:"?",v);
        if(ident[0]&&strstr(vcn,"Block"))HFARegisterCustomBlock(v,ident);
    }
}
static void dump_collection(id o,const char*cn,int depth){if(!o||depth>1)return;id a=o;if(strstr(cn,"Dictionary")){dump_dictionary(o,depth);if(resp(o,"allValues"))a=M0(id,o,"allValues");}if(!a||!resp(a,"count")||!resp(a,"objectAtIndex:"))return;u64 n=M0(u64,a,"count");logf("    [COLLECTION] class=%s count=%llu\n",cn,n);if(n>24)n=24;for(u64 i=0;i<n;i++){id x=M1(id,a,"objectAtIndex:",u64,i);if(!x)continue;Class c=M0(Class,x,"class");const char*xc=c?class_getName(c):"?";logf("      item[%llu] class=%s ptr=%p\n",i,xc,x);if(strstr(xc,"Dictionary"))dump_dictionary(x,depth+1);else if(customcn(xc))dump_own(x,"ITEM",depth+1);}}
static u64 gLastSI[2]={0,0};
static u64 secret_imp(id x){if(!x||!resp(x,"_methodDescription"))return 0;id d=M0(id,x,"_methodDescription");const char*s=d?(const char*)M0(void*,d,"UTF8String"):0;if(!s)return 0;const char*q=strstr(s," secret; (0x");if(!q)q=strstr(s," secret; (0X");if(!q)return 0;q=strstr(q,"0x");return q?hexptr(q):0;}
static void imp_image(u64 imp,const char*kind){if(!imp)return;int k=strstr(kind,"Data")?1:0;if(gLastSI[k]==imp)return;gLastSI[k]=imp;u64 best=0;const char*bp=0;unsigned int n=_dyld_image_count();for(unsigned int i=0;i<n;i++){const void*h=_dyld_get_image_header(i);u64 a=(u64)(size_t)h;if(a<=imp&&a>best){best=a;bp=_dyld_get_image_name(i);}}if(best&&imp-best<0x10000000ULL)logf("[SI]%s imp=%p image=%s base=%p rva=%llX\n",kind,(void*)(size_t)imp,bp?cbase(bp):"?",(void*)(size_t)best,imp-best);else logf("[SI]%s imp=%p image=? base=%p rva=0\n",kind,(void*)(size_t)imp,(void*)(size_t)best);}
static void probe_secret_selector(id x,const char*actualClass,const char*kind){
    if(!gAttached||!x||!kind)return;int ok=resp(x,"secret")?1:0;void*sp=ok?M0(void*,x,"secret"):0;u64 imp=secret_imp(x);imp_image(imp,kind);if(!sp){logf("    [SECRET] %s obj=%p ok=%d p=%p\n",kind,x,ok,sp);return;}unsigned int h[2];u64 q[2];memcpy(h,sp,8);unsigned int len=h[0],flags=h[1];int plausible=len>0&&len<=32;if(plausible)memcpy(q,sp,16);else q[0]=q[1]=0;logf("[B]%s %p %u %08X %u %d %016llX%016llX\n",kind,sp,len,flags,(flags>>24)&255,plausible,q[0],q[1]);
}
static void maybe_expand_line(id owner,const char*ownerClass,const char*s,const char*e,int depth){if(depth>1)return;const char*sv=findn(s,e,"(NSString*): @\"");if(sv){sv+=15;char z[256];size_t zi=0;while(sv<e&&*sv!='\"'&&zi+1<sizeof(z))z[zi++]=*sv++;z[zi]=0;HFAPatchTraceConsiderString(z);HFARegisterPatchString(owner,z);}const char*q=findn(s,e,"): <");if(!q)return;const char*lt=q+4;const char*colon=lt;while(colon<e&&*colon!=':')colon++;if(colon>=e)return;char cn[96];size_t n=(size_t)(colon-lt);if(n>=sizeof(cn))n=sizeof(cn)-1;memcpy(cn,lt,n);cn[n]=0;const char*px=findn(colon,e,"0x");if(!px)return;u64 v=hexptr(px);if(!v)return;id x=(id)(size_t)v;const char*kind=0;if(findn(s,e,"IGSecretInt"))kind="IGSecretInt";else if(findn(s,e,"IGSecretData"))kind="IGSecretData";if(kind){probe_secret_selector(x,cn,kind);HFARegisterPatchSecret(owner,x,kind);}if(findn(s,e,"APColorModifier"))HFARegisterPatchObject(owner,ownerClass);if(strstr(cn,"Array")||strstr(cn,"Dictionary")){dump_collection(x,cn,depth);return;}if(customcn(cn)&&(findn(s,e,"UIBetterScrollView")||findn(s,e,"IGSecretInt")||findn(s,e,"IGSecretData")||findn(s,e,"APColorModifier")||findn(s,e,"APSubpatchManager")))dump_own(x,"NESTED",depth+1);}
static void dump_own(id o,const char*tag,int depth){const char*dsname=(depth==2)?"_methodDescription":"_ivarDescription";if(!o||depth>2||!resp(o,dsname))return;Class c=M0(Class,o,"class");const char*cn=c?class_getName(c):"?";id ds=M0(id,o,dsname);const char*s=ds?(const char*)M0(void*,ds,"UTF8String"):0;if(!s)return;const char*p=strstr(s,"\nin ");if(!p)return;p++;const char*hdrEnd=p;while(*hdrEnd&&*hdrEnd!='\n')hdrEnd++;if(!*hdrEnd)return;p=hdrEnd+1;logf("  [%s-OWN] class=%s ptr=%p depth=%d\n",tag,cn,o,depth);int lines=0;while(*p&&lines<96){const char*e=p;while(*e&&*e!='\n')e++;if(starts(p,"in "))break;size_t n=(size_t)(e-p);if(n){if(n>220)logf("    %.*s ... [lineLen=%llu]\n",180,p,(u64)n);else {logf("    %.*s\n",(int)n,p);maybe_expand_line(o,cn,p,e,depth);}lines++;}if(!*e)break;p=e+1;}}
static id gAutoTargets[256];static unsigned int gAutoTargetCount=0,gAutoControlCount=0;static int gAutoMenuFound=0;
static int auto_seen(id o){for(unsigned int i=0;i<gAutoTargetCount;i++)if(gAutoTargets[i]==o)return 1;return 0;}
static void auto_target(id o){
    if(!o||o==gTarget||auto_seen(o)||gAutoTargetCount>=256)return;
    @try {
        Class c=M0(Class,o,"class");const char*cn=c?class_getName(c):"?";
        if(!customcn(cn)||strstr(cn,".")||!resp(o,"_ivarDescription"))return;
        id ds=M0(id,o,"_ivarDescription");const char*summary=ds?(const char*)M0(void*,ds,"UTF8String"):0;
        if(!summary||(!strstr(summary,"UIBetterScrollView")&&!strstr(summary,"IGSecretInt")&&!strstr(summary,"IGSecretData")))return;
        gAutoTargets[gAutoTargetCount++]=o;
        logf("[AUTO-TARGET-BEGIN] class=%s ptr=%p\n",cn,o);
        dump_own(o,"AUTO-TARGET",0);
        logf("[AUTO-TARGET-END] class=%s ptr=%p\n",cn,o);
        gAutoMenuFound=1;
    } @catch(id exception) {
        logf("[AUTO-TARGET-SKIP] ptr=%p reason=objc-exception\n",o);
    }
}
static void auto_view(id v,int depth){
    if(!v||depth>18||gAutoMenuFound)return;
    if(resp(v,"allTargets")){
        gAutoControlCount++;
        id targets=M0(id,v,"allTargets");id a=targets&&resp(targets,"allObjects")?M0(id,targets,"allObjects"):targets;
        u64 n=a&&resp(a,"count")?M0(u64,a,"count"):0;if(n>32)n=32;
        for(u64 i=0;i<n;i++){id t=M1(id,a,"objectAtIndex:",u64,i);logf("[AUTO-CONTROL-TARGET] ptr=%p\n",t);auto_target(t);if(gAutoMenuFound)return;}
    }
    if(!resp(v,"subviews"))return;
    id a=M0(id,v,"subviews");u64 n=a&&resp(a,"count")?M0(u64,a,"count"):0;if(n>128)n=128;
    for(u64 i=0;i<n;i++){auto_view(M1(id,a,"objectAtIndex:",u64,i),depth+1);if(gAutoMenuFound)return;}
}
static void auto_controller(id vc,int depth){
    if(!vc||depth>8||gAutoMenuFound)return;
    if(resp(vc,"view"))auto_view(M0(id,vc,"view"),0);
    if(gAutoMenuFound)return;
    if(resp(vc,"presentedViewController"))auto_controller(M0(id,vc,"presentedViewController"),depth+1);
    if(gAutoMenuFound)return;
    if(resp(vc,"childViewControllers")){
        id a=M0(id,vc,"childViewControllers");u64 n=a&&resp(a,"count")?M0(u64,a,"count"):0;if(n>32)n=32;
        for(u64 i=0;i<n;i++){auto_controller(M1(id,a,"objectAtIndex:",u64,i),depth+1);if(gAutoMenuFound)return;}
    }
}
static unsigned int run_full_scan(void){
    gAutoTargetCount=0;gAutoControlCount=0;gAutoMenuFound=0;
    Class ac=objc_getClass("UIApplication");id app=ac?M0(id,(id)ac,"sharedApplication"):0;
    logf("[AUTO-STAGE] application=%p\n",app);
    id windows=app&&resp(app,"windows")?M0(id,app,"windows"):0;
    u64 n=windows&&resp(windows,"count")?M0(u64,windows,"count"):0;if(n>32)n=32;
    logf("[AUTO-STAGE] windows=%p count=%llu\n",windows,n);
    for(u64 i=0;i<n;i++){
        id w=M1(id,windows,"objectAtIndex:",u64,i);
        logf("[AUTO-WINDOW] index=%llu ptr=%p\n",i,w);
        if(resp(w,"rootViewController")){id root=M0(id,w,"rootViewController");logf("[AUTO-ROOT] index=%llu ptr=%p\n",i,root);auto_controller(root,0);}
        if(gAutoMenuFound)break;
        auto_view(w,0);
        if(gAutoMenuFound)break;
    }
    logf("[AUTO-TRAVERSAL-END] menuFound=%d controls=%u targets=%u\n",gAutoMenuFound,gAutoControlCount,gAutoTargetCount);
    unsigned int valid=HFAPatchTraceFinalizeScan();
    logf("[AUTO-SCAN] windows=%llu controls=%u targets=%u validMappings=%u\n",n,gAutoControlCount,gAutoTargetCount,valid);
    return valid;
}
static void hooksend(id self,SEL cmd,SEL action,id target,id event){unsigned int ev=0;if(gAttached&&target!=gTarget&&self!=gButton){Class sc=M0(Class,self,"class"),tc=target?M0(Class,target,"class"):0;const char*sn=sc?class_getName(sc):"?",*tn=tc?class_getName(tc):"(nil)";if(!starts(sn,"HFAMap")&&!starts(tn,"HFAMap")){ev=++gEvent;HFAPatchTraceBeginEvent(ev);HFAPatchTraceObserveAction(target,action);const char*ident=objtext(self,"identifier");if(ident&&*ident)HFAPatchTraceSetIdentifier(ident);logf("\n[EVENT %u] sender=%s target=%s action=%s identifier=%s\n",ev,sn,tn,action?sel_getName(action):"?",ident?ident:"?");near_text(self);dump_own(self,"SENDER",0);if(target&&target!=self)dump_own(target,"TARGET",0);logf("[EVENT-END %u]\n",ev);HFAPatchTraceArm(ev);}}if(gOrigSend)((void(*)(id,SEL,SEL,id,id))gOrigSend)(self,cmd,action,target,event);if(ev)HFAPatchTraceFinalizeEvent(ev);}
static void tryhook(void){if(gHooked)return;Class c=objc_getClass("UIControl");if(!c)return;gOrigSend=class_replaceMethod(c,sel_registerName("sendAction:to:forEvent:"),(IMP)hooksend,"v@::@@");if(!gOrigSend)return;gHooked=1;logf("[hook] UIControl sendAction installed orig=%p\n",gOrigSend);}
static id win(void){Class ac=objc_getClass("UIApplication");if(!ac)return 0;id app=M0(id,(id)ac,"sharedApplication");if(!app)return 0;id w=M0(id,app,"keyWindow");if(w)return w;id a=M0(id,app,"windows");if(!a)return 0;u64 n=M0(u64,a,"count");return n?M1(id,a,"objectAtIndex:",u64,n-1):0;}
static id mklabel(CGRect r,double fs){Class lc=objc_getClass("UILabel");if(!lc)return 0;id l=M0(id,(id)lc,"alloc");l=M1(id,l,"initWithFrame:",CGRect,r);M1(void,l,"setTextColor:",id,color(.95,.95,.98,1));M1(void,l,"setNumberOfLines:",long long,0);Class fc=objc_getClass("UIFont");if(fc)M1(void,l,"setFont:",id,M1(id,(id)fc,"systemFontOfSize:",double,fs));return l;}
static void settext(id l,const char*s){if(l)M1(void,l,"setText:",id,ns(s));}
static void attach(id self,SEL c,id sender){(void)self;(void)c;(void)sender;gAttached=1;gFound[0]=0;settext(gStatus,"Scanning the complete menu...");logf("[AUTO] full menu scan started\n");unsigned int valid=run_full_scan();if(valid)settext(gStatus,"Full scan completed.\nMappings saved to HFAMap_Mapping.log");else settext(gStatus,"No Patch descriptors found.\nOpen the game menu and scan again.");}
static void pan(id self,SEL c,id g){(void)self;(void)c;if(!gButton||!gWindow)return;long long st=M0(long long,g,"state");if(st==1||st==2){CGPoint tr=M1(CGPoint,g,"translationInView:",id,gWindow);CGPoint ce=M0(CGPoint,gButton,"center");ce.x+=tr.x;ce.y+=tr.y;CGRect b=M0(CGRect,gWindow,"bounds");double h=26;if(ce.x<h)ce.x=h;if(ce.x>b.size.width-h)ce.x=b.size.width-h;if(ce.y<h)ce.y=h;if(ce.y>b.size.height-h)ce.y=b.size.height-h;M1(void,gButton,"setCenter:",CGPoint,ce);CGPoint z={0,0};M2(void,g,"setTranslation:inView:",CGPoint,z,id,gWindow);}}
static void panelpan(id self,SEL c,id g){(void)self;(void)c;if(!gPanel||!gWindow)return;long long st=M0(long long,g,"state");if(st==1||st==2){CGPoint tr=M1(CGPoint,g,"translationInView:",id,gWindow);CGPoint ce=M0(CGPoint,gPanel,"center");ce.x+=tr.x;ce.y+=tr.y;M1(void,gPanel,"setCenter:",CGPoint,ce);CGPoint z={0,0};M2(void,g,"setTranslation:inView:",CGPoint,z,id,gWindow);}}
static void mkui(id w){if(gMade||!w)return;Class bc=objc_getClass("UIButton"),vc=objc_getClass("UIView");if(!bc||!vc)return;id b=M0(id,(id)bc,"alloc");b=M1(id,b,"initWithFrame:",CGRect,((CGRect){{18,165},{52,52}}));M2(void,b,"setTitle:forState:",id,ns("HF"),u64,0);M1(void,b,"setBackgroundColor:",id,color(.12,.12,.15,.94));id ly=M0(id,b,"layer");if(ly)M1(void,ly,"setCornerRadius:",double,26);M3(void,b,"addTarget:action:forControlEvents:",id,gTarget,SEL,sel_registerName("tap:"),u64,TOUCHUP);Class pc=objc_getClass("UIPanGestureRecognizer");if(pc){id pg=M0(id,(id)pc,"alloc");pg=M2(id,pg,"initWithTarget:action:",id,gTarget,SEL,sel_registerName("pan:"));M1(void,b,"addGestureRecognizer:",id,pg);}M1(void,w,"addSubview:",id,b);gButton=b;
id p=M0(id,(id)vc,"alloc");p=M1(id,p,"initWithFrame:",CGRect,((CGRect){{70,90},{330,250}}));M1(void,p,"setBackgroundColor:",id,color(.055,.06,.075,.97));ly=M0(id,p,"layer");if(ly)M1(void,ly,"setCornerRadius:",double,14);if(pc){id pg=M0(id,(id)pc,"alloc");pg=M2(id,pg,"initWithTarget:action:",id,gTarget,SEL,sel_registerName("panelpan:"));M1(void,pg,"setCancelsTouchesInView:",BOOL,0);M1(void,p,"addGestureRecognizer:",id,pg);}id h=mklabel((CGRect){{14,10},{302,52}},18);settext(h,"HFAMap v1.8.7 Key Register");M1(void,p,"addSubview:",id,h);id a=M0(id,(id)bc,"alloc");a=M1(id,a,"initWithFrame:",CGRect,((CGRect){{14,76},{302,44}}));M2(void,a,"setTitle:forState:",id,ns("Auto Detect / Full Scan"),u64,0);M1(void,a,"setBackgroundColor:",id,color(.18,.32,.62,1));M3(void,a,"addTarget:action:forControlEvents:",id,gTarget,SEL,sel_registerName("attach:"),u64,TOUCHUP);M1(void,p,"addSubview:",id,a);gStatus=mklabel((CGRect){{14,136},{302,94}},11);settext(gStatus,"Key registration is fingerprinted without table guesses.\nOpen the menu, scan, then repeat user recognition.");M1(void,p,"addSubview:",id,gStatus);M1(void,p,"setHidden:",BOOL,1);M1(void,w,"addSubview:",id,p);gPanel=p;gWindow=w;gMade=1;}
static void tick(id self,SEL c,id timer){(void)self;(void)c;(void)timer;tryhook();id w=win();if(!w)return;if(!gMade)mkui(w);if(gMade&&gWindow!=w){M1(void,w,"addSubview:",id,gPanel);M1(void,w,"addSubview:",id,gButton);gWindow=w;}if(gAttached&&gStatus){const char*found=HFAPatchTraceDetectedTarget();if(found&&*found&&!ceq(found,gFound)){copyc(gFound,found,sizeof(gFound));id s=M1(id,ns("Verified target: "),"stringByAppendingString:",id,ns(gFound));s=M1(id,s,"stringByAppendingString:",id,ns("\nGrouped mapping is active."));M1(void,gStatus,"setText:",id,s);}}if(gMade){M1(void,w,"bringSubviewToFront:",id,gPanel);M1(void,w,"bringSubviewToFront:",id,gButton);}}
static void tap(id self,SEL c,id s){(void)self;(void)c;(void)s;if(gPanel){BOOL h=M0(BOOL,gPanel,"isHidden");M1(void,gPanel,"setHidden:",BOOL,!h);}}
__attribute__((constructor)) static void init(void){initlog();Class base=objc_getClass("NSObject");if(!base)return;Class c=objc_allocateClassPair(base,"HFAMapLearningTarget133",0);if(!c)c=objc_getClass("HFAMapLearningTarget133");if(!c)return;class_addMethod(c,sel_registerName("tick:"),(IMP)tick,"v@:@");class_addMethod(c,sel_registerName("tap:"),(IMP)tap,"v@:@");class_addMethod(c,sel_registerName("pan:"),(IMP)pan,"v@:@");class_addMethod(c,sel_registerName("panelpan:"),(IMP)panelpan,"v@:@");class_addMethod(c,sel_registerName("attach:"),(IMP)attach,"v@:@");objc_registerClassPair(c);gTarget=M0(id,(id)c,"new");Class t=objc_getClass("NSTimer");if(t&&gTarget)M5(id,(id)t,"scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:",double,.5,id,gTarget,SEL,sel_registerName("tick:"),id,(id)0,BOOL,1);}
