#import <Foundation/Foundation.h>
#import "ZNFeatureMetadataCodec.h"
#include <assert.h>
#include <string.h>

static BOOL RawContains(const ZN44StaticEntry *entry, NSString *needle) {
    NSData *raw = [NSData dataWithBytes:entry->title length:sizeof(entry->title) + sizeof(entry->group)];
    NSData *plain = [needle dataUsingEncoding:NSUTF8StringEncoding];
    if (!plain.length || raw.length < plain.length) return NO;
    const uint8_t *r = (const uint8_t *)raw.bytes;
    const uint8_t *p = (const uint8_t *)plain.bytes;
    for (NSUInteger i = 0; i + plain.length <= raw.length; i++) {
        if (memcmp(r + i, p, plain.length) == 0) return YES;
    }
    return NO;
}

int main(void) {
    @autoreleasepool {
        ZN44StaticEntry a = {};
        a.patchID = 1;
        a.siteRVA = 0x1000;
        assert(ZNFeatureMetadataEncodeEntry(&a, @"UnityFramework", @"Patch #1", @"Unlimited Cash"));
        NSDictionary *da = ZNFeatureMetadataDecodeEntry(&a);
        assert(da);
        assert([da[@"title"] isEqualToString:@"Unlimited Cash"]);
        assert([da[@"explicitGroup"] boolValue]);
        assert([da[@"featureID"] unsignedLongLongValue] != 0);
        assert(a.title[0] == 0);
        assert(a.group[0] == 0);
        assert(!RawContains(&a, @"Unlimited Cash"));

        // Same explicit Feature name must remain one identity even when Patch
        // order/RVA/target differ.
        ZN44StaticEntry b = {};
        b.patchID = 9;
        b.siteRVA = 0xABCDEF;
        assert(ZNFeatureMetadataEncodeEntry(&b, @"OtherFramework", @"Patch #9", @"Unlimited Cash"));
        NSDictionary *db = ZNFeatureMetadataDecodeEntry(&b);
        assert([[da objectForKey:@"featureID"] unsignedLongLongValue] ==
               [[db objectForKey:@"featureID"] unsignedLongLongValue]);

        // Legacy/no-group rows intentionally stay independent even if their
        // display labels happen to be equal.
        ZN44StaticEntry c = {};
        c.patchID = 1;
        c.siteRVA = 0x2000;
        assert(ZNFeatureMetadataEncodeEntry(&c, @"UnityFramework", @"Legacy Toggle", @"Imported"));
        NSDictionary *dc = ZNFeatureMetadataDecodeEntry(&c);

        ZN44StaticEntry d = {};
        d.patchID = 2;
        d.siteRVA = 0x3000;
        assert(ZNFeatureMetadataEncodeEntry(&d, @"UnityFramework", @"Legacy Toggle", @"Imported"));
        NSDictionary *dd = ZNFeatureMetadataDecodeEntry(&d);
        assert([[dc objectForKey:@"featureID"] unsignedLongLongValue] !=
               [[dd objectForKey:@"featureID"] unsignedLongLongValue]);

        // UTF-8 survives encoding/decoding and still does not appear verbatim.
        ZN44StaticEntry e = {};
        e.patchID = 3;
        e.siteRVA = 0x4000;
        assert(ZNFeatureMetadataEncodeEntry(&e, @"UnityFramework", @"Patch #3", @"无限金币"));
        NSDictionary *de = ZNFeatureMetadataDecodeEntry(&e);
        assert([de[@"title"] isEqualToString:@"无限金币"]);
        assert(!RawContains(&e, @"无限金币"));

        printf("feature metadata codec tests passed\n");
    }
    return 0;
}
