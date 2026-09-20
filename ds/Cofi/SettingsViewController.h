//
//  SettingsViewController.h
//  DSWUnity
//

#import <UIKit/UIKit.h>

extern NSString * const kSettingsKeepAlive;
extern NSString * const kSettingsAutoRunExploit;
extern NSString * const kSettingsSandboxEscape;

extern NSString * const kSettingsESPRateTick;

extern NSString * const kSettingsDrawLine;
extern NSString * const kSettingsDrawBox;
extern NSString * const kSettingsDrawHealth;
extern NSString * const kSettingsDrawName;
extern NSString * const kSettingsDrawDistance;
extern NSString * const kSettingsDrawPlayerCount;

extern NSString * const kSettingsAimbot;
extern NSString * const kSettingsShowFov;
extern NSString * const kSettingsAimFov;
extern NSString * const kSettingsAimSpeed;
extern NSString * const kSettingsAimPos;
extern NSString * const kSettingsAimTrigger;
extern NSString * const kSettingsAimIgnoreBot;
extern NSString * const kSettingsAimIgnoreKnock;
extern NSString * const kSettingsAimCheckVisible;
extern NSString * const kSettingsAimLine;

void settings_register_defaults(void);
void settings_best_effort_termination_cleanup(const char *reason);
void settings_application_did_become_active(void);
void settings_application_will_enter_foreground(void);
void settings_application_did_enter_background(void);

@interface SettingsViewController : UITableViewController

@property (nonatomic) NSInteger underlyingSection;
@property (copy, nonatomic, nullable) NSString *bundleTitle;
@property (retain, nonatomic, nullable) UIBarButtonItem *espMenuButtonItem;

+ (nonnull UIImage *)iconBadgeWithSymbol:(nonnull NSString *)symbol
                                   color:(nonnull UIColor *)color
                                    size:(CGFloat)size;

- (instancetype)initWithUnderlyingSection:(NSInteger)section
                              bundleTitle:(nullable NSString *)title NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithCoder:(NSCoder *)coder;

@end
