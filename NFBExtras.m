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
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>

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


// 7. The real switch (12.39): a screen opts into the shrinking tab bar by answering YES to
//    tfn_supportsTabBarCollapsing (the Home timeline does), and T1TabBarViewController then follows the
//    scroll through setTabBarCollapseRatio:. Every class that answers now says NO, and the ratio stays 0.
static BOOL NFBNo(id self, SEL _cmd) { return NO; }

static void NFBNoTabBarCollapse(void) {
    SEL supports = sel_registerName("tfn_supportsTabBarCollapsing");
    // The only implementations in 12.39: Home (YES), TFNNavigationController (asks its screen) and the
    // UIViewController default (NO).
    for (NSString *name in @[@"_TtC32TwitterHomeFeatureImplementation35HomeTimelineContainerViewController",
                             @"TFNNavigationController", @"UIViewController"]) {
        Class cls = objc_getClass(name.UTF8String);
        Method m = cls ? class_getInstanceMethod(cls, supports) : NULL;
        if (m) method_setImplementation(m, (IMP)NFBNo);
    }
}

static BOOL ratioDone = NO;
static void NFBNoCollapseRatio(void) {
    if (ratioDone) return;
    Class bar = objc_getClass("T1TabBarViewController");
    SEL set = sel_registerName("setTabBarCollapseRatio:");
    Method m = bar ? class_getInstanceMethod(bar, set) : NULL;
    if (!m) return;
    ratioDone = YES;
    IMP original = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self, CGFloat ratio) {
        ((void (*)(id, SEL, CGFloat))original)(self, set, 0);
    }));
}


// 8. What really moves X's bars (12.39): XNavigation's CollapseEngine reads the list's contentOffset on every
//    display-link frame (XServiceLibraries 0x228c328 and 0x228c690) and collapses the tab bar pill and the top
//    bar as it changes. Those two reads, and only those, now see the list at its top, so the engine keeps
//    the bars expanded. Everything else (the list itself, the pop gesture) gets the real offset. The sites
//    are tied to this exact build: nothing happens unless XServiceLibraries' UUID matches.
static const uint8_t kXSLUUID[16] = {0x9a,0xb7,0x91,0x43,0x6a,0x95,0x39,0xc5,0xb9,0x67,0x34,0x2a,0x90,0x91,0x0b,0x56};
static uintptr_t engineRead1, engineRead2;
static IMP originalOffset;
static volatile long engineHits, offsetCalls;
static uintptr_t xslBase;
static int xslState; // 0 not loaded yet, 1 other build, 2 hooked
static IMP originalTableOffset;
static volatile long tableHits;
static uintptr_t lastCallers[4];

static CGPoint NFBContentOffset(UIScrollView *self, SEL _cmd) {
    CGPoint offset = ((CGPoint (*)(id, SEL))originalOffset)(self, _cmd);
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    offsetCalls++;
    if (caller == engineRead1 || caller == engineRead2) {
        engineHits++;
        offset.y = -self.adjustedContentInset.top;
    } else if (caller - xslBase < 0x424c000 && caller != lastCallers[0] && caller != lastCallers[1] &&
               caller != lastCallers[2] && caller != lastCallers[3]) {
        // contentOffset readers inside XServiceLibraries, to find the engine if its sites differ.
        static int next;
        lastCallers[next++ & 3] = caller;
    }
    return offset;
}

// X's timelines are TFNTableViews, which override contentOffset (and call UIScrollView's): the engine's
// read lands here first, so this is where its call site shows.
static CGPoint NFBTableContentOffset(UIScrollView *self, SEL _cmd) {
    CGPoint offset = ((CGPoint (*)(id, SEL))originalTableOffset)(self, _cmd);
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    if (caller == engineRead1 || caller == engineRead2) {
        tableHits++;
        offset.y = -self.adjustedContentInset.top;
    }
    return offset;
}

static const struct mach_header_64 *NFBImage(const char *suffix) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        size_t n = strlen(name), m = strlen(suffix);
        if (n >= m && strcmp(name + n - m, suffix) == 0) return (const struct mach_header_64 *)_dyld_get_image_header(i);
    }
    return NULL;
}

static BOOL NFBHasUUID(const struct mach_header_64 *header, const uint8_t *uuid) {
    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_UUID) return memcmp(((const struct uuid_command *)command)->uuid, uuid, 16) == 0;
        cursor += command->cmdsize;
    }
    return NO;
}

static BOOL offsetDone = NO;
static void NFBFreezeEngineOffset(void) {
    if (offsetDone) return;
    const struct mach_header_64 *xsl = NFBImage("/XServiceLibraries.framework/XServiceLibraries");
    if (!xsl) return;
    offsetDone = YES;
    xslBase = (uintptr_t)xsl;
    if (!NFBHasUUID(xsl, kXSLUUID)) { xslState = 1; return; }
    xslState = 2;
    // __TEXT starts at 0 in this build, so an address in the file is the header plus that address.
    engineRead1 = (uintptr_t)xsl + 0x228c328 + 4;
    engineRead2 = (uintptr_t)xsl + 0x228c690 + 4;
    Method m = class_getInstanceMethod([UIScrollView class], @selector(contentOffset));
    originalOffset = method_getImplementation(m);
    method_setImplementation(m, (IMP)NFBContentOffset);
    Class table = objc_getClass("TFNTableView");
    Method own = NULL;
    unsigned int n = 0;
    Method *methods = table ? class_copyMethodList(table, &n) : NULL;
    for (unsigned int i = 0; i < n; i++) if (method_getName(methods[i]) == @selector(contentOffset)) own = methods[i];
    free(methods);
    if (own) {
        originalTableOffset = method_getImplementation(own);
        method_setImplementation(own, (IMP)NFBTableContentOffset);
    }
}


// Diagnostics (temporary): a small label at the top of the screen for 30 s with what the add-on managed.
static void NFBShowStatus(void) {
    __block int ticks = 0;
    __block UILabel *label = nil;
    __block void (^tick)(void);
    tick = ^{
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) window = w;
        }
        if (window && !label) {
            label = [[UILabel alloc] initWithFrame:CGRectMake(8, 48, window.bounds.size.width - 16, 60)];
            label.numberOfLines = 3;
            label.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
            label.textColor = UIColor.whiteColor;
            label.backgroundColor = [UIColor colorWithRed:0.8 green:0.1 blue:0.1 alpha:0.85];
            label.userInteractionEnabled = NO;
            label.layer.zPosition = 10000;
            [window addSubview:label];
        }
        uintptr_t b = xslBase;
        label.text = [NSString stringWithFormat:@"NFB v9 xsl=%d table=%d hits=%ld/%ld calls=%ld\ncallers %lx %lx %lx %lx",
                      xslState, originalTableOffset != NULL, engineHits, tableHits, offsetCalls,
                      lastCallers[0] ? lastCallers[0] - b : 0, lastCallers[1] ? lastCallers[1] - b : 0,
                      lastCallers[2] ? lastCallers[2] - b : 0, lastCallers[3] ? lastCallers[3] - b : 0];
        label.accessibilityLabel = label.text;
        [label.superview bringSubviewToFront:label];
        if (++ticks < 30) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), tick);
        else { [label removeFromSuperview]; tick = nil; }
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), tick);
}

__attribute__((constructor)) static void NFBExtrasInit(void) {
    @autoreleasepool {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"hide_quick_compose"];
        NFBHookCompose();
        NFBHookTabBar();
        NFBPinBars();
        NFBStopCollapse();
        NFBStopFollowing();
        NFBNoTabBarCollapse();
        NFBNoCollapseRatio();
        NFBFreezeEngineOffset();
        dispatch_async(dispatch_get_main_queue(), ^{ NFBFreezeEngineOffset(); });
        NFBShowStatus();
        dispatch_async(dispatch_get_main_queue(), ^{ NFBNoTabBarCollapse(); NFBNoCollapseRatio(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ NFBNoTabBarCollapse(); NFBNoCollapseRatio(); });
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
