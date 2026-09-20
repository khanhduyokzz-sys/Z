//
//  AppDelegate.m
//  RenewFF
//

#import "AppDelegate.h"
#import "SettingsViewController.h"
#import "DSKeepAlive.h"
#import "LogTextView.h"
#import <signal.h>
#import <sys/utsname.h>

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [self logBootIdentity];
    settings_register_defaults();
    log_set_verbose(YES);
    ds_keepalive_apply_enabled([[NSUserDefaults standardUserDefaults] boolForKey:kSettingsKeepAlive]);
    [self installBarAppearances];
    return YES;
}

- (void)logBootIdentity {
    NSBundle *b = [NSBundle mainBundle];
    NSDictionary *info = b.infoDictionary;
    NSString *shortVer = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build    = info[@"CFBundleVersion"] ?: @"?";

    struct utsname u = {0};
    const char *machine = "device";
    if (uname(&u) == 0 && u.machine[0])
        machine = u.machine;
    NSString *ios = UIDevice.currentDevice.systemVersion ?: @"?";

    fprintf(stdout,
        "\n"
        "     ╭───────────╮\n"
        "     │ ▄▄▄▄▄▄▄▄▄ │\n"
        "     ├───────────┤\n"
        "     │ ░░░░░░░░░ │   R E N E W  F F\n"
        "     │ ░░░ R ░░░ │   %s (%s)\n"
        "     │ ░░░░░░░░░ │   %s • iOS %s\n"
        "     │ ░░░░░░░░░ │\n"
        "     ╰───────────╯\n"
        "\n",
        shortVer.UTF8String, build.UTF8String,
        machine, ios.UTF8String);
}

- (void)installBarAppearances {
    UIColor *teal = [UIColor colorWithRed:0.0 green:0.71 blue:0.68 alpha:1.0];

    UINavigationBarAppearance *nav = [[UINavigationBarAppearance alloc] init];
    [nav configureWithDefaultBackground];
    nav.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    nav.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.08 alpha:0.86]
            : [UIColor colorWithWhite:0.98 alpha:0.86];
    }];
    nav.shadowColor = [UIColor colorWithWhite:0 alpha:0.12];
    nav.titleTextAttributes = @{ NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold] };
    nav.largeTitleTextAttributes = @{ NSFontAttributeName: [UIFont systemFontOfSize:34 weight:UIFontWeightBold] };
    UINavigationBar.appearance.standardAppearance = nav;
    UINavigationBar.appearance.scrollEdgeAppearance = nav;
    UINavigationBar.appearance.compactAppearance = nav;
    UINavigationBar.appearance.compactScrollEdgeAppearance = nav;
    UINavigationBar.appearance.tintColor = teal;
    UINavigationBar.appearance.prefersLargeTitles = NO;

    UITabBarAppearance *tab = [[UITabBarAppearance alloc] init];
    [tab configureWithDefaultBackground];
    tab.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    tab.shadowColor = [UIColor colorWithWhite:0 alpha:0.12];
    UITabBar.appearance.standardAppearance = tab;
    UITabBar.appearance.scrollEdgeAppearance = tab;
    UITabBar.appearance.tintColor = teal;
    UITabBar.appearance.unselectedItemTintColor = [UIColor secondaryLabelColor];
}

#pragma mark - UISceneSession lifecycle

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ESPStopRequested" object:nil];
    settings_best_effort_termination_cleanup("applicationWillTerminate");
}

@end
