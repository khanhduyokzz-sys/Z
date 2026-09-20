#import <UIKit/UIKit.h>

static NSString * const UIThemePreferenceKey = @"renew.appearance";

static inline UIColor *UIAccent(void) {
    return [UIColor colorWithRed:0.025 green:0.714 blue:0.831 alpha:1.0]; // #06B6D4 Cyan
}

static inline UIColor *UISecondaryAccent(void) {
    return [UIColor colorWithRed:0.231 green:0.510 blue:0.965 alpha:1.0]; // #3B82F6 Blue
}

static inline UIColor *UISectionColor(NSInteger section) {
    (void)section;
    return UIColor.whiteColor;
}

// The app ships one pure-white interface: every window is pinned to Light
// regardless of any stored preference or the system appearance.
static inline void UIApplyTheme(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([window.rootViewController isKindOfClass:UITabBarController.class])
                window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        }
    }
}

static inline void UIConfigureTable(UITableViewController *controller) {
    controller.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    controller.tableView.backgroundColor = UIColor.whiteColor;
    controller.tableView.tintColor = UIAccent();
    controller.tableView.rowHeight = UITableViewAutomaticDimension;
    controller.tableView.estimatedRowHeight = 72;
    controller.tableView.separatorInset = UIEdgeInsetsMake(0, 20, 0, 0);
    controller.tableView.contentInset = UIEdgeInsetsMake(8, 0, 16, 0);
}
