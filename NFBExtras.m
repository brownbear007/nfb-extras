// NFBExtras: a tiny add-on for NeoFreeBird, injected next to it when signing.
// NeoFreeBird already hides X's "What's happening?" quick-compose bar when its
// `hide_quick_compose` setting is on (QuickComposerSlotView hook), but its
// settings screen has no switch for it. This turns that setting on at launch.
#import <Foundation/Foundation.h>

__attribute__((constructor)) static void NFBExtrasInit(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:YES forKey:@"hide_quick_compose"];
    }
}
