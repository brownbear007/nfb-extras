// NFBExtras: a tiny add-on for NeoFreeBird, injected next to it when signing.
//
// 1. NeoFreeBird already hides X's "What's happening?" quick-compose bar when its
//    `hide_quick_compose` setting is on, but its settings screen has no switch for it.
//    This turns that setting on at launch.
// 2. With Liquid Glass, X's compose "+" is XNavigation.TabBarAccessoryButtonView, which
//    NeoFreeBird's "Hide Tweet button" (TFNFloatingActionButton) doesn't reach. This keeps
//    that button, and a glass bubble that holds only it, hidden.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kComposeClass = @"_TtC11XNavigation25TabBarAccessoryButtonView";

static void NFBHide(UIView *view) {
    view.hidden = YES;
    view.alpha = 0;
    view.userInteractionEnabled = NO;
    // The glass bubble around the button: a parent about the button's own size, holding nothing else.
    UIView *parent = view.superview;
    if (parent && fabs(parent.bounds.size.width - view.bounds.size.width) < 12 &&
        fabs(parent.bounds.size.height - view.bounds.size.height) < 12) {
        parent.hidden = YES;
        parent.alpha = 0;
        parent.userInteractionEnabled = NO;
    }
}

static void NFBSwizzleHide(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP original = method_getImplementation(m);
    IMP replacement = imp_implementationWithBlock(^(UIView *self) {
        ((void (*)(id, SEL))original)(self, sel);
        NFBHide(self);
    });
    // Only replace the class's own method (add it if inherited), never UIView's for every view.
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m))) {
        method_setImplementation(m, replacement);
    }
}

static void NFBHookCompose(void) {
    Class cls = NSClassFromString(kComposeClass);
    if (!cls) return;
    NFBSwizzleHide(cls, @selector(didMoveToWindow));
    NFBSwizzleHide(cls, @selector(layoutSubviews));
}

__attribute__((constructor)) static void NFBExtrasInit(void) {
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hide_quick_compose"];
        NFBHookCompose();
        if (!NSClassFromString(kComposeClass)) {
            // The XNavigation framework may load after this dylib: try again once the app is up.
            dispatch_async(dispatch_get_main_queue(), ^{ NFBHookCompose(); });
        }
    }
}
