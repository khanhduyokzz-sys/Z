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
    // Classic white surface with a calm graphite + teal accent system.
    // Pinned to Light so the app reads identically in dark-mode systems.

    UINavigationBarAppearance *nav = [[UINavigationBarAppearance alloc] init];
    [nav configureWithOpaqueBackground];
    nav.backgroundColor = UIColor.whiteColor;
    nav.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.10f];
    nav.titleTextAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.10f alpha:1.0f],
    };
    nav.largeTitleTextAttributes = @{
        NSFontAttributeName: [UIFont systemFontOfSize:34 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.10f alpha:1.0f],
    };
    UINavigationBar.appearance.standardAppearance = nav;
    UINavigationBar.appearance.scrollEdgeAppearance = nav;
    UINavigationBar.appearance.compactAppearance = nav;
    UINavigationBar.appearance.compactScrollEdgeAppearance = nav;
    UINavigationBar.appearance.tintColor = [UIColor colorWithRed:0.059f green:0.463f blue:0.431f alpha:1.0f];
    UINavigationBar.appearance.prefersLargeTitles = NO;

    UITabBarAppearance *tab = [[UITabBarAppearance alloc] init];
    [tab configureWithOpaqueBackground];
    tab.backgroundColor = UIColor.whiteColor;
    tab.shadowColor = [UIColor colorWithWhite:0.0f alpha:0.10f];
    UITabBar.appearance.standardAppearance = tab;
    UITabBar.appearance.scrollEdgeAppearance = tab;
    UITabBar.appearance.tintColor = [UIColor colorWithRed:0.059f green:0.463f blue:0.431f alpha:1.0f];
    UITabBar.appearance.unselectedItemTintColor = [UIColor colorWithWhite:0.63f alpha:1.0f];
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
