// NFBExtras: a tiny add-on for NeoFreeBird, injected next to it when signing.
//
// 1. NeoFreeBird already hides X's "What's happening?" quick-compose bar when its
//    `hide_quick_compose` setting is on, but its settings screen has no switch for it.
//    This turns that setting on at launch.
// 2. With Liquid Glass, X's compose "+" is XNavigation.TabBarAccessoryButtonView, which
//    NeoFreeBird's "Hide Tweet button" (TFNFloatingActionButton) doesn't reach. This keeps
//    that button, and a glass bubble that holds only it, hidden.
// 3. The Liquid Glass tab bar shrinks while scrolling (UITabBarController.tabBarMinimizeBehavior). This
//    keeps it expanded: every tab bar controller is set to "never" and stays there.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

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

// UITabBarMinimizeBehavior: automatic 0, never 1, onScrollDown 2, onScrollUp 3 (iOS 26).
static const NSInteger kNever = 1;
static SEL setMinimize;

static void NFBNeverMinimize(id controller) {
    if ([controller respondsToSelector:setMinimize]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(controller, setMinimize, kNever);
    }
}

static void NFBHookTabBar(void) {
    Class cls = [UITabBarController class];
    setMinimize = NSSelectorFromString(@"setTabBarMinimizeBehavior:");
    // Whatever X asks for, the bar never minimises.
    Method set = class_getInstanceMethod(cls, setMinimize);
    if (set) {
        IMP original = method_getImplementation(set);
        method_setImplementation(set, imp_implementationWithBlock(^(id self, NSInteger behavior) {
            ((void (*)(id, SEL, NSInteger))original)(self, setMinimize, kNever);
        }));
    }
    // And the ones that never ask get it when they appear.
    SEL appear = @selector(viewWillAppear:);
    Method m = class_getInstanceMethod(cls, appear);
    if (m) {
        IMP original = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(id self, BOOL animated) {
            ((void (*)(id, SEL, BOOL))original)(self, appear, animated);
            NFBNeverMinimize(self);
        }));
    }
}

// 4. X's own navigation (XNAVNavigationController) collapses its bars as a list scrolls, following each
//    screen's XNAVConfiguration (the iOS tab bar setting above does not reach it). X has a pinned
//    configuration whose bars never collapse: every screen gets it (method found by LiquidBird, Tiling.x).
static id NFBPinned(id self, SEL _cmd) {
    Class configuration = objc_getClass("XNAVConfiguration");
    return ((id (*)(id, SEL))objc_msgSend)(configuration, sel_registerName("pinnedConfiguration"));
}

static BOOL pinnedDone = NO;
static void NFBPinBars(void) {
    if (pinnedDone) return;
    Class configuration = objc_getClass("XNAVConfiguration");
    SEL pinned = sel_registerName("pinnedConfiguration");
    if (!configuration || !class_getClassMethod(configuration, pinned)) return;
    pinnedDone = YES;
    // The standard (collapsing) configuration answers with the pinned one wherever X asks for it.
    Method standard = class_getClassMethod(configuration, sel_registerName("standardConfiguration"));
    if (standard) method_setImplementation(standard, (IMP)NFBPinned);
    // Screens that do not provide a configuration get the collapsing default: give the main ones the pinned one.
    Protocol *providing = objc_getProtocol("XNAVConfigurationProviding");
    SEL answer = sel_registerName("xnav_navigationConfiguration");
    for (NSString *name in @[@"_TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController",
                             @"T1ConversationContainerViewController"]) {
        Class screen = objc_getClass(name.UTF8String);
        if (!screen) continue;
        Method m = class_getInstanceMethod(screen, answer);
        if (m) method_setImplementation(m, (IMP)NFBPinned);
        else {
            class_addMethod(screen, answer, (IMP)NFBPinned, "@@:");
            if (providing) class_addProtocol(screen, providing);
        }
    }
}

// 5. What actually collapses X's bars (found in XServiceLibraries): XNavigation.CollapseEngine.ScrollObserver,
//    whose handlePan: follows the list's pan and collapses the navigation bar and the tab bar pill. It does
//    nothing now, so the bars stay as they are while scrolling.
static BOOL collapseDone = NO;
static void NFBStopCollapse(void) {
    if (collapseDone) return;
    Class observer = objc_getClass("_TtCC11XNavigation14CollapseEngine14ScrollObserver");
    Method pan = observer ? class_getInstanceMethod(observer, sel_registerName("handlePan:")) : NULL;
    if (!pan) return;
    collapseDone = YES;
    method_setImplementation(pan, imp_implementationWithBlock(^(id self, id gesture) {}));
}

// 6. X's bars follow the scroll view each screen reports through xnav_contentScrollView (TFNDataViewController
//    for every timeline, and a few others). Reporting none leaves nothing for the collapse to follow, so the
//    tab bar pill and the top bar stay as they are. Classes found in T1Twitter and XServiceLibraries (12.39).
static BOOL unfollowDone = NO;
static void NFBStopFollowing(void) {
    if (unfollowDone) return;
    SEL ask = sel_registerName("xnav_contentScrollView");
    NSArray *names = @[@"TFNDataViewController", @"T1TweetComposeViewController", @"T1ProfileSegmentedFollowingViewController",
                       @"T1StandardSpaceViewController", @"T1MuteListTabViewController", @"T1BlockListTabViewController",
                       @"T1WebViewController", @"T1TaggingViewController", @"T1LegacyResizableHeaderContainerViewController",
                       @"_TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController",
                       @"T1ConversationContainerViewController"];
    BOOL any = NO;
    for (NSString *name in names) {
        Class cls = objc_getClass(name.UTF8String);
        Method m = cls ? class_getInstanceMethod(cls, ask) : NULL;
        if (!m) continue;
        method_setImplementation(m, imp_implementationWithBlock(^id(id self) { return nil; }));
        any = YES;
    }
    if (any) unfollowDone = YES;
}

__attribute__((constructor)) static void NFBExtrasInit(void) {
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hide_quick_compose"];
        NFBHookCompose();
        NFBHookTabBar();
        NFBPinBars();
        NFBStopCollapse();
        NFBStopFollowing();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ NFBStopFollowing(); });
        dispatch_async(dispatch_get_main_queue(), ^{ NFBStopCollapse(); });
        // X's frameworks may finish loading after this dylib: try again once the app is up.
        dispatch_async(dispatch_get_main_queue(), ^{ NFBPinBars(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ NFBPinBars(); });
        if (!NSClassFromString(kComposeClass)) {
            // The XNavigation framework may load after this dylib: try again once the app is up.
            dispatch_async(dispatch_get_main_queue(), ^{ NFBHookCompose(); });
        }
    }
}
