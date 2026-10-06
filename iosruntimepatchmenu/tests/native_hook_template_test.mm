#import <Foundation/Foundation.h>
#import <assert.h>
#import <limits.h>
#import "ZNNativeHookTemplate.h"

int main(void) {
    @autoreleasepool {
        uint32_t reg = 99;

        assert(ZNNativeHookArgRegisterIndex(NO, 0, 2, &reg));
        assert(reg == 1); // instance: x0=this, arg0=x1
        assert(ZNNativeHookArgRegisterIndex(NO, 1, 2, &reg));
        assert(reg == 2); // FillSP amount -> w2/x2

        assert(ZNNativeHookArgRegisterIndex(YES, 0, 2, &reg));
        assert(reg == 0); // static: arg0=x0
        assert(ZNNativeHookArgRegisterIndex(YES, 1, 2, &reg));
        assert(reg == 1);

        assert(!ZNNativeHookArgRegisterIndex(NO, 8, 9, &reg));
        assert(!ZNNativeHookArgRegisterIndex(NO, 2, 2, &reg));

        assert(ZNNativeHookScaleInt32(10, 5) == 50);
        assert(ZNNativeHookScaleInt32(-10, 5) == -50);
        assert(ZNNativeHookScaleInt32(INT32_MAX, 2) == INT32_MAX);
        assert(ZNNativeHookScaleInt32(INT32_MIN, 2) == INT32_MIN);
        assert(ZNNativeHookScaleInt32(0, 1000) == 0);

        assert([ZNNativeHookTemplateKey(ZNNativeHookTemplateArgScaleInt32)
                isEqualToString:@"arg-scale-int32"]);
        assert([ZNNativeHookTemplateKey(ZNNativeHookTemplateManagedCallbackShortCircuit)
                isEqualToString:@"managed-callback-short-circuit"]);
        assert([ZNNativeHookTemplateKey(ZNNativeHookTemplateReturnBoolOverride)
                isEqualToString:@"return-bool-override"]);
        assert([ZNNativeHookTemplateKey(ZNNativeHookTemplateStructFieldTransform)
                isEqualToString:@"struct-field-transform"]);

        assert(ZNNativeHookScaleInt64(10, 5) == 50);
        assert(ZNNativeHookScaleInt64(-10, 5) == -50);
        assert(ZNNativeHookScaleInt64(INT64_MAX, 2) == INT64_MAX);
        assert(ZNNativeHookScaleInt64(INT64_MIN, 2) == INT64_MIN);
    }
    return 0;
}
