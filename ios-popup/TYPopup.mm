#import "TYPopup.h"
#import <UIKit/UIKit.h>

static void TY_ShowInternal(NSString *title, NSString *message)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
        if (!root) return;

        while (root.presentedViewController)
            root = root.presentedViewController;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [root presentViewController:alert animated:YES completion:nil];
    });
}

void TY_ShowPopup(const char *title, const char *message)
{
    NSString *t = title ? [NSString stringWithUTF8String:title] : @"Popup";
    NSString *m = message ? [NSString stringWithUTF8String:message] : @"";
    TY_ShowInternal(t, m);
}

void TY_ShowConfirm(const char *title, const char *message)
{
    TY_ShowPopup(title, message);
}
