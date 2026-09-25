#import <UIKit/UIKit.h>
#import <os/log.h>

#if !TARGET_OS_SIMULATOR
#error This controlled-host probe must never be built for a physical device.
#endif

static UITextView *FocusedEditor(UIView *view) {
    if ([view isKindOfClass:UITextView.class] && view.isFirstResponder) return (UITextView *)view;
    for (UIView *child in view.subviews) {
        UITextView *result = FocusedEditor(child);
        if (result) return result;
    }
    return nil;
}

// Isolate the host's public reload behavior. This cannot serve as an extension
// workaround: it deliberately runs inside our own test host, which owns the editor.
__attribute__((constructor)) static void InstallHostReloadProbe(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        __block NSUInteger attempts = 0;
        __block BOOL pending = NO;
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidChangeFrameNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                CGFloat height = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue].size.height;
                if (pending || attempts >= 3 || fabs(height - 299) > 0.5) return;
                pending = YES;
                attempts += 1;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                        if (![scene isKindOfClass:UIWindowScene.class]) continue;
                        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                            UITextView *editor = FocusedEditor(window);
                            if (!editor) continue;
                            NSString *original = editor.text;
                            NSRange selection = editor.selectedRange;
                            os_log(OS_LOG_DEFAULT, "MARGIN-HOST-RELOAD invoking on focused editor");
                            [editor reloadInputViews];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                                pending = NO;
                                os_log(OS_LOG_DEFAULT, "MARGIN-HOST-RELOAD textPreserved=%d selectionPreserved=%d focused=%d",
                                    [editor.text isEqualToString:original], NSEqualRanges(editor.selectedRange, selection), editor.isFirstResponder);
                            });
                            return;
                        }
                    }
                    os_log(OS_LOG_DEFAULT, "MARGIN-HOST-RELOAD no focused editor");
                    pending = NO;
                });
            }];
    });
}
