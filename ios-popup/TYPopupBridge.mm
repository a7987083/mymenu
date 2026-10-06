#import "TYPopupBridge.h"
#import <UIKit/UIKit.h>

static UIViewController *TY_FindController(void)
{
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            window = ((UIWindowScene *)scene).windows.firstObject;
            break;
        }
    }
    if (!window) window = UIApplication.sharedApplication.keyWindow;
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void TY_Present(NSString *title, NSString *msg, BOOL confirm)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = TY_FindController();
        if (!vc) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        if (confirm) {
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        }
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

void TY_ShowPopup(const char *title, const char *message)
{
    TY_Present([NSString stringWithUTF8String:title ?: ""], [NSString stringWithUTF8String:message ?: ""], NO);
}

void TY_ShowConfirm(const char *title, const char *message)
{
    TY_Present([NSString stringWithUTF8String:title ?: ""], [NSString stringWithUTF8String:message ?: ""], YES);
}
