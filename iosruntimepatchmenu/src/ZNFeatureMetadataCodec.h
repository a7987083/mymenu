#import <Foundation/Foundation.h>
#import "ZNStaticPatchFormat.h"

NS_ASSUME_NONNULL_BEGIN

// Privacy-preserving Feature metadata stored inside the existing 72-byte
// title+group area of ZN44StaticEntry. The on-disk representation keeps both
// title[0] and group[0] zero, so legacy readers fall back instead of treating
// encoded bytes as a C string.
//
// This is an obfuscation/transport codec, not cryptographic protection. Its
// purpose is to keep human-readable Feature names out of normal Mach-O strings
// while making the names survive IPA re-sign/reinstall without NSUserDefaults.

FOUNDATION_EXPORT BOOL ZNFeatureMetadataEncodeEntry(ZN44StaticEntry *entry,
                                                     NSString *target,
                                                     NSString *title,
                                                     NSString *group);

FOUNDATION_EXPORT NSDictionary<NSString *, id> * _Nullable
ZNFeatureMetadataDecodeEntry(const ZN44StaticEntry *entry);

NS_ASSUME_NONNULL_END
