#import <Foundation/Foundation.h>
#import "ZNIL2CPPABIMetadata.h"

static void Expect(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        Expect(ZNIL2CPPABIKindForManagedTypeName(@"System.Void") == ZNIL2CPPABIValueKindVoid, @"void");
        Expect(ZNIL2CPPABIKindForManagedTypeName(@"System.Boolean") == ZNIL2CPPABIValueKindBool, @"bool");
        Expect(ZNIL2CPPABIKindForManagedTypeName(@"System.Int32") == ZNIL2CPPABIValueKindSigned32, @"int32");
        Expect(ZNIL2CPPABIKindForManagedTypeName(@"System.UInt32") == ZNIL2CPPABIValueKindUnsigned32, @"uint32");
        Expect(ZNIL2CPPABIKindForManagedTypeName(@"System.Int64") == ZNIL2CPPABIValueKindSigned64, @"int64");
        Expect(ZNIL2CPPABIKindForManagedTypeName(@"System.UInt64") == ZNIL2CPPABIValueKindUnsigned64, @"uint64");
        Expect(ZNIL2CPPABIKindForManagedTypeName(@"System.Single") == ZNIL2CPPABIValueKindFloat32, @"float");
        Expect(ZNIL2CPPABIKindForManagedTypeName(@"System.Double") == ZNIL2CPPABIValueKindFloat64, @"double");
        Expect(ZNIL2CPPABIKindForManagedTypeName(@"System.IntPtr") == ZNIL2CPPABIValueKindPointer, @"intptr");
        Expect(ZNIL2CPPABIKindForManagedTypeName(@"com.game.CustomStruct") == ZNIL2CPPABIValueKindUnknown, @"custom type stays runtime-classified");
        NSLog(@"il2cpp_abi_classifier_test: PASS");
    }
    return 0;
}
