#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Rehosts the existing menu panel without changing its visual tree. The
// floating button remains a UIWindow overlay; the menu itself is presented by
// UIKit as UIModalPresentationOverFullScreen.
FOUNDATION_EXPORT void ZNInstallRuntimeMenuModalShellDeferred(void);

NS_ASSUME_NONNULL_END
