#import <Foundation/Foundation.h>
#import "../src/ZNBuildRouterShadow.h"

static void Expect(const char *name,
                   NSUInteger completeStatic,
                   NSUInteger partialStatic,
                   NSUInteger runtimeCount,
                   NSUInteger nativeHookCount,
                   ZNShadowBuildMode expected) {
    ZNShadowBuildMode actual=ZNShadowBuildModeForCounts(completeStatic,
                                                        partialStatic,
                                                        runtimeCount,
                                                        nativeHookCount);
    if(actual!=expected){
        fprintf(stderr,"%s failed: expected=%lu actual=%lu\n",
                name,(unsigned long)expected,(unsigned long)actual);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Expect("static-only",1,0,0,0,ZNShadowBuildModeStaticOnly);
        Expect("runtime-only",0,0,1,0,ZNShadowBuildModeRuntimeOnly);
        Expect("native-hook-only",0,0,0,3,ZNShadowBuildModeRuntimeOnly);
        Expect("mixed",2,0,1,2,ZNShadowBuildModeMixed);
        Expect("runtime-with-partial-static-draft",0,2,0,1,ZNShadowBuildModeRuntimeOnly);
        Expect("partial-static-only",0,1,0,0,ZNShadowBuildModeInvalid);
        Expect("empty",0,0,0,0,ZNShadowBuildModeEmpty);
        puts("shadow build router cases: OK");
    }
    return 0;
}
