#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <os/log.h>

#if !TARGET_OS_SIMULATOR
#error This runtime-inspection probe must never be built for a physical device.
#endif

// Research only, included solely by generate-margin-probe.py --variant host-trace.
// Observe UIKit's existing layout state in our own test host. No system state is
// changed, and no text is read. These selectors are NOT production API contracts.
static void RecordMarginState(NSNotification *note) {
    Class impl = NSClassFromString(@"UIKeyboardImpl");
    SEL activeSelector = NSSelectorFromString(@"activeInstance");
    SEL layoutSelector = NSSelectorFromString(@"_layout");
    SEL paddingSelector = NSSelectorFromString(@"keyplanePadding");
    SEL additionalSelector = NSSelectorFromString(@"additionalTopPaddingForRoundedKeyboard");
    if (![impl respondsToSelector:activeSelector] || ![impl respondsToSelector:additionalSelector]) return;
    id active = ((id (*)(id, SEL))objc_msgSend)(impl, activeSelector);
    id layout = [active respondsToSelector:layoutSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(active, layoutSelector) : nil;
    if (![layout respondsToSelector:paddingSelector]) {
        os_log(OS_LOG_DEFAULT, "MARGIN-HOST no active keyplane");
        return;
    }
    UIEdgeInsets padding = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(layout, paddingSelector);
    CGFloat additional = ((CGFloat (*)(id, SEL))objc_msgSend)(impl, additionalSelector);
    CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    os_log(OS_LOG_DEFAULT, "MARGIN-HOST layout=%{public}@ keyplaneTop=%g additional=%g hostHeight=%g",
           NSStringFromClass([layout class]), padding.top, additional, frame.size.height);
}

__attribute__((constructor)) static void InstallMarginTrace(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidChangeFrameNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                RecordMarginState(note);
            }];
    });
}
