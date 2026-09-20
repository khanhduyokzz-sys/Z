#import <UIKit/UIKit.h>

// ============================================================================
//  DSWUnity · Classic White Theme
// ----------------------------------------------------------------------------
//  Single, pure-white interface with a calm graphite + teal accent system.
//  Every surface is white, every section sits on a 2% graphite plate, every
//  accent is teal #0F766E. The trait collection is forced to Light on every
//  window so the app reads identically in dark-mode systems.
//
//  Palette
//    surface          #FFFFFF   pure white (every window, every card)
//    surfaceMuted     #F5F5F7   2% graphite — section backgrounds, table bg
//    hairline          10% black card and section separators
//    textPrimary      #1A1A1A   near-black graphite — headings, primary text
//    textSecondary    #6E6E73   medium graphite — subtitles, hints, footers
//    textTertiary     #A1A1A6   light graphite — eyebrows, captions
//    accent           #0F766E   teal — toggles, progress, primary buttons
//    accentSoft       #14B8A6   bright teal — hero glow, accent gradient end
//    success          #16A34A   emerald — "LIVE / Active" states
//    warn             #D97706   amber — "Retrying" states
//    danger           #DC2626   red — "Failed / Reset" states
// ============================================================================

static NSString * const UIThemePreferenceKey = @"renew.appearance";

static inline UIColor *UIAccent(void) {
    // Primary teal — toggles, progress, primary actions.
    return [UIColor colorWithRed:0.059f green:0.463f blue:0.431f alpha:1.0f]; // #0F766E
}

static inline UIColor *UIAccentSoft(void) {
    // Brighter teal used for gradient endpoints and glow strokes.
    return [UIColor colorWithRed:0.078f green:0.722f blue:0.651f alpha:1.0f]; // #14B8A6
}

static inline UIColor *UISecondaryAccent(void) {
    // Quiet slate-blue companion for two-tone accents (hero gradient end).
    return [UIColor colorWithRed:0.231f green:0.510f blue:0.965f alpha:1.0f]; // #3B82F6
}

static inline UIColor *UISurfaceColor(void) {
    return UIColor.whiteColor;
}

static inline UIColor *UISurfaceMutedColor(void) {
    // 2% graphite — sits behind inset-grouped table sections.
    return [UIColor colorWithWhite:0.96f alpha:1.0f];
}

static inline UIColor *UIHairlineColor(void) {
    return [UIColor colorWithWhite:0.0f alpha:0.10f];
}

static inline UIColor *UITextPrimaryColor(void) {
    return [UIColor colorWithWhite:0.10f alpha:1.0f]; // near-black graphite
}

static inline UIColor *UITextSecondaryColor(void) {
    return [UIColor colorWithWhite:0.43f alpha:1.0f];
}

static inline UIColor *UITextTertiaryColor(void) {
    return [UIColor colorWithWhite:0.63f alpha:1.0f];
}

static inline UIColor *UISuccessColor(void) {
    return [UIColor colorWithRed:0.086f green:0.639f blue:0.290f alpha:1.0f]; // #16A34A
}

static inline UIColor *UIWarnColor(void) {
    return [UIColor colorWithRed:0.851f green:0.467f blue:0.024f alpha:1.0f]; // #D97706
}

static inline UIColor *UIDangerColor(void) {
    return [UIColor colorWithRed:0.863f green:0.149f blue:0.149f alpha:1.0f]; // #DC2626
}

static inline UIColor *UISectionColor(NSInteger section) {
    (void)section;
    return UIColor.whiteColor;
}

// Force the trait collection to Light on EVERY window in EVERY connected
// scene. This is the "preset theme to white" behaviour: regardless of the
// iOS system appearance (Light / Dark / Auto), the app always renders in
// the classic white theme.
//
// We iterate every window (not just UITabBarController roots) so pushed
// navigation controllers, modal sheets, and the ESP overlay window all
// inherit the Light trait. We also force the rootViewController's
// overrideUserInterfaceStyle so any view controller presented afterwards
// inherits Light without needing another pass.
static inline void UIApplyTheme(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
            // Propagate down the root VC chain so presented VCs inherit.
            UIViewController *rootVC = window.rootViewController;
            while (rootVC) {
                rootVC.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
                rootVC = rootVC.presentedViewController;
            }
        }
    }
}

static inline void UIConfigureTable(UITableViewController *controller) {
    controller.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    controller.tableView.backgroundColor = UISurfaceMutedColor();
    controller.tableView.tintColor = UIAccent();
    controller.tableView.rowHeight = UITableViewAutomaticDimension;
    controller.tableView.estimatedRowHeight = 72;
    controller.tableView.separatorInset = UIEdgeInsetsMake(0, 20, 0, 0);
    controller.tableView.contentInset = UIEdgeInsetsMake(8, 0, 16, 0);
}
