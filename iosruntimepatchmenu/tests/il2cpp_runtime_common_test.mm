#import <Foundation/Foundation.h>
#import <assert.h>
#import "ZNIL2CPPRuntimeCommon.h"

static void AssertEqual(NSString *actual, NSString *expected) {
    assert((actual == expected) || [actual isEqualToString:expected]);
}

int main(void) {
    @autoreleasepool {
        AssertEqual(ZNIL2CPPTrim(nil), @"");
        AssertEqual(ZNIL2CPPTrim(@"  Foo.Bar  \n"), @"Foo.Bar");

        AssertEqual(ZNIL2CPPNormalizedAssembly(@" Assembly-CSharp.dll "),
                    @"assembly-csharp");
        AssertEqual(ZNIL2CPPNormalizedAssembly(@"UNITYENGINE.COREMODULE.DLL"),
                    @"unityengine.coremodule");
        AssertEqual(ZNIL2CPPNormalizedAssembly(@"GameAssembly"),
                    @"gameassembly");

        AssertEqual(ZNIL2CPPInstanceKey(@" Assembly-CSharp.dll ",
                                        @"  Game.Player ",
                                        @" MotionComponent "),
                    @"assembly-csharp|Game.Player|MotionComponent");

        // Preserve the two historical edge semantics exactly:
        // M4.4 stripped a bare ".dll"; M4.6.2 kept it because it required name.length > 4.
        AssertEqual(ZNIL2CPPInstanceKey(@".dll", @"", @""), @"||");
        AssertEqual(ZNIL2CPPConservativeInstanceKey(@".dll", @"", @""), @".dll||");

        void *mallocSymbol = ZNIL2CPPResolveSymbol(@"", "malloc");
        assert(mallocSymbol != NULL);

        void *missing = ZNIL2CPPResolveSymbol(@"", "zonoe_symbol_that_must_not_exist_6a955c5");
        assert(missing == NULL);

        void *nullName = ZNIL2CPPResolveSymbol(@"", NULL);
        assert(nullName == NULL);
    }
    return 0;
}
