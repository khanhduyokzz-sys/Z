#import "SettingsViewController.h"
#import "DSKeepAlive.h"
#import "LogTextView.h"
#import "ESP/ESPMenuOverlay.h"
#import "TaskRop/RemoteCall.h"
#import <sys/utsname.h>
#import "UITheme.h"
#import "ESPInstallerViewController.h"

#pragma mark - Settings Keys

NSString * const kSettingsKeepAlive          = @"renew.keepAlive";
NSString * const kSettingsAutoRunExploit     = @"renew.autoRunExploit";
NSString * const kSettingsSandboxEscape      = @"renew.sandboxEscape";

NSString * const kSettingsESPRateTick        = @"renew.espRateTick";

NSString * const kSettingsDrawLine           = @"renew.drawLine";
NSString * const kSettingsDrawBox            = @"renew.drawBox";
NSString * const kSettingsDrawHealth         = @"renew.drawHealth";
NSString * const kSettingsDrawName           = @"renew.drawName";
NSString * const kSettingsDrawDistance       = @"renew.drawDistance";
NSString * const kSettingsDrawPlayerCount    = @"renew.drawPlayerCount";

NSString * const kSettingsAimbot             = @"renew.aimbot";
NSString * const kSettingsShowFov            = @"renew.showFov";
NSString * const kSettingsAimFov             = @"renew.aimFov";
NSString * const kSettingsAimSpeed           = @"renew.aimSpeed";
NSString * const kSettingsAimPos             = @"renew.aimPos";
NSString * const kSettingsAimTrigger         = @"renew.aimTrigger";
NSString * const kSettingsAimIgnoreBot       = @"renew.aimIgnoreBot";
NSString * const kSettingsAimIgnoreKnock     = @"renew.aimIgnoreKnock";
NSString * const kSettingsAimCheckVisible    = @"renew.aimCheckVisible";
NSString * const kSettingsAimLine            = @"renew.aimLine";

void settings_register_defaults(void) {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kSettingsKeepAlive:         @YES,
        kSettingsAutoRunExploit:    @NO,
        kSettingsSandboxEscape:     @NO,
        kSettingsESPRateTick:       @30,
        kSettingsDrawLine:          @YES,
        kSettingsDrawBox:           @YES,
        kSettingsDrawHealth:        @YES,
        kSettingsDrawName:          @YES,
        kSettingsDrawDistance:      @YES,
        kSettingsDrawPlayerCount:   @YES,

        kSettingsAimbot:            @NO,
        kSettingsShowFov:           @YES,
        kSettingsAimFov:            @250.0,
        kSettingsAimSpeed:          @1000.0,
        kSettingsAimPos:            @0,
        kSettingsAimTrigger:        @0,
        kSettingsAimIgnoreBot:      @NO,
        kSettingsAimIgnoreKnock:    @NO,
        kSettingsAimCheckVisible:   @YES,
        kSettingsAimLine:           @NO,
    }];
}

void settings_best_effort_termination_cleanup(const char *reason) {
    log_user("[CLEANUP] %s\n", reason);
}

void settings_application_did_become_active(void) {}
void settings_application_will_enter_foreground(void) {}
void settings_application_did_enter_background(void) {}

#pragma mark - Row Model

typedef NS_ENUM(NSInteger, SettingsRowKind) {
    SettingsRowKindAction = 0,
    SettingsRowKindDisclosure,
    SettingsRowKindInfo,
    SettingsRowKindToggle,
    SettingsRowKindStepper,
    SettingsRowKindSegmented,
    SettingsRowKindSlider,
};

static NSDictionary *SettingsRow(NSString *symbol, UIColor *color, NSString *title,
                                 NSString *subtitle, NSString *detail,
                                 SettingsRowKind kind, UIColor *titleColor) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (symbol) d[@"symbol"] = symbol;
    if (color)  d[@"color"]  = color;
    if (title)  d[@"title"]  = title;
    if (subtitle) d[@"subtitle"] = subtitle;
    if (detail) d[@"detail"] = detail;
    d[@"kind"] = @(kind);
    if (titleColor) d[@"titleColor"] = titleColor;
    return d;
}

static NSMutableDictionary *ToggleRow(NSString *title, NSString *key) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = title;
    d[@"key"] = key;
    d[@"kind"] = @(SettingsRowKindToggle);
    return d;
}

static NSMutableDictionary *StepperRow(NSString *title, NSString *subtitle, NSString *key,
                                        NSInteger min, NSInteger max) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = title;
    if (subtitle) d[@"subtitle"] = subtitle;
    d[@"key"] = key;
    d[@"kind"] = @(SettingsRowKindStepper);
    d[@"min"] = @(min);
    d[@"max"] = @(max);
    return d;
}

static NSMutableDictionary *SegmentedRow(NSString *title, NSString *subtitle, NSString *key,
                                          NSArray<NSString *> *segments) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = title;
    if (subtitle) d[@"subtitle"] = subtitle;
    d[@"key"] = key;
    d[@"kind"] = @(SettingsRowKindSegmented);
    d[@"segments"] = segments;
    return d;
}

static NSMutableDictionary *SliderRow(NSString *title, NSString *subtitle, NSString *key,
                                       float min, float max, NSString *unit) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"title"] = title;
    if (subtitle) d[@"subtitle"] = subtitle;
    d[@"key"] = key;
    d[@"kind"] = @(SettingsRowKindSlider);
    d[@"min"] = @(min);
    d[@"max"] = @(max);
    d[@"unit"] = unit ?: @"";
    return d;
}

#pragma mark - SettingsViewController

@interface SettingsViewController ()
@property (nonatomic, strong) NSArray<NSString *> *sectionHeaders;
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *sectionRows;
@property (nonatomic, strong) NSArray<NSString *> *sectionFooters;
@property (nonatomic, strong) dispatch_source_t menuPollTimer;
@end

@implementation SettingsViewController

+ (UIImage *)iconBadgeWithSymbol:(NSString *)symbol color:(UIColor *)color size:(CGFloat)size {
    UIGraphicsImageRendererFormat *fmt = [[UIGraphicsImageRendererFormat alloc] init];
    fmt.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
                                         initWithSize:CGSizeMake(size, size) format:fmt];

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size)
                                    cornerRadius:size * 0.24] fill];

        UIImageSymbolConfiguration *symCfg =
            [UIImageSymbolConfiguration configurationWithPointSize:size * 0.5
                                                            weight:UIImageSymbolWeightMedium];
        UIImage *img = [[UIImage systemImageNamed:symbol withConfiguration:symCfg]
                        imageWithTintColor:UIColor.whiteColor
                           renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (img) {
            CGSize s = img.size;
            [img drawAtPoint:CGPointMake((size - s.width) / 2.0, (size - s.height) / 2.0)];
        }
    }];
}

- (instancetype)initWithUnderlyingSection:(NSInteger)section
                               bundleTitle:(NSString *)title {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _underlyingSection = section;
        _bundleTitle = [title copy];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        _underlyingSection = NSIntegerMax;
    }
    return self;
}

- (BOOL)isRootMode {
    return _underlyingSection == NSIntegerMax;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.bundleTitle ?: @"DSWUnity";
    UIConfigureTable(self);
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 58, 0, 0);
    [self buildRows];

    if (_underlyingSection == 1) {
        UIImage *menuIcon = [UIImage systemImageNamed:@"slider.horizontal.3"];
        self.espMenuButtonItem = [[UIBarButtonItem alloc]
                                  initWithImage:menuIcon
                                          style:UIBarButtonItemStylePlain
                                         target:self
                                         action:@selector(espMenuButtonTapped:)];
        self.navigationItem.rightBarButtonItem = self.espMenuButtonItem;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self buildRows];
    [self.tableView reloadData];
}

- (void)buildRows {
    if ([self isRootMode]) {
        [self buildRootRows];
    } else if (_underlyingSection == 0) {
        [self buildLaunchRows];
    } else if (_underlyingSection == 1) {
        [self buildESPRows];
    } else if (_underlyingSection == 2) {
        [self buildAboutRows];
    } else if (_underlyingSection == 5) {
        _sectionHeaders = @[@"Background"];
        _sectionRows = @[@[ToggleRow(@"Keep app active", kSettingsKeepAlive)]];
        _sectionFooters = @[@"The interface always uses the pure white theme. "
                            @"Allows the current session to continue while the app is in the background."];
    }
}

- (void)buildAboutRows {
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 20, 0, 0);
    NSBundle *bundle = NSBundle.mainBundle;
    NSString *version = bundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0";
    NSString *build = bundle.infoDictionary[@"CFBundleVersion"] ?: @"1";
    _sectionHeaders = @[@"About DSWUnity"];
    _sectionRows = @[@[
        SettingsRow(nil, nil, @"Version", nil, version, SettingsRowKindInfo, nil),
        SettingsRow(nil, nil, @"Build", nil, build, SettingsRowKindInfo, nil),
        SettingsRow(nil, nil, @"Bundle ID", nil, bundle.bundleIdentifier ?: @"Ds.Dswunity.Esp", SettingsRowKindInfo, nil),
        SettingsRow(nil, nil, @"Telegram Support", nil, @"@duydzne", SettingsRowKindInfo, nil),
        SettingsRow(nil, nil, @"iOS System", nil, UIDevice.currentDevice.systemVersion, SettingsRowKindInfo, nil),
        SettingsRow(nil, nil, @"Device Model", nil, UIDevice.currentDevice.model, SettingsRowKindInfo, nil),
    ]];
    _sectionFooters = @[@"DSWUnity · High-Performance Native iOS Overlay"];
}

#pragma mark - Root Rows

- (void)buildRootRows {
    UIColor *cyan = [UIColor colorWithRed:0.025 green:0.714 blue:0.831 alpha:1.0];
    UIColor *blue = [UIColor colorWithRed:0.231 green:0.510 blue:0.965 alpha:1.0];

    NSArray *quickActions = @[
        SettingsRow(@"paperplane.fill", blue, @"Telegram Contact",
                    @"https://t.me/duydzne", nil, SettingsRowKindAction, nil),
        SettingsRow(@"xmark.circle.fill", UIColor.systemRedColor, @"Reset Settings",
                    nil, nil, SettingsRowKindAction, UIColor.systemRedColor),
    ];

    NSArray *menu = @[
        SettingsRow(@"square.3.layers.3d.down.right", cyan, @"ESP Configuration",
                    @"Custom display, line, box & performance options.", nil, SettingsRowKindDisclosure, nil),
    ];

    NSArray *more = @[
        SettingsRow(@"paintpalette", UIColor.systemIndigoColor, @"Appearance",
                    @"Theme and background modes.", nil, SettingsRowKindDisclosure, nil),
        SettingsRow(@"info.circle", [UIColor colorWithRed:0.35 green:0.45 blue:0.58 alpha:1.0], @"About DSWUnity",
                    @"Version and device details.", nil, SettingsRowKindDisclosure, nil),
    ];

    _sectionHeaders = @[@"Contact & Reset", @"ESP Overlay", @"System"];
    _sectionRows = @[quickActions, menu, more];
    _sectionFooters = @[@"", @"", @"DSWUnity - Clean & Fast ESP Engine"];
}

#pragma mark - Launch Options

- (void)buildLaunchRows {
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 20, 0, 0);

    NSArray *rows = @[
        ToggleRow(@"Auto-run kexploit on launch", kSettingsAutoRunExploit),
        ToggleRow(@"Sandbox escape", kSettingsSandboxEscape),
        ToggleRow(@"Keep app alive in background", kSettingsKeepAlive),
    ];

    _sectionHeaders = @[@"Advanced System Options"];
    _sectionRows = @[rows];
    _sectionFooters = @[
        @"Keep Alive allows DSWUnity to remain active in background."
    ];
}

#pragma mark - ESP Detail

- (void)buildESPRows {
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 20, 0, 0);

    NSArray *drawSection = @[
        ToggleRow(@"Tracelines", kSettingsDrawLine),
        ToggleRow(@"2D Box", kSettingsDrawBox),
        ToggleRow(@"Health Bar", kSettingsDrawHealth),
        ToggleRow(@"Player Nickname", kSettingsDrawName),
        ToggleRow(@"Distance Meter", kSettingsDrawDistance),
        ToggleRow(@"Live Player Counter", kSettingsDrawPlayerCount),
    ];

    NSArray *espSection = @[
        StepperRow(@"ESP Refresh Rate (Hz)", @"30 Hz max", kSettingsESPRateTick, 1, 30),
    ];

    NSArray *aimSection = @[
        ToggleRow(@"Aimbot", kSettingsAimbot),
        ToggleRow(@"Draw FOV Circle", kSettingsShowFov),
        ToggleRow(@"Draw Aim Lock Line", kSettingsAimLine),
        SliderRow(@"FOV Radius", @"Aim circle size", kSettingsAimFov, 5.0f, 500.0f, @"px"),
        SliderRow(@"Aim Speed", @"Rotation smoothing", kSettingsAimSpeed, 100.0f, 2000.0f, @""),
        SegmentedRow(@"Aim Position", @"Target bone", kSettingsAimPos,
                     @[@"Head", @"Neck", @"Chest", @"U.Head"]),
        SegmentedRow(@"Trigger Mode", @"When to aim", kSettingsAimTrigger,
                     @[@"Always", @"Firing", @"Scoping", @"F+S"]),
        ToggleRow(@"Ignore Bots", kSettingsAimIgnoreBot),
        ToggleRow(@"Ignore Knocked", kSettingsAimIgnoreKnock),
        ToggleRow(@"Aim Through Walls", kSettingsAimCheckVisible),
    ];

    _sectionHeaders = @[@"ESP Display Toggles", @"Performance", @"Aim Engine (VIP)"];
    _sectionRows = @[drawSection, espSection, aimSection];
    _sectionFooters = @[
        @"Select features to display on the passthrough overlay.",
        @"Refresh rate per second (1 - 30 Hz).",
        @"Kernel-steered aim assist. FOV circle draws at screen centre; selection window is 3x the circle radius. Trigger F+S also auto-fires while firing."
    ];
}

#pragma mark - ESP Menu Overlay Helper

- (void)espMenuButtonTapped:(UIBarButtonItem *)sender {
    if (esp_menu_overlay_state() == ESPMenuOverlayStateRunning) {
        [self stopESPMenuPolling];
        esp_menu_overlay_stop_in_session();
        [self updateESPMenuButton];
        return;
    }

    if (!remote_call_has_local_state() || !remote_call_current_success()) {
        [self presentESPMenuError:@"SpringBoard channel is not open. Activate ESP first."];
        return;
    }

    sender.enabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int ret = esp_menu_overlay_initialize_in_session();
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
            if (ret != 0) {
                [self presentESPMenuError:
                    [NSString stringWithFormat:@"ESP menu overlay failed to initialize: %d", ret]];
            } else {
                [self startESPMenuPolling];
            }
            [self updateESPMenuButton];
        });
    });
}

- (void)updateESPMenuButton {
    BOOL running = (esp_menu_overlay_state() == ESPMenuOverlayStateRunning);
    UIColor *tint = running
        ? [UIColor colorWithRed:0.025 green:0.714 blue:0.831 alpha:1.0]
        : UIColor.labelColor;
    self.espMenuButtonItem.tintColor = tint;
}

- (void)presentESPMenuError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ESP Menu"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)startESPMenuPolling {
    [self stopESPMenuPolling];
    _menuPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_menuPollTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_menuPollTimer, ^{
        if (esp_menu_overlay_state() != ESPMenuOverlayStateRunning) {
            [weakSelf stopESPMenuPolling];
            [weakSelf updateESPMenuButton];
            return;
        }

        esp_menu_overlay_poll_changes_in_session(^(NSString *key, float value) {
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            [ud setFloat:value forKey:key];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"SettingsStateDidChange" object:nil];
                [weakSelf buildRows];
                [weakSelf.tableView reloadData];
            });
        });
    });

    dispatch_resume(_menuPollTimer);
}

- (void)stopESPMenuPolling {
    if (_menuPollTimer) {
        dispatch_source_cancel(_menuPollTimer);
        _menuPollTimer = nil;
    }
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _sectionRows.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _sectionRows[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSString *h = _sectionHeaders[section];
    return h.length > 0 ? h : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section < (NSInteger)_sectionFooters.count) {
        NSString *f = _sectionFooters[section];
        return f.length > 0 ? f : nil;
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = _sectionRows[indexPath.section][indexPath.row];
    SettingsRowKind kind = [row[@"kind"] integerValue];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    if ([self isRootMode] || kind == SettingsRowKindInfo) {
        UITableViewCell *cell = [self rootCellForRow:row];
        cell.backgroundColor = [self isRootMode] ? UISectionColor(indexPath.section) : UIColor.secondarySystemGroupedBackgroundColor;
        return cell;
    }

    if (kind == SettingsRowKindSegmented || kind == SettingsRowKindStepper ||
        kind == SettingsRowKindSlider) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UILabel *label = [[UILabel alloc] init];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        label.adjustsFontForContentSizeCategory = YES;
        label.numberOfLines = 0;
        NSString *key = row[@"key"];
        label.text = row[@"title"];
        UIControl *control;
        NSInteger tag = indexPath.section * 1000 + indexPath.row;
        if (kind == SettingsRowKindSegmented) {
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:row[@"segments"]];
            NSInteger value = [ud integerForKey:key];
            seg.selectedSegmentIndex = value >= 0 && value < seg.numberOfSegments ? value : 0;
            [seg addTarget:self action:@selector(segmentedChanged:) forControlEvents:UIControlEventValueChanged];
            control = seg;
        } else if (kind == SettingsRowKindSlider) {
            UISlider *slider = [[UISlider alloc] init];
            slider.minimumValue = [row[@"min"] floatValue];
            slider.maximumValue = [row[@"max"] floatValue];
            float current = [ud floatForKey:key];
            if (current < slider.minimumValue || current > slider.maximumValue) current = slider.minimumValue;
            slider.value = current;
            NSString *unit = row[@"unit"] ?: @"";
            label.text = [NSString stringWithFormat:@"%@ · %.0f %@", row[@"title"], current, unit];
            [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            control = slider;
        } else {
            UIStepper *stepper = [[UIStepper alloc] init];
            stepper.minimumValue = [row[@"min"] doubleValue];
            stepper.maximumValue = [row[@"max"] doubleValue];
            stepper.value = [ud integerForKey:key];
            label.text = [NSString stringWithFormat:@"%@ · %.0f Hz", row[@"title"], stepper.value];
            [stepper addTarget:self action:@selector(stepperChanged:) forControlEvents:UIControlEventValueChanged];
            control = stepper;
        }
        control.tag = tag;
        control.accessibilityLabel = row[@"title"];
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, control]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 12;
        stack.alignment = kind == SettingsRowKindStepper ? UIStackViewAlignmentLeading : UIStackViewAlignmentFill;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:16],
            [stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-16],
            [stack.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:20],
            [stack.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-20],
            [control.heightAnchor constraintGreaterThanOrEqualToConstant:32],
        ]];
        return cell;
    }

    UITableViewCellStyle style = row[@"subtitle"]
        ? UITableViewCellStyleSubtitle
        : UITableViewCellStyleDefault;

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:nil];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;

    if (row[@"subtitle"]) {
        cell.detailTextLabel.text = row[@"subtitle"];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.numberOfLines = 0;
    }

    NSString *key = row[@"key"];

    if (kind == SettingsRowKindToggle) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.onTintColor = UIAccent();
        sw.accessibilityLabel = row[@"title"];
        sw.on = key ? [ud boolForKey:key] : NO;
        sw.tag = indexPath.section * 1000 + indexPath.row;
        [sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    return cell;
}

- (UITableViewCell *)rootCellForRow:(NSDictionary *)row {
    SettingsRowKind kind = [row[@"kind"] integerValue];

    UITableViewCellStyle style = row[@"subtitle"]
        ? UITableViewCellStyleSubtitle
        : (row[@"detail"] ? UITableViewCellStyleValue1 : UITableViewCellStyleDefault);

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:nil];

    NSString *symbol = row[@"symbol"];
    UIColor *color = row[@"color"];
    if (symbol && color)
        cell.imageView.image = [SettingsViewController iconBadgeWithSymbol:symbol color:color size:29];

    cell.textLabel.text = row[@"title"];
    if (row[@"titleColor"])
        cell.textLabel.textColor = row[@"titleColor"];

    if (row[@"subtitle"]) {
        cell.detailTextLabel.text = row[@"subtitle"];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.numberOfLines = 2;
    }

    if (row[@"detail"] && !row[@"subtitle"]) {
        cell.detailTextLabel.text = row[@"detail"];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    }

    switch (kind) {
        case SettingsRowKindDisclosure:
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case SettingsRowKindInfo:
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        default:
            break;
    }

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = row[@"title"];
    content.secondaryText = row[@"subtitle"] ?: row[@"detail"];
    content.secondaryTextProperties.numberOfLines = 0;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.textProperties.color = UIColor.labelColor;
    content.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(16, 20, 16, 20);
    if (symbol) {
        content.image = [UIImage systemImageNamed:symbol];
        content.imageProperties.tintColor = color;
        content.imageProperties.maximumSize = CGSizeMake(28, 28);
        content.imageToTextPadding = 16;
    }
    cell.contentConfiguration = content;
    return cell;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = _sectionRows[indexPath.section][indexPath.row];
    SettingsRowKind kind = [row[@"kind"] integerValue];

    if (kind == SettingsRowKindDisclosure) {
        NSString *title = row[@"title"];
        NSDictionary *destinations = @{@"ESP Configuration": @1, @"Appearance": @5, @"About DSWUnity": @2};
        NSNumber *destination = destinations[title];
        if (!destination) return;
        NSInteger section = destination.integerValue;
        SettingsViewController *detail = [[SettingsViewController alloc]
                                          initWithUnderlyingSection:section
                                                        bundleTitle:title];
        [self.navigationController pushViewController:detail animated:YES];
    }

    if (kind == SettingsRowKindAction) {
        NSString *title = row[@"title"];
        if ([title isEqualToString:@"Reset Settings"]) {
            [self confirmCleanup];
        } else if ([title isEqualToString:@"Telegram Contact"]) {
            NSURL *url = [NSURL URLWithString:@"https://t.me/duydzne"];
            if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    }
}

#pragma mark - Control Actions

- (NSDictionary *)rowForControlTag:(NSInteger)tag {
    NSInteger section = tag / 1000;
    NSInteger row = tag % 1000;
    if (section < (NSInteger)_sectionRows.count && row < (NSInteger)_sectionRows[section].count)
        return _sectionRows[section][row];
    return nil;
}

- (void)toggleChanged:(UISwitch *)sender {
    NSDictionary *row = [self rowForControlTag:sender.tag];
    NSString *key = row[@"key"];
    if (!key) return;

    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn forKey:key];

    if ([key isEqualToString:kSettingsKeepAlive])
        ds_keepalive_apply_enabled(sender.isOn);

    [[NSNotificationCenter defaultCenter] postNotificationName:@"SettingsStateDidChange" object:nil];
}

- (void)stepperChanged:(UIStepper *)sender {
    NSDictionary *row = [self rowForControlTag:sender.tag];
    NSString *key = row[@"key"];
    if (!key) return;

    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)sender.value forKey:key];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SettingsStateDidChange" object:nil];

    NSInteger section = sender.tag / 1000;
    NSInteger rowIdx = sender.tag % 1000;
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:rowIdx inSection:section]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

- (void)sliderChanged:(UISlider *)sender {
    NSDictionary *row = [self rowForControlTag:sender.tag];
    NSString *key = row[@"key"];
    if (!key) return;

    [[NSUserDefaults standardUserDefaults] setFloat:sender.value forKey:key];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SettingsStateDidChange" object:nil];

    NSInteger section = sender.tag / 1000;
    NSInteger rowIdx = sender.tag % 1000;
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:rowIdx inSection:section];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    NSString *unit = row[@"unit"] ?: @"";
    cell.textLabel.text =
        [NSString stringWithFormat:@"%@ · %.0f %@", row[@"title"], sender.value, unit];
}

- (void)segmentedChanged:(UISegmentedControl *)sender {
    NSDictionary *row = [self rowForControlTag:sender.tag];
    NSString *key = row[@"key"];
    if (!key) return;

    [[NSUserDefaults standardUserDefaults] setInteger:sender.selectedSegmentIndex forKey:key];
    if ([key isEqualToString:UIThemePreferenceKey]) UIApplyTheme();
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SettingsStateDidChange" object:nil];
}

#pragma mark - Reset Settings

- (void)confirmCleanup {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Reset Settings"
                         message:@"Reset all ESP display settings and preferences to default?"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        UINavigationController *gameNavigation = (UINavigationController *)self.tabBarController.viewControllers.firstObject;
        ESPInstallerViewController *game = (ESPInstallerViewController *)gameNavigation.viewControllers.firstObject;
        if ([game isKindOfClass:ESPInstallerViewController.class]) {
            [game prepareForCleanup];
        }
        [self stopESPMenuPolling];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        for (NSString *key in defaults.dictionaryRepresentation) {
            if ([key hasPrefix:@"renew."]) [defaults removeObjectForKey:key];
        }
        settings_register_defaults();
        ds_keepalive_apply_enabled([defaults boolForKey:kSettingsKeepAlive]);
        log_clear_display();
        UIApplyTheme();
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SettingsStateDidChange" object:nil];
        [self buildRows];
        [self.tableView reloadData];
        UINotificationFeedbackGenerator *feedback = [[UINotificationFeedbackGenerator alloc] init];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
