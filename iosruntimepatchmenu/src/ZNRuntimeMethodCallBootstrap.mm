#import <Foundation/Foundation.h>
#import "ZNRuntimeActionRuntime.h"
#import "ZNRuntimeCapabilityCoordinator.h"
#import "ZNPatchCore.h"

extern "C" void ZNInstallRuntimeMethodCallFinderUIDeferred(void);
extern "C" void ZNInstallRuntimeMethodCallBuilderUIDeferred(void);
extern "C" void ZNInstallMethodFinderM42UIDeferred(void);

extern "C" void ZNInstallRuntimeMethodCallDeferred(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Finder + Builder authoring remain part of the Runtime Method backend.
        ZNInstallRuntimeMethodCallFinderUIDeferred();
        ZNInstallRuntimeMethodCallBuilderUIDeferred();

        // M5.7 intentionally does NOT install the historical
        // ZNRuntimeMethodCallFeatureUI. That older layer appended a second
        // customer-facing "method + Execute" card before M5.1 rendered the
        // typed Runtime control card, leaving two public Runtime action UIs.
        // M5.1 + M5.7 are now the single customer Runtime surface.
        ZNInstallMethodFinderM42UIDeferred();
        [[ZNRuntimeCapabilityCoordinator sharedCoordinator] start];
        [[ZNRuntimeCapabilityCoordinator sharedCoordinator] requestRefresh];
        [[ZNRuntimeLogger sharedLogger] log:@"[runtime-method-call] M6.8.5 backend installed: discovery delegated to RuntimeCapabilityCoordinator"];
    });
}
