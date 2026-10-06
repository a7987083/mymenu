#import <Foundation/Foundation.h>
#import "ZNIL2CPPResolver.h"
#include <assert.h>
#include <stdio.h>

static NSDictionary *Parse(NSString *text) {
    NSString *error = nil;
    NSDictionary *result = [ZNIL2CPPResolver parseNamedOffsetExpression:text error:&error];
    if (!result) {
        fprintf(stderr, "parse failed for %s: %s\n", text.UTF8String, error.UTF8String);
        abort();
    }
    return result;
}

int main(void) {
    @autoreleasepool {
        NSDictionary *a = Parse(@"GetMoney");
        assert([a[@"method"] isEqualToString:@"GetMoney"]);
        assert(![a[@"argumentSpecified"] boolValue]);
        assert([a[@"delta"] longLongValue] == 0);
        assert([a[@"class"] length] == 0);
        assert([a[@"assembly"] length] == 0);

        NSDictionary *b = Parse(@"GetMoney/0");
        assert([b[@"method"] isEqualToString:@"GetMoney"]);
        assert([b[@"argumentSpecified"] boolValue]);
        assert([b[@"argumentCount"] integerValue] == 0);

        NSDictionary *c = Parse(@"PlayerData::GetMoney/2");
        assert([c[@"class"] isEqualToString:@"PlayerData"]);
        assert([c[@"namespace"] length] == 0);
        assert(![c[@"namespaceSpecified"] boolValue]);
        assert([c[@"argumentCount"] integerValue] == 2);

        NSDictionary *d = Parse(@"Game.PlayerData::GetMoney/1");
        assert([d[@"namespace"] isEqualToString:@"Game"]);
        assert([d[@"class"] isEqualToString:@"PlayerData"]);
        assert([d[@"namespaceSpecified"] boolValue]);

        NSDictionary *e = Parse(@"Assembly-CSharp.dll!Game.PlayerData::GetMoney/0+0x10");
        assert([e[@"assembly"] isEqualToString:@"Assembly-CSharp.dll"]);
        assert([e[@"namespace"] isEqualToString:@"Game"]);
        assert([e[@"class"] isEqualToString:@"PlayerData"]);
        assert([e[@"method"] isEqualToString:@"GetMoney"]);
        assert([e[@"argumentCount"] integerValue] == 0);
        assert([e[@"delta"] longLongValue] == 0x10);

        NSDictionary *f = Parse(@"Assembly-CSharp!PlayerData::GetMoney/0-16");
        assert([f[@"delta"] longLongValue] == -16);

        NSString *error = nil;
        assert([ZNIL2CPPResolver parseNamedOffsetExpression:@"" error:&error] == nil);
        assert(error.length > 0);
        error = nil;
        assert([ZNIL2CPPResolver parseNamedOffsetExpression:@"Assembly-CSharp!" error:&error] == nil);
        assert(error.length > 0);
        error = nil;
        assert([ZNIL2CPPResolver parseNamedOffsetExpression:@"PlayerData::" error:&error] == nil);
        assert(error.length > 0);

        puts("il2cpp_named_offset_parser_test: PASS");
    }
    return 0;
}
