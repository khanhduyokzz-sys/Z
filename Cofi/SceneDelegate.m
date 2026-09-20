//
//  SceneDelegate.m
//  RenewFF
//

#import "SceneDelegate.h"
#import "SettingsViewController.h"
#import "UITheme.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIApplyTheme();
}

- (void)sceneDidDisconnect:(UIScene *)scene {
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    UIApplyTheme();
    settings_application_did_become_active();
}

- (void)sceneWillResignActive:(UIScene *)scene {
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
    settings_application_will_enter_foreground();
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Backgrounding is not a stop request. Keep ESP alive while minimized;
    // cleanup is reserved for an explicit Stop/Clean Up or termination.
    settings_application_did_enter_background();
}

@end
