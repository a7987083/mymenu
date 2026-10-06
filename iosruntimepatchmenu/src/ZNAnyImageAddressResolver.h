#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Installs the runtime address-normalization layer used by Patch validation.
// Bare input is auto-detected; explicit qualifiers are also accepted:
//   rva:0x..., va:0x... / preferred:0x..., runtime:0x..., file:0x...
// The normalized value passed to the existing validator is always an RVA.
FOUNDATION_EXPORT void ZNInstallAnyImageAddressResolverDeferred(void);

NS_ASSUME_NONNULL_END
