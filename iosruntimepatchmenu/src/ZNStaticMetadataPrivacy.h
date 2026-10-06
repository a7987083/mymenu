#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Removes human-readable feature title/group strings from the V3-owned
// __ZNDATA metadata before CodeDirectory regeneration. Runtime dispatch fields
// and the fixed 128-byte ABI remain unchanged.
FOUNDATION_EXPORT BOOL ZNScrubStaticDisplayMetadataAtPath(NSString *path,
                                                          NSUInteger * _Nullable scrubbedEntries,
                                                          NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
