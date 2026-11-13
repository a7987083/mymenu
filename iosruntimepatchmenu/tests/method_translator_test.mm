#import <Foundation/Foundation.h>
#import "../src/ZNMethodTranslator.h"

// Developer-only Foundation smoke test: translation changes labels, not IL2CPP IDs.
static BOOL expect(NSString *name,NSString *expected) {
    NSString *actual=[ZNMethodTranslator translateMethodName:name];
    if(![actual isEqualToString:expected]) {
        NSLog(@"P4 FAIL %@: got %@, expected %@",name,actual?:@"<nil>",expected);
        return NO;
    }
    return YES;
}
int main(void) {
    @autoreleasepool {
        NSDictionary<NSString *,NSString *> *cases=@{
            @"set_LoginSdkName":@"设置登录 SDK 名称",
            @"add_coin":@"增加金币",
            @"addcoin":@"增加金币",
            @"AddCoin":@"增加金币",
            @"addCoinGem":@"增加金币和宝石",
            @"addcoingem":@"增加金币和宝石",
            @"AddDiamond":@"增加钻石",
            @"getplayerlevel":@"获取玩家等级",
            @"BuyWeeklyPass":@"购买周卡"
        };
        for(NSString *name in cases)
            if(!expect(name,cases[name]))return 1;
        if([ZNMethodTranslator translateMethodName:@"zzzznotaword"]!=nil){
            NSLog(@"P4 FAIL: unrecognized method should not invent semantics");
            return 2;
        }
        NSLog(@"P4 PASS: %lu representative names, fail-closed unknowns", (unsigned long)cases.count);
    }
    return 0;
}
