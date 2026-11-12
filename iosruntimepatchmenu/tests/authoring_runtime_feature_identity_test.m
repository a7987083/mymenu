#import <Foundation/Foundation.h>
#import "../src/ZNAuthoringRuntimeFeatureIdentity.h"

static NSDictionary *Record(NSString *itemID, NSString *title) {
    return @{
        @"method": @"SetItemNum",
        @"title": title,
        @"description": @"",
        @"executionKind": @1,
        @"argumentValues": @[itemID,@"99999",@"0"],
        @"argumentControlConfigs": @[
            @{@"enabled":@NO,@"type":@"fixed"},
            @{@"enabled":@YES,@"type":@"number"},
            @{@"enabled":@NO,@"type":@"fixed"}],
        @"immediateChain": @{}
    };
}
static void Verify(BOOL condition, NSString *message) {
    if(!condition) { NSLog(@"FAIL: %@",message); exit(1); }
}
int main(void) {
    @autoreleasepool {
        NSString *method=@"Assembly-CSharp.dll!ItemDataModel::SetItemNum(System.Int32,System.Int64,System.Boolean)";
        NSDictionary *one=ZNAuthoringRuntimeFeatureIdentity(Record(@"1002",@"SetItemNum金币"),method);
        NSDictionary *two=ZNAuthoringRuntimeFeatureIdentity(Record(@"1003",@"SetItemNum"),method);
        NSDictionary *three=ZNAuthoringRuntimeFeatureIdentity(Record(@"1004",@"SetItemNum"),method);
        NSSet *items=[NSSet setWithArray:@[one,two,three]];
        Verify(items.count==3,@"same method with distinct item IDs must remain three features");
        Verify([one isEqual:ZNAuthoringRuntimeFeatureIdentity(Record(@"1002",@"SetItemNum金币"),method)],
               @"identical records must compare equal, including repeat imports");
        Verify(![one isEqual:ZNAuthoringRuntimeFeatureIdentity(Record(@"1002",@"Different title"),method)],
               @"intentional separately titled feature must be distinguishable");
        NSMutableDictionary *direct=[Record(@"1002",@"SetItemNum金币") mutableCopy];
        direct[@"executionKind"]=@3;
        Verify(![one isEqual:ZNAuthoringRuntimeFeatureIdentity(direct,method)],
               @"Runtime Method and Direct Native Call must remain separate");
        NSMutableDictionary *control=[Record(@"1002",@"SetItemNum金币") mutableCopy];
        control[@"argumentControlConfigs"]=@[@{@"enabled":@NO,@"type":@"fixed"},
                                               @{@"enabled":@YES,@"type":@"slider"},
                                               @{@"enabled":@NO,@"type":@"fixed"}];
        Verify(![one isEqual:ZNAuthoringRuntimeFeatureIdentity(control,method)],
               @"different control configuration is a distinct feature");
        Verify(![one isEqual:ZNAuthoringRuntimeFeatureIdentity(Record(@"1002",@"SetItemNum金币"),@"other signature")],
               @"method overload must be distinguishable");
        NSLog(@"PASS: 6 authoring feature identity contracts");
    }
    return 0;
}
