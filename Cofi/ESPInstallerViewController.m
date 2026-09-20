//
//  ESPInstallerViewController.m
//  DSWUnity — Game tab (modern dashboard UI)
//
//  Completely redesigned interface: gradient hero status card, glowing
//  activation button, 2×2 pipeline status grid and a Telegram support card.
//  All engine logic (activation chain, tick loop, teardown) is unchanged.
//

#import "ESPInstallerViewController.h"
#import "SettingsViewController.h"
#import "LogTextView.h"
#import "drawing_view/esp.h"
#import "Core/PhantomMemory.h"
#import "DarkSwordMemoryProvider.h"

// Global module base owned by the collector; the installer publishes it after
// the DarkSword provider locates UnityFramework, and clears it on teardown.
extern uint64_t ModuleBase;
#import "MemoryProviderOwner.h"
#import "kexploit/kexploit_opa334.h"
#import "kexploit/kutils.h"
#import "kexploit/krw.h"
#import "kpf/patchfinder.h"
#import "utils/sandbox.h"
#import "TaskRop/RemoteCall.h"
#import "TaskRop/MigFilterBypassThread.h"
#import "ESP/ESPDrawOverlay.h"
#import "ESP/ESPMenuOverlay.h"
#include <errno.h>
#include <signal.h>
#import "UITheme.h"

typedef NS_ENUM(NSInteger, ESPSection) {
    ESPSectionHero = 0,
    ESPSectionAction,
    ESPSectionPipeline,
    ESPSectionSupport,
    ESPSectionCount
};

typedef NS_ENUM(NSInteger, ESPActivationStep) {
    ESPStepIdle = 0,
    ESPStepKernelExploit,
    ESPStepSandboxEscape,
    ESPStepSpringBoardChannel,
    ESPStepMemoryProvider,
    ESPStepStartESP,
    ESPStepComplete,
    ESPStepFailed
};

#pragma mark - Design Tokens

static NSString * const DSSupportURL    = @"https://t.me/duydzne";
static NSString * const DSSupportHandle = @"@duydzne";

static inline UIColor *DSLiveColor(void) {
    return [UIColor colorWithRed:0.20 green:0.80 blue:0.42 alpha:1.0]; // #33CC6B
}

static inline UIColor *DSWarnColor(void) {
    return [UIColor colorWithRed:0.95 green:0.64 blue:0.18 alpha:1.0]; // #F2A32E
}

static inline UIColor *DSTealColor(void) {
    return [UIColor colorWithRed:0.0 green:0.71 blue:0.68 alpha:1.0]; // #00B5AD
}

static inline UIColor *DSCardColor(void) {
    // Pure-white interface: cards are white and separated by hairline borders.
    return UIColor.whiteColor;
}

static inline UIColor *DSBorderColor(void) {
    return [UIColor colorWithWhite:0.0 alpha:0.10];
}

#pragma mark - Label / View Factories

static UILabel *DSLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.numberOfLines = 1;
    return label;
}

static UILabel *DSCapsLabel(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color, CGFloat kern) {
    UILabel *label = [[UILabel alloc] init];
    label.attributedText = [[NSAttributedString alloc]
        initWithString:text
            attributes:@{ NSFontAttributeName      : [UIFont systemFontOfSize:size weight:weight],
                          NSForegroundColorAttributeName : color,
                          NSKernAttributeName      : @(kern) }];
    return label;
}

static UIView *DSDot(CGFloat size, UIColor *color) {
    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = color;
    dot.layer.cornerRadius = size / 2.0;
    [dot.widthAnchor constraintEqualToConstant:size].active = YES;
    [dot.heightAnchor constraintEqualToConstant:size].active = YES;
    return dot;
}

// Repeating soft opacity pulse; restarts naturally when the table reloads.
static void DSAttachPulse(UIView *view) {
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue   = @0.25;
    pulse.duration  = 0.9;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [view.layer addAnimation:pulse forKey:@"dsPulse"];
}

// Simple gradient-backed view (layer-class based, so it tracks bounds changes).
@interface DSGradientView : UIView
@property (nonatomic, copy) NSArray<UIColor *> *gradientColors;
@end

@implementation DSGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        CAGradientLayer *gradient = (CAGradientLayer *)self.layer;
        gradient.startPoint = CGPointMake(0.0, 0.35);
        gradient.endPoint   = CGPointMake(1.0, 0.65);
    }
    return self;
}

- (void)setGradientColors:(NSArray<UIColor *> *)gradientColors {
    _gradientColors = [gradientColors copy];
    NSMutableArray *cgColors = [NSMutableArray arrayWithCapacity:_gradientColors.count];
    for (UIColor *color in _gradientColors) {
        if (color.CGColor) [cgColors addObject:(id)color.CGColor];
    }
    ((CAGradientLayer *)self.layer).colors = cgColors;
}
@end

#pragma mark - Class Extension

@interface ESPInstallerViewController ()
@property (nonatomic) BOOL espActive;
@property (nonatomic) ESPActivationStep currentStep;
@property (nonatomic, strong) MemoryProviderOwner *providerOwner;
@property (nonatomic, strong) ESPFrameBuilder *frameBuilder;
@property (nonatomic, strong) dispatch_queue_t workerQueue;
@property (nonatomic, strong) dispatch_source_t workerTimer;
@property (nonatomic) int moduleRetryCount;
@property (nonatomic) int rosterTickCount;
@property (nonatomic) int logTickCount;
@property (nonatomic) int consecutivePacketFailures;
@property (nonatomic) int consecutiveEmptyRosters;
@property (nonatomic) int readBackoffTicks;
@property (nonatomic) BOOL cleanupInProgress;
@end

@implementation ESPInstallerViewController

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    return self;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)dealloc {
    if (_workerTimer) {
        dispatch_source_cancel(_workerTimer);
        _workerTimer = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DSWUnity";
    UIConfigureTable(self);
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.estimatedRowHeight = 108.0;
    self.tableView.sectionHeaderHeight = UITableViewAutomaticDimension;
    self.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedSectionHeaderHeight = 30.0;
    self.tableView.estimatedSectionFooterHeight = 24.0;
    self.tableView.contentInset = UIEdgeInsetsMake(10, 0, 16, 0);

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(settingsStateDidChange:)
                                                 name:@"SettingsStateDidChange"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(stopRequested:)
                                                 name:@"ESPStopRequested"
                                               object:nil];
}

- (void)stopRequested:(NSNotification *)note {
    (void)note;
    if (_espActive || _providerOwner || _frameBuilder) [self stopESP];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadState];
}

- (void)settingsStateDidChange:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadState];
        // Reconfigure the roster-refresh timer so live tick-rate edits from
        // the Settings tab take effect immediately without restarting ESP.
        [self applyRosterTickRateIfRunning];
    });
}

#pragma mark - Tick-rate helper

// Reads the current ESP tick rate (Hz) from NSUserDefaults, clamps into
// [1, 30], and defaults to 30 when the key was never written.
- (int)currentESPTickHz {
    NSNumber *raw = [[NSUserDefaults standardUserDefaults] objectForKey:kSettingsESPRateTick];
    NSInteger hz = raw ? [raw integerValue] : 30;
    if (hz < 1) hz = 1;
    if (hz > 30) hz = 30;
    return (int)hz;
}

- (void)applyRosterTickRateIfRunning {
    if (!_workerTimer) return;
    int hz = [self currentESPTickHz];
    uint64_t intervalNs = (uint64_t)(NSEC_PER_SEC / (uint64_t)hz);
    uint64_t leewayNs   = intervalNs / 20;
    dispatch_source_set_timer(_workerTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              intervalNs, leewayNs);
}

#pragma mark - State

- (BOOL)espEnabled {
    return _espActive;
}

- (BOOL)espApplied {
    return _espActive && _currentStep == ESPStepComplete;
}

- (NSString *)statusTitle {
    if (_currentStep > ESPStepIdle && _currentStep < ESPStepComplete)
        return @"Activating...";
    if (_currentStep == ESPStepFailed)
        return @"Failed";
    return _espActive ? @"Active" : @"Ready";
}

- (NSString *)statusDetail {
    switch (_currentStep) {
        case ESPStepKernelExploit:       return @"Preparing access…";
        case ESPStepSandboxEscape:       return @"Preparing session…";
        case ESPStepSpringBoardChannel:  return @"Connecting overlay…";
        case ESPStepMemoryProvider:      return @"Connecting to the game…";
        case ESPStepStartESP:            return @"Starting ESP session...";
        case ESPStepComplete:            return @"ESP session is running.";
        case ESPStepFailed:              return @"Activation failed. Check log for details.";
        default:                         return @"ESP is off. Activate it to start.";
    }
}

- (NSString *)actionTitle {
    return _espActive ? @"Deactivate ESP" : @"Activate ESP";
}

- (NSString *)actionSubtitle {
    return _espActive
        ? @"Stops the current session and releases resources."
        : @"Revalidates protected access and starts a fresh session.";
}

- (void)reloadState {
    [self.tableView reloadData];
}

- (void)toggleESP {
    if (_currentStep > ESPStepIdle && _currentStep < ESPStepComplete) return;
    if (_espActive) {
        [self stopESP];
    } else {
        [self setESPEnabledAndRun:YES];
    }
}

- (void)setESPEnabledAndRun:(BOOL)run {
    if (run) {
        [self runActivationChain];
    } else {
        [self stopESP];
    }
}

#pragma mark - Activation Chain

- (void)runActivationChain {
    if (_espActive) return;

    _cleanupInProgress = NO;
    _espActive = YES;
    _currentStep = ESPStepKernelExploit;
    [self reloadState];

    log_session_begin();

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = [self executeActivationChain];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                self->_currentStep = ESPStepComplete;
                log_user("[ESP] Activation complete\n");
                [self startRosterRefreshLoop];
            } else {
                self->_currentStep = ESPStepFailed;
                self->_espActive = NO;
                log_user("[ESP] Activation failed\n");
                log_session_end();
            }
            [self reloadState];
        });
    });
}

- (BOOL)executeActivationChain {
    // Step 1: Kernel exploit
    [self updateStep:ESPStepKernelExploit];
    if (![self ensureKernelExploit]) return NO;

    // Step 2: Sandbox escape
    [self updateStep:ESPStepSandboxEscape];
    if (![self ensureSandboxEscape]) return NO;

    // Step 3: SpringBoard remote call channel
    [self updateStep:ESPStepSpringBoardChannel];
    if (![self ensureSpringBoardChannel]) return NO;

    // Step 4: Memory provider
    [self updateStep:ESPStepMemoryProvider];
    if (![self ensureMemoryProvider]) return NO;

    // Step 5: Start ESP
    [self updateStep:ESPStepStartESP];
    return YES;
}

- (void)updateStep:(ESPActivationStep)step {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_currentStep = step;
        [self reloadState];
    });
}

#pragma mark - Step 1: Kernel Exploit

- (BOOL)ensureKernelExploit {
    if (kexploit_krw_ready()) {
        log_user("[ESP] Kernel r/w already available\n");
        return YES;
    }

    log_user("[ESP] Step 1: Running kernel exploit...\n");

    int ret = kexploit_opa334();
    if (ret != 0) {
        log_user("[ESP] Kernel exploit failed: %d\n", ret);
        return NO;
    }

    if (!kexploit_krw_ready()) {
        log_user("[ESP] Kernel r/w not ready after exploit\n");
        return NO;
    }

    log_user("[ESP] Kernel r/w established, slide=0x%llx\n", g_kernel_slide);

    ret = init_xpf();
    if (ret != 0) {
        log_user("[ESP] XPF patchfinder failed: %d (non-fatal)\n", ret);
    }

    return YES;
}

#pragma mark - Step 2: Sandbox Escape

- (BOOL)ensureSandboxEscape {
    if (check_sandbox_var_rw() == 0) {
        log_user("[ESP] Sandbox already escaped\n");
        return YES;
    }

    log_user("[ESP] Step 2: Patching sandbox extensions...\n");

    int ret = patch_sandbox_ext();
    if (ret != 0) {
        log_user("[ESP] patch_sandbox_ext failed, trying borrow from SpringBoard\n");
        ret = borrow_sandbox_ext("SpringBoard");
        if (ret != 0) {
            log_user("[ESP] borrow_sandbox_ext also failed: %d\n", ret);
            return NO;
        }
    }

    if (check_sandbox_var_rw() != 0) {
        log_user("[ESP] Sandbox escape verification failed\n");
        return NO;
    }

    log_user("[ESP] Sandbox escaped successfully\n");
    return YES;
}

#pragma mark - Step 3: SpringBoard Channel

- (BOOL)ensureSpringBoardChannel {
    if (remote_call_has_local_state() && remote_call_current_success()) {
        log_user("[ESP] SpringBoard channel already open\n");
        return YES;
    }

    log_user("[ESP] Step 3: Opening SpringBoard channel...\n");

    int ret = init_remote_call_with_first_exception_timeout("SpringBoard", false, 10000);
    if (ret != 0) {
        RemoteCallInitFailure failure = remote_call_last_init_failure();
        log_user("[ESP] SpringBoard channel failed: %s\n",
                 remote_call_init_failure_description(failure));
        return NO;
    }

    if (!remote_call_current_success()) {
        log_user("[ESP] SpringBoard channel not successful\n");
        return NO;
    }

    log_user("[ESP] SpringBoard channel open (pid=%d)\n", remote_call_current_pid());
    return YES;
}

#pragma mark - Step 4: Memory Provider

- (BOOL)ensureMemoryProvider {
    log_user("[ESP] Step 4: Initializing DarkSword memory provider...\n");

    _providerOwner = [[MemoryProviderOwner alloc] initWithTargetProcessName:@"FreeFire"];
    if (![_providerOwner isReady]) {
        log_user("[ESP] Memory provider not ready — is FreeFire running?\n");
        _providerOwner = nil;
        return NO;
    }

    _frameBuilder = [[ESPFrameBuilder alloc] init];

    DarkSwordMemoryProvider *provider = (DarkSwordMemoryProvider *)[_providerOwner provider];
    phantom_memory_set_provider(provider);
    uint64_t unityBase = [provider findUnityFrameworkBase];
    uint64_t mainBase = [provider findMainModuleBase];
    uint64_t base = unityBase;
    ModuleBase = base;
    if (base) {
        log_user("[ESP] Found moduleBase: 0x%llx (unity=0x%llx, main=0x%llx)\n", base, unityBase, mainBase);
    } else {
        log_user("[ESP] UnityFramework not found yet (main=0x%llx); waiting for dyld image\n", mainBase);
    }

    int overlayResult = esp_draw_overlay_initialize_in_session();
    if (overlayResult != 0) {
        log_user("[ESP] Overlay initialization failed: %d\n", overlayResult);
        return NO;
    }

    log_user("[ESP] Memory provider initialized (overlay ready, game data %s)\n",
             base ? "ready" : "pending");
    return YES;
}

#pragma mark - Roster Refresh Loop

- (void)startRosterRefreshLoop {
    if (_workerTimer) return;

    if (!_workerQueue) {
        _workerQueue = dispatch_queue_create("com.ds.freefire.esp.worker", DISPATCH_QUEUE_SERIAL);
    }

    _workerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _workerQueue);
    // Tick rate is user-configurable via Settings → "ESP/AIM rate tick"
    // (kSettingsESPRateTick, 1..30 Hz, default 30 Hz).  applyRosterTickRateIfRunning
    // reprograms this timer live whenever the stepper changes.
    int hz = [self currentESPTickHz];
    uint64_t intervalNs = (uint64_t)(NSEC_PER_SEC / (uint64_t)hz);
    uint64_t leewayNs   = intervalNs / 20;
    dispatch_source_set_timer(_workerTimer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              intervalNs, leewayNs);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_workerTimer, ^{
        [weakSelf rosterTick];
    });
    dispatch_resume(_workerTimer);
}

- (void)rosterTick {
    if (!_espActive || !_frameBuilder || !_providerOwner || ![_providerOwner isReady]) {
        return;
    }

    DarkSwordMemoryProvider *provider = (DarkSwordMemoryProvider *)[_providerOwner provider];
    if (_readBackoffTicks > 0) {
        _readBackoffTicks--;
        return;
    }

    if (ModuleBase == 0) {
        _moduleRetryCount++;
        if (_moduleRetryCount % 50 != 0) return;
        uint64_t unityBase = [provider findUnityFrameworkBase];
        if (unityBase) {
            ModuleBase = unityBase;
            log_user("[ESP] Resolved moduleBase: 0x%llx\n", unityBase);
        } else {
            return;
        }
    }

    if (![provider beginReadTransaction]) return;

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    float screenW = (float)fmax(screenBounds.size.width, screenBounds.size.height);
    float screenH = (float)fmin(screenBounds.size.width, screenBounds.size.height);
    esp_draw_overlay_get_screen_size(&screenW, &screenH);
    ESPDrawPacket packet = {0};
    BOOL packetOk = [_frameBuilder buildDrawPacket:&packet
                                      screenWidth:screenW
                                     screenHeight:screenH];
    [provider endReadTransaction];

    if ([provider diagnosticIsDegraded]) {
        _readBackoffTicks = MIN(2, (int)[provider diagnosticConsecutiveOperationalFailureCount]);
    }

    if (packetOk) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        packet.showLines = [defaults objectForKey:kSettingsDrawLine] ? [defaults boolForKey:kSettingsDrawLine] : YES;
        packet.showBoxes = [defaults objectForKey:kSettingsDrawBox] ? [defaults boolForKey:kSettingsDrawBox] : YES;
        packet.showHealth = [defaults objectForKey:kSettingsDrawHealth] ? [defaults boolForKey:kSettingsDrawHealth] : YES;
        packet.showNames = [defaults objectForKey:kSettingsDrawName] ? [defaults boolForKey:kSettingsDrawName] : YES;
        packet.showDistance = [defaults objectForKey:kSettingsDrawDistance] ? [defaults boolForKey:kSettingsDrawDistance] : YES;
        packet.showPlayerCount = [defaults objectForKey:kSettingsDrawPlayerCount] ? [defaults boolForKey:kSettingsDrawPlayerCount] : YES;
    }

    _rosterTickCount++;
    _logTickCount++;

    if (_rosterTickCount <= 3 || _rosterTickCount % 30 == 0) {
        log_user("[ESP] tick=%d packet=%s count=%u failures=%d\n",
                 _rosterTickCount, packetOk ? "OK" : "FAIL",
                 packet.count, _consecutivePacketFailures);
    }

    if (packetOk) {
        _consecutivePacketFailures = 0;
        if (packet.count == 0) {
            _consecutiveEmptyRosters++;
        } else {
            _consecutiveEmptyRosters = 0;
        }
        esp_draw_overlay_update_packet(&packet);
    } else {
        _consecutivePacketFailures++;
        // Keep the last good snapshot through transient read failures. Clear only
        // after several confirmed empty polls (roughly 2.5 seconds).
        if (_consecutivePacketFailures >= 5) {
            ESPDrawPacket emptyPacket = {0};
            esp_draw_overlay_update_packet(&emptyPacket);
            _consecutivePacketFailures = 0;
        }
    }
}

#pragma mark - Stop

- (BOOL)prepareForCleanup {
    if (_currentStep > ESPStepIdle && _currentStep < ESPStepComplete) return NO;
    if (_workerTimer) {
        dispatch_source_cancel(_workerTimer);
        _workerTimer = nil;
    }
    // Drain pending reads before releasing their provider on the main thread.
    if (_workerQueue) dispatch_sync(_workerQueue, ^{});
    [self stopESP];
    esp_menu_overlay_stop_in_session();
    return YES;
}

- (void)stopESP {
    if (_cleanupInProgress) return;
    _cleanupInProgress = YES;
    log_user("[ESP] Stopping ESP session...\n");

    if (_workerTimer) {
        dispatch_source_cancel(_workerTimer);
        _workerTimer = nil;
    }

    // The timer cancellation is asynchronous. Drain the serial worker before
    // invalidating game state or shutting down its memory provider.
    if (_workerQueue) {
        dispatch_sync(_workerQueue, ^{});
    }

    esp_draw_overlay_stop_in_session();

    // RemoteCall owns injected/synthetic threads, exception ports, trojan
    // memory and shared-memory mappings. It must be torn down while KRW and
    // the target task are still valid, before releasing the memory provider.
    if (remote_call_has_local_state()) {
        int remotePid = remote_call_current_pid();
        // A respawned SpringBoard cannot service munmap/pthread_exit. Avoid
        // IPC in that case and release only local exception-port resources.
        BOOL targetAlive = remotePid > 0 && (kill(remotePid, 0) == 0 || errno == EPERM);
        int remoteCleanup = targetAlive ? destroy_remote_call() : (abandon_remote_call(), 0);
        log_user("[ESP] RemoteCall cleanup result=%d\n", remoteCleanup);
    }

    if (_frameBuilder) {
        [_frameBuilder reset];
        _frameBuilder = nil;
    }
    ModuleBase = 0;
    phantom_memory_set_provider(nil);

    if (_providerOwner) {
        [_providerOwner shutdown];
        _providerOwner = nil;
    }

    _espActive = NO;
    _currentStep = ESPStepIdle;
    _moduleRetryCount = 0;
    _rosterTickCount = 0;
    _logTickCount = 0;
    _consecutivePacketFailures = 0;
    _consecutiveEmptyRosters = 0;
    _readBackoffTicks = 0;

    log_user("[ESP] ESP session stopped\n");
    log_session_end();
    _cleanupInProgress = NO;
    [self reloadState];
}

#pragma mark - Unsupported Alert

- (void)presentUnsupportedAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Unsupported Device"
                         message:@"This device or iOS version is not supported."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentActivityLogWithCompletion:(void (^)(void))completion {
    UITabBarController *tbc = self.tabBarController;
    if (tbc && tbc.viewControllers.count > 1) {
        tbc.selectedIndex = 1;
    }
    if (completion) completion();
}

#pragma mark - Derived UI State

- (BOOL)ds_isActivating {
    return _currentStep > ESPStepIdle && _currentStep < ESPStepComplete;
}

- (UIImage *)ds_heroSymbol {
    if (_currentStep == ESPStepFailed)
        return [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
    if ([self ds_isActivating])
        return [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
    return [UIImage systemImageNamed:_espActive ? @"bolt.fill" : @"shield.lefthalf.filled"];
}

- (UIColor *)ds_heroColor {
    if (_currentStep == ESPStepFailed) return UIColor.systemRedColor;
    if ([self ds_isActivating]) return UIAccent();
    return _espActive ? DSLiveColor() : UIAccent();
}

- (NSString *)ds_chipText {
    if (_currentStep == ESPStepFailed) return @"FAILED";
    if ([self ds_isActivating]) return @"SYNCING";
    return _espActive ? @"LIVE" : @"READY";
}

- (UIColor *)ds_chipColor {
    if (_currentStep == ESPStepFailed) return UIColor.systemRedColor;
    if ([self ds_isActivating]) return UIAccent();
    return _espActive ? DSLiveColor() : UIColor.secondaryLabelColor;
}

// Pipeline tile state: returns (title, symbol, status, statusColor, tint).
- (NSArray *)ds_pipelineItem:(NSInteger)index {
    static NSArray *items;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        items = @[
            @[@"Kernel", @"cpu.fill"],
            @[@"Game",   @"externaldrive.fill"],
            @[@"Overlay", @"eye.fill"],
            @[@"Stream", @"dot.radiowave.left"],
        ];
    });

    NSString *status;
    UIColor *color;
    switch (index) {
        case 0: // Kernel access
            if (kexploit_krw_ready()) { status = @"Unlocked"; color = DSLiveColor(); }
            else { status = @"Locked"; color = UIColor.secondaryLabelColor; }
            break;
        case 1: // Game connection
            if (_providerOwner.isReady) { status = @"Connected"; color = DSLiveColor(); }
            else if ([self ds_isActivating]) { status = @"Scanning"; color = UIAccent(); }
            else { status = @"Offline"; color = UIColor.secondaryLabelColor; }
            break;
        case 2: // Overlay
            switch (esp_draw_overlay_state()) {
                case ESPDrawOverlayStateRunning:      status = @"Running"; color = DSLiveColor(); break;
                case ESPDrawOverlayStateInitializing: status = @"Booting"; color = UIAccent(); break;
                default:                              status = @"Offline"; color = UIColor.secondaryLabelColor; break;
            }
            break;
        default: // Packet stream
            if ([self ds_isActivating]) { status = @"Syncing"; color = UIAccent(); }
            else if (_espActive && _consecutivePacketFailures == 0) { status = @"Live"; color = DSLiveColor(); }
            else if (_espActive) { status = @"Retrying"; color = DSWarnColor(); }
            else { status = @"Idle"; color = UIColor.secondaryLabelColor; }
            break;
    }
    return @[items[index][0], items[index][1], status, color];
}

#pragma mark - Shared Cell Helpers

- (UIView *)ds_cardView {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = DSCardColor();
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = DSBorderColor().CGColor;
    return card;
}

- (UITableViewCell *)ds_plainCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.contentView.backgroundColor = UIColor.clearColor;
    return cell;
}

// Pins a card to the cell content view with the standard dashboard margins.
- (void)ds_pinCard:(UIView *)card inCell:(UITableViewCell *)cell top:(CGFloat)top bottom:(CGFloat)bottom {
    [cell.contentView addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:top],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-bottom],
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
    ]];
}

// Tinted rounded-square icon plate used across the pipeline/support cards.
- (UIView *)ds_iconPlate:(UIImage *)image size:(CGFloat)size tint:(UIColor *)tint symbolPoint:(CGFloat)point {
    UIView *plate = [[UIView alloc] init];
    plate.translatesAutoresizingMaskIntoConstraints = NO;
    plate.backgroundColor = [tint colorWithAlphaComponent:0.15];
    plate.layer.cornerRadius = size * 0.28;

    UIImageView *icon = [[UIImageView alloc] initWithImage:image];
    icon.tintColor = tint;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [plate addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [plate.widthAnchor constraintEqualToConstant:size],
        [plate.heightAnchor constraintEqualToConstant:size],
        [icon.centerXAnchor constraintEqualToAnchor:plate.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:plate.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:point * 1.4],
        [icon.heightAnchor constraintEqualToConstant:point * 1.4],
    ]];
    return plate;
}

#pragma mark - Hero Card

- (UITableViewCell *)heroCell {
    UITableViewCell *cell = [self ds_plainCell];
    UIView *card = [self ds_cardView];
    [self ds_pinCard:card inCell:cell top:8 bottom:6];

    // Eyebrow row: brand mark + live status chip.
    UIImageView *mark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"bolt.fill"]];
    mark.tintColor = UIAccent();
    mark.translatesAutoresizingMaskIntoConstraints = NO;
    [mark.widthAnchor constraintEqualToConstant:11].active = YES;
    [mark.heightAnchor constraintEqualToConstant:11].active = YES;

    UILabel *brand = DSCapsLabel(@"DSWUNITY  ·  EXTERNAL ENGINE", 10, UIFontWeightSemibold,
                                 UIColor.tertiaryLabelColor, 1.2);

    UIView *chipDot = DSDot(6, [self ds_chipColor]);
    if ([self ds_isActivating] || _espActive) DSAttachPulse(chipDot);
    UILabel *chipLabel = DSCapsLabel([self ds_chipText], 9.5, UIFontWeightBold, [self ds_chipColor], 0.8);
    UIStackView *chip = [[UIStackView alloc] initWithArrangedSubviews:@[chipDot, chipLabel]];
    chip.axis = UILayoutConstraintAxisHorizontal;
    chip.alignment = UIStackViewAlignmentCenter;
    chip.spacing = 5;
    chip.layoutMarginsRelativeArrangement = YES;
    chip.layoutMargins = UIEdgeInsetsMake(4, 9, 4, 9);
    chip.backgroundColor = [[self ds_chipColor] colorWithAlphaComponent:0.13];
    chip.layer.cornerRadius = 11;
    chip.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *eyebrow = [[UIStackView alloc] initWithArrangedSubviews:@[mark, brand, [[UIView alloc] init], chip]];
    eyebrow.axis = UILayoutConstraintAxisHorizontal;
    eyebrow.alignment = UIStackViewAlignmentCenter;
    eyebrow.spacing = 6;

    // Main row: gradient status icon + title/detail.
    UIColor *heroColor = [self ds_heroColor];
    UIColor *heroGradientEnd = _currentStep == ESPStepFailed
        ? [UIColor colorWithRed:0.95 green:0.45 blue:0.25 alpha:1.0]
        : UISecondaryAccent();

    DSGradientView *iconWrap = [[DSGradientView alloc] initWithFrame:CGRectZero];
    iconWrap.gradientColors = @[heroColor, heroGradientEnd];
    iconWrap.layer.cornerRadius = 26;
    iconWrap.layer.shadowColor = heroColor.CGColor;
    iconWrap.layer.shadowOpacity = 0.45;
    iconWrap.layer.shadowRadius = 10;
    iconWrap.layer.shadowOffset = CGSizeMake(0, 4);
    iconWrap.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *heroIcon = [[UIImageView alloc] initWithImage:[self ds_heroSymbol]];
    heroIcon.tintColor = UIColor.whiteColor;
    heroIcon.contentMode = UIViewContentModeScaleAspectFit;
    heroIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [iconWrap addSubview:heroIcon];
    [NSLayoutConstraint activateConstraints:@[
        [iconWrap.widthAnchor constraintEqualToConstant:52],
        [iconWrap.heightAnchor constraintEqualToConstant:52],
        [heroIcon.centerXAnchor constraintEqualToAnchor:iconWrap.centerXAnchor],
        [heroIcon.centerYAnchor constraintEqualToAnchor:iconWrap.centerYAnchor],
        [heroIcon.widthAnchor constraintEqualToConstant:24],
        [heroIcon.heightAnchor constraintEqualToConstant:24],
    ]];

    UILabel *title = DSLabel([self statusTitle], 20, UIFontWeightBold,
                             UIColor.labelColor);
    UILabel *detail = DSLabel([self statusDetail], 13, UIFontWeightRegular,
                              UIColor.secondaryLabelColor);
    detail.numberOfLines = 0;

    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[title, detail]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.alignment = UIStackViewAlignmentLeading;
    labels.spacing = 3;

    UIStackView *mainRow = [[UIStackView alloc] initWithArrangedSubviews:@[iconWrap, labels]];
    mainRow.axis = UILayoutConstraintAxisHorizontal;
    mainRow.alignment = UIStackViewAlignmentCenter;
    mainRow.spacing = 14;

    UIStackView *root = [[UIStackView alloc] initWithArrangedSubviews:@[eyebrow, mainRow]];
    root.axis = UILayoutConstraintAxisVertical;
    root.alignment = UIStackViewAlignmentFill;
    root.spacing = 16;
    root.layoutMarginsRelativeArrangement = YES;
    root.layoutMargins = UIEdgeInsetsMake(16, 16, 16, 16);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:card.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
    ]];
    return cell;
}

#pragma mark - Action Card

- (UITableViewCell *)actionCell {
    UITableViewCell *cell = [self ds_plainCell];

    BOOL activating = [self ds_isActivating];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.layer.cornerRadius = 16;
    button.layer.shadowColor = UIAccent().CGColor;
    button.layer.shadowOpacity = _espActive ? 0.0 : 0.35;
    button.layer.shadowRadius = 12;
    button.layer.shadowOffset = CGSizeMake(0, 5);

    DSGradientView *fill = [[DSGradientView alloc] init];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.gradientColors = _espActive
        ? @[[UIColor colorWithRed:0.98 green:0.30 blue:0.34 alpha:1.0],
            [UIColor colorWithRed:0.95 green:0.50 blue:0.25 alpha:1.0]]
        : @[UIAccent(), UISecondaryAccent()];
    fill.layer.cornerRadius = 16;
    fill.clipsToBounds = YES;
    fill.userInteractionEnabled = NO;
    [button addSubview:fill];

    if (!activating) {
        NSString *caption = [self actionTitle].uppercaseString;
        NSMutableAttributedString *styled = [[NSMutableAttributedString alloc]
            initWithString:caption
                attributes:@{ NSFontAttributeName      : [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold],
                              NSForegroundColorAttributeName : UIColor.whiteColor,
                              NSKernAttributeName      : @(1.2) }];
        [button setAttributedTitle:styled forState:UIControlStateNormal];
        UIImage *glyph = [UIImage systemImageNamed:_espActive ? @"stop.fill" : @"play.fill"];
        [button setImage:glyph forState:UIControlStateNormal];
        button.imageEdgeInsets = UIEdgeInsetsMake(0, -6, 0, 6);
        button.titleEdgeInsets = UIEdgeInsetsMake(0, 6, 0, -6);
    }
    [button addTarget:self action:@selector(ds_buttonPressDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(ds_buttonPressRelease:)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    [button addTarget:self action:@selector(toggleESP) forControlEvents:UIControlEventTouchUpInside];

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = UIColor.whiteColor;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    spinner.hidden = !activating;
    if (activating) [spinner startAnimating];
    [button addSubview:spinner];

    UILabel *hint = DSLabel(_espActive
        ? @"Stops the session and releases all resources."
        : @"Open Free Fire before starting the session.",
        12, UIFontWeightRegular, UIColor.tertiaryLabelColor);
    hint.textAlignment = NSTextAlignmentCenter;

    UIStackView *root = [[UIStackView alloc] initWithArrangedSubviews:@[button, hint]];
    root.axis = UILayoutConstraintAxisVertical;
    root.alignment = UIStackViewAlignmentFill;
    root.spacing = 9;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:2],
        [root.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [root.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [root.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [button.heightAnchor constraintEqualToConstant:54],
        [spinner.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
    ]];
    return cell;
}

- (void)ds_buttonPressDown:(UIButton *)sender {
    [UIView animateWithDuration:0.1 animations:^{
        sender.transform = CGAffineTransformMakeScale(0.97, 0.97);
        sender.alpha = 0.85;
    }];
}

- (void)ds_buttonPressRelease:(UIButton *)sender {
    [UIView animateWithDuration:0.18 animations:^{
        sender.transform = CGAffineTransformIdentity;
        sender.alpha = 1.0;
    }];
}

#pragma mark - Pipeline Grid

- (UITableViewCell *)pipelineCellForRow:(NSInteger)row {
    UITableViewCell *cell = [self ds_plainCell];

    UIView *left  = [self ds_pipelineCard:(row * 2)];
    UIView *right = [self ds_pipelineCard:(row * 2 + 1)];

    UIStackView *grid = [[UIStackView alloc] initWithArrangedSubviews:@[left, right]];
    grid.axis = UILayoutConstraintAxisHorizontal;
    grid.alignment = UIStackViewAlignmentFill;
    grid.distribution = UIStackViewDistributionFillEqually;
    grid.spacing = 10;
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:5],
        [grid.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-5],
        [grid.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [grid.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
    ]];
    return cell;
}

- (UIView *)ds_pipelineCard:(NSInteger)index {
    NSArray *state = [self ds_pipelineItem:index];
    NSString *title = state[0];
    UIImage *symbol = [UIImage systemImageNamed:state[1]];
    NSString *status = state[2];
    UIColor *color = state[3];

    UIView *card = [self ds_cardView];
    UIView *plate = [self ds_iconPlate:symbol size:34 tint:UIAccent() symbolPoint:15];

    UILabel *titleLabel = DSLabel(title, 13, UIFontWeightSemibold, UIColor.labelColor);
    UIView *statusDot = DSDot(6, color);
    if ([color isEqual:DSLiveColor()]) DSAttachPulse(statusDot);
    UILabel *statusLabel = DSLabel(status, 12, UIFontWeightMedium, color);

    UIStackView *statusRow = [[UIStackView alloc] initWithArrangedSubviews:@[statusDot, statusLabel]];
    statusRow.axis = UILayoutConstraintAxisHorizontal;
    statusRow.alignment = UIStackViewAlignmentCenter;
    statusRow.spacing = 5;

    UIStackView *root = [[UIStackView alloc] initWithArrangedSubviews:@[plate, titleLabel, statusRow]];
    root.axis = UILayoutConstraintAxisVertical;
    root.alignment = UIStackViewAlignmentLeading;
    root.spacing = 8;
    root.layoutMarginsRelativeArrangement = YES;
    root.layoutMargins = UIEdgeInsetsMake(12, 12, 12, 12);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:card.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
    ]];
    return card;
}

#pragma mark - Support Card

- (UITableViewCell *)supportCell {
    UITableViewCell *cell = [self ds_plainCell];
    UIView *card = [self ds_cardView];
    [self ds_pinCard:card inCell:cell top:5 bottom:6];

    UIView *plate = [self ds_iconPlate:[UIImage systemImageNamed:@"paperplane.fill"]
                                  size:36 tint:DSTealColor() symbolPoint:16];

    UILabel *title = DSLabel(@"Telegram Support", 15, UIFontWeightSemibold, UIColor.labelColor);
    UILabel *handle = DSLabel(DSSupportHandle, 12, UIFontWeightRegular, UIColor.secondaryLabelColor);
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[title, handle]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.alignment = UIStackViewAlignmentLeading;
    labels.spacing = 2;

    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.forward"]];
    chevron.tintColor = UIColor.tertiaryLabelColor;
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [chevron.widthAnchor constraintEqualToConstant:12].active = YES;
    [chevron.heightAnchor constraintEqualToConstant:16].active = YES;

    UIStackView *root = [[UIStackView alloc] initWithArrangedSubviews:@[plate, labels, [[UIView alloc] init], chevron]];
    root.axis = UILayoutConstraintAxisHorizontal;
    root.alignment = UIStackViewAlignmentCenter;
    root.spacing = 12;
    root.layoutMarginsRelativeArrangement = YES;
    root.layoutMargins = UIEdgeInsetsMake(11, 12, 11, 14);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:card.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
    ]];
    return cell;
}

#pragma mark - Table View

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return ESPSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == ESPSectionPipeline ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == ESPSectionPipeline ? @"Pipeline" : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return section == ESPSectionSupport ? @"DSWUnity · Native External Engine · t.me/duydzne" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case ESPSectionHero:     return [self heroCell];
        case ESPSectionAction:   return [self actionCell];
        case ESPSectionPipeline: return [self pipelineCellForRow:indexPath.row];
        default:                 return [self supportCell];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != ESPSectionSupport) return;
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:DSSupportURL]
                                       options:@{}
                             completionHandler:nil];
}

@end
