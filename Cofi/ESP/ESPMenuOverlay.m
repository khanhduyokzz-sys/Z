#import "ESPMenuOverlay.h"
#import "ESPMenuRemoteEntry.h"
#import "../SettingsViewController.h"
#import "../TaskRop/RemoteCall.h"
#import "../TaskRop/VM.h"

#pragma mark - Remote ObjC helpers

static uint64_t rc_cls(const char *name) {
    return do_remote_call_stable(100, "objc_getClass", (uint64_t)name, 0, 0, 0, 0, 0, 0, 0);
}

static uint64_t rc_sel(const char *name) {
    return do_remote_call_stable(100, "sel_registerName", (uint64_t)name, 0, 0, 0, 0, 0, 0, 0);
}

static uint64_t rc_msg0(uint64_t obj, const char *sel) {
    return do_remote_call_stable(200, "objc_msgSend", obj, rc_sel(sel), 0, 0, 0, 0, 0, 0);
}

static uint64_t rc_msg1(uint64_t obj, const char *sel, uint64_t a1) {
    return do_remote_call_stable(200, "objc_msgSend", obj, rc_sel(sel), a1, 0, 0, 0, 0, 0);
}

static uint64_t rc_msg2(uint64_t obj, const char *sel, uint64_t a1, uint64_t a2) {
    return do_remote_call_stable(200, "objc_msgSend", obj, rc_sel(sel), a1, a2, 0, 0, 0, 0);
}

static uint64_t rc_msg3(uint64_t obj, const char *sel, uint64_t a1, uint64_t a2, uint64_t a3) {
    return do_remote_call_stable(200, "objc_msgSend", obj, rc_sel(sel), a1, a2, a3, 0, 0, 0);
}

static uint64_t rc_msg4(uint64_t obj, const char *sel, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
    return do_remote_call_stable(200, "objc_msgSend", obj, rc_sel(sel), a1, a2, a3, a4, 0, 0);
}

static uint64_t rc_alloc(const char *className) {
    uint64_t cls = rc_cls(className);
    if (!cls) return 0;
    return rc_msg0(cls, "alloc");
}

static uint64_t rc_alloc_init(const char *className) {
    uint64_t obj = rc_alloc(className);
    if (!obj) return 0;
    return rc_msg0(obj, "init");
}

static uint64_t rc_remote_str(const char *cstr) {
    if (!cstr) return 0;
    uint64_t trojan = remote_call_trojan_mem();
    if (!trojan) return 0;
    remote_writeStr(trojan, cstr);
    uint64_t nsStringCls = rc_cls("NSString");
    uint64_t sel = rc_sel("stringWithUTF8String:");
    return do_remote_call_stable(200, "objc_msgSend", nsStringCls, sel, trojan, 0, 0, 0, 0, 0);
}

typedef union {
    float f;
    uint64_t u;
} FloatBits;

static uint64_t float_to_bits(float v) {
    FloatBits fb;
    fb.u = 0;
    fb.f = v;
    return fb.u;
}

typedef union {
    double d;
    uint64_t u;
} DoubleBits;

static uint64_t double_to_bits(double v) {
    DoubleBits db;
    db.d = v;
    return db.u;
}

#pragma mark - CGRect packing

typedef struct {
    double x, y, w, h;
} RCGRect;

static void rc_write_cgrect(uint64_t addr, RCGRect r) {
    remote_write(addr, &r.x, sizeof(double));
    remote_write(addr + 8, &r.y, sizeof(double));
    remote_write(addr + 16, &r.w, sizeof(double));
    remote_write(addr + 24, &r.h, sizeof(double));
}

#pragma mark - Global state

static ESPMenuOverlayState gESPMenuState = ESPMenuOverlayStateIdle;

static uint64_t gESPMenuApplication = 0;
static uint64_t gESPMenuWindow = 0;
static uint64_t gESPMenuTriggerWindow = 0;
static uint64_t gESPMenuRoot = 0;
static uint64_t gESPMenuBackdrop = 0;
static uint64_t gESPMenuPanel = 0;
static uint64_t gESPMenuScroll = 0;
static uint64_t gESPMenuTitle = 0;
static uint64_t gESPMenuTriggerButton = 0;

static uint64_t gESPMenuTriggerPan = 0;
static uint64_t gESPMenuTriggerSingleTap = 0;
static uint64_t gESPMenuTriggerDoubleTap = 0;
static uint64_t gESPMenuTriggerDragIndex = 0;
static uint64_t gESPMenuTriggerDoubleTapIndex = 0;

static uint64_t gESPMenuMailbox = 0;
static uint64_t gESPMenuMailboxBytes = 0;
static uint64_t gESPMenuMailboxLength = 0;
static uint64_t gESPMenuDirtyByte = 0;
static uint64_t gESPMenuVisibleByte = 0;
static uint64_t gESPMenuHiddenByte = 0;

static uint64_t gESPMenuInitialOwnership = 0;
static BOOL gESPMenuPhysicallySuspended = NO;
static double gESPMenuRawWidth = 0;
static double gESPMenuRawHeight = 0;
static double gESPMenuTriggerX = 0;
static double gESPMenuTriggerY = 0;
static BOOL gESPMenuTriggerHasCustomPosition = NO;
static long long gESPMenuOrientation = 0;

static NSMutableArray<ESPMenuRemoteEntry *> *gESPMenuEntries = nil;
static NSMutableArray *gESPMenuActionControls = nil;

#pragma mark - Helpers

static uint64_t esp_menu_color(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    uint64_t cls = rc_cls("UIColor");
    uint64_t sel = rc_sel("colorWithRed:green:blue:alpha:");
    return do_remote_call_stable(200, "objc_msgSend", cls, sel,
                                 double_to_bits(r), double_to_bits(g),
                                 double_to_bits(b), double_to_bits(a), 0, 0);
}

static uint64_t esp_menu_color_white_alpha(CGFloat white, CGFloat alpha) {
    uint64_t cls = rc_cls("UIColor");
    uint64_t sel = rc_sel("colorWithWhite:alpha:");
    return do_remote_call_stable(200, "objc_msgSend", cls, sel,
                                 double_to_bits(white), double_to_bits(alpha), 0, 0, 0, 0);
}

static uint64_t esp_menu_font(const char *name, CGFloat size) {
    if (name) {
        uint64_t nsName = rc_remote_str(name);
        uint64_t cls = rc_cls("UIFont");
        uint64_t sel = rc_sel("fontWithName:size:");
        return do_remote_call_stable(200, "objc_msgSend", cls, sel,
                                     nsName, double_to_bits(size), 0, 0, 0, 0);
    }
    uint64_t cls = rc_cls("UIFont");
    uint64_t sel = rc_sel("systemFontOfSize:");
    return do_remote_call_stable(200, "objc_msgSend", cls, sel,
                                 double_to_bits(size), 0, 0, 0, 0, 0);
}

static uint64_t esp_menu_bold_font(CGFloat size) {
    uint64_t cls = rc_cls("UIFont");
    uint64_t sel = rc_sel("boldSystemFontOfSize:");
    return do_remote_call_stable(200, "objc_msgSend", cls, sel,
                                 double_to_bits(size), 0, 0, 0, 0, 0);
}

static void esp_menu_release_remote_obj(uint64_t obj) {
    if (obj)
        rc_msg0(obj, "release");
}

static uint64_t esp_menu_create_view(RCGRect frame) {
    uint64_t view = rc_alloc("UIView");
    if (!view) return 0;

    uint64_t trojan = remote_call_trojan_mem();
    rc_write_cgrect(trojan, frame);
    uint64_t sel = rc_sel("initWithFrame:");
    view = do_remote_call_stable(200, "objc_msgSend", view, sel,
                                 trojan, 0, 0, 0, 0, 0);
    return view;
}

static uint64_t esp_menu_create_label(RCGRect frame, const char *text, CGFloat fontSize, uint64_t color) {
    uint64_t label = rc_alloc("UILabel");
    if (!label) return 0;

    uint64_t trojan = remote_call_trojan_mem();
    rc_write_cgrect(trojan, frame);
    uint64_t sel = rc_sel("initWithFrame:");
    label = do_remote_call_stable(200, "objc_msgSend", label, sel,
                                  trojan, 0, 0, 0, 0, 0);
    if (!label) return 0;

    if (text) {
        uint64_t nsText = rc_remote_str(text);
        rc_msg1(label, "setText:", nsText);
    }

    uint64_t font = esp_menu_font(NULL, fontSize);
    rc_msg1(label, "setFont:", font);

    if (color)
        rc_msg1(label, "setTextColor:", color);

    return label;
}

static void esp_menu_set_frame(uint64_t view, RCGRect frame) {
    if (!view) return;
    uint64_t trojan = remote_call_trojan_mem();
    rc_write_cgrect(trojan, frame);
    uint64_t sel = rc_sel("setFrame:");
    do_remote_call_stable(200, "objc_msgSend", view, sel, trojan, 0, 0, 0, 0, 0);
}

static void esp_menu_set_label_text(uint64_t label, const char *text) {
    if (!label) return;
    uint64_t nsText = rc_remote_str(text);
    rc_msg1(label, "setText:", nsText);
}

#pragma mark - Key Window

static uint64_t esp_menu_key_window(void) {
    uint64_t app = rc_msg0(rc_cls("UIApplication"), "sharedApplication");
    if (!app) return 0;

    uint64_t scenes = rc_msg0(app, "connectedScenes");
    uint64_t enumerator = rc_msg0(scenes, "objectEnumerator");
    uint64_t scene = 0;
    while ((scene = rc_msg0(enumerator, "nextObject")) != 0) {
        uint64_t windows = rc_msg0(scene, "windows");
        uint64_t winEnum = rc_msg0(windows, "objectEnumerator");
        uint64_t win = 0;
        while ((win = rc_msg0(winEnum, "nextObject")) != 0) {
            uint64_t isKey = rc_msg0(win, "isKeyWindow");
            if (isKey)
                return win;
        }
    }
    return 0;
}

static void esp_menu_read_window_bounds(double *outW, double *outH) {
    uint64_t keyWin = esp_menu_key_window();
    if (!keyWin) {
        *outW = 393; *outH = 852;
        return;
    }
    uint64_t trojan = remote_call_trojan_mem();
    uint64_t sel = rc_sel("bounds");
    do_remote_call_stable(200, "objc_msgSend", keyWin, sel, trojan, 0, 0, 0, 0, 0);
    remote_read(trojan + 16, outW, sizeof(double));
    remote_read(trojan + 24, outH, sizeof(double));
    if (*outW <= 0) *outW = 393;
    if (*outH <= 0) *outH = 852;
}

#pragma mark - Mailbox

static void esp_menu_create_mailbox(NSUInteger entryCount) {
    gESPMenuMailboxLength = entryCount + 4;
    uint64_t len = gESPMenuMailboxLength;
    gESPMenuMailbox = do_remote_call_stable(500, "malloc", len, 0, 0, 0, 0, 0, 0, 0);
    if (gESPMenuMailbox)
        do_remote_call_stable(200, "memset", gESPMenuMailbox, 0, len, 0, 0, 0, 0, 0);

    gESPMenuMailboxBytes = gESPMenuMailbox;
    gESPMenuDirtyByte = gESPMenuMailbox + 0;
    gESPMenuVisibleByte = gESPMenuMailbox + 1;
    gESPMenuHiddenByte = gESPMenuMailbox + 2;
}

#pragma mark - Build Rows

static void esp_menu_build_rows(void) {
    if (!gESPMenuEntries)
        gESPMenuEntries = [NSMutableArray new];
    if (!gESPMenuActionControls)
        gESPMenuActionControls = [NSMutableArray new];

    [gESPMenuEntries removeAllObjects];
    [gESPMenuActionControls removeAllObjects];

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    typedef struct {
        const char *key;
        const char *kind;
        long long itemCount;
        float minVal;
        float maxVal;
    } EntryDef;

    EntryDef defs[] = {
        { "renew.drawLine",              "toggle", 0,    0,     0 },
        { "renew.drawBox",               "toggle", 0,    0,     0 },
        { "renew.drawHealth",            "toggle", 0,    0,     0 },
        { "renew.drawName",              "toggle", 0,    0,     0 },
        { "renew.drawDistance",          "toggle", 0,    0,     0 },
        { "renew.drawPlayerCount",       "toggle", 0,    0,     0 },
        { "renew.espRateTick",           "stepper",0,    1,     30 },
        // Aim engine (VIP standard) — same renew.* keys as the settings UI.
        { "renew.aimbot",                "toggle", 0,    0,     0 },
        { "renew.showFov",               "toggle", 0,    0,     0 },
        { "renew.aimLine",               "toggle", 0,    0,     0 },
        { "renew.aimFov",                "slider", 0,    5,     500 },
        { "renew.aimSpeed",              "slider", 0,    100,   2000 },
        { "renew.aimPos",                "segmented", 4, 0,     0 },
        { "renew.aimTrigger",            "segmented", 4, 0,     0 },
        { "renew.aimIgnoreBot",          "toggle", 0,    0,     0 },
        { "renew.aimIgnoreKnock",        "toggle", 0,    0,     0 },
        { "renew.aimCheckVisible",       "toggle", 0,    0,     0 },
    };

    NSUInteger count = sizeof(defs) / sizeof(defs[0]);
    esp_menu_create_mailbox(count);

    double panelW = gESPMenuRawWidth * 0.85;
    double rowH = 44.0;
    double rowY = 48.0;
    double labelX = 16.0;
    double controlX = panelW - 120.0;
    double controlW = 100.0;

    for (NSUInteger i = 0; i < count; i++) {
        EntryDef *def = &defs[i];
        ESPMenuRemoteEntry *entry = [[ESPMenuRemoteEntry alloc] init];
        entry.key = [NSString stringWithUTF8String:def->key];
        entry.kind = [NSString stringWithUTF8String:def->kind];
        entry.itemCount = def->itemCount;
        entry.minimumValue = def->minVal;
        entry.maximumValue = def->maxVal;
        entry.dirtyIndex = i + 4;

        double y = rowY + i * rowH;

        const char *displayName = strrchr(def->key, '.') + 1;

        uint64_t rowLabel = esp_menu_create_label(
            (RCGRect){labelX, y + 10, controlX - labelX - 8, 24},
            displayName, 14.0,
            esp_menu_color_white_alpha(1.0, 0.9)
        );
        rc_msg1(gESPMenuScroll, "addSubview:", rowLabel);

        if (strcmp(def->kind, "toggle") == 0) {
            BOOL on = [ud boolForKey:entry.key];
            uint64_t sw = rc_alloc_init("UISwitch");
            esp_menu_set_frame(sw, (RCGRect){controlX, y + 6, 51, 31});
            rc_msg1(sw, "setOn:", (uint64_t)on);
            uint64_t teal = esp_menu_color(0.0, 0.71, 0.68, 1.0);
            rc_msg1(sw, "setOnTintColor:", teal);
            rc_msg1(gESPMenuScroll, "addSubview:", sw);
            entry.control = sw;
        }
        else if (strcmp(def->kind, "slider") == 0) {
            uint64_t slider = rc_alloc("UISlider");
            uint64_t trojan = remote_call_trojan_mem();
            rc_write_cgrect(trojan, (RCGRect){controlX - 40, y + 10, controlW + 40, 24});
            slider = do_remote_call_stable(200, "objc_msgSend", slider,
                                           rc_sel("initWithFrame:"), trojan, 0, 0, 0, 0, 0);
            rc_msg1(slider, "setMinimumValue:", float_to_bits(def->minVal));
            rc_msg1(slider, "setMaximumValue:", float_to_bits(def->maxVal));
            float curVal = [ud floatForKey:entry.key];
            rc_msg1(slider, "setValue:", float_to_bits(curVal));
            uint64_t teal = esp_menu_color(0.0, 0.71, 0.68, 1.0);
            rc_msg1(slider, "setMinimumTrackTintColor:", teal);
            rc_msg1(gESPMenuScroll, "addSubview:", slider);
            entry.control = slider;

            uint64_t valLabel = esp_menu_create_label(
                (RCGRect){controlX + controlW + 8, y + 12, 50, 20},
                [[NSString stringWithFormat:@"%.1f", curVal] UTF8String],
                12.0, esp_menu_color_white_alpha(1.0, 0.6)
            );
            rc_msg1(gESPMenuScroll, "addSubview:", valLabel);
            entry.valueLabel = valLabel;
        }
        else if (strcmp(def->kind, "segmented") == 0) {
            NSInteger val = [ud integerForKey:entry.key];
            uint64_t items = rc_alloc_init("NSMutableArray");
            for (long long j = 0; j < def->itemCount; j++) {
                NSString *itemTitle = [NSString stringWithFormat:@"%lld", j];
                uint64_t nsItem = rc_remote_str([itemTitle UTF8String]);
                rc_msg1(items, "addObject:", nsItem);
            }
            uint64_t seg = rc_alloc("UISegmentedControl");
            seg = rc_msg1(seg, "initWithItems:", items);
            esp_menu_set_frame(seg, (RCGRect){controlX - 20, y + 8, controlW + 20, 28});
            rc_msg1(seg, "setSelectedSegmentIndex:", (uint64_t)val);
            rc_msg1(gESPMenuScroll, "addSubview:", seg);
            entry.control = seg;
        }
        else if (strcmp(def->kind, "stepper") == 0) {
            NSInteger val = [ud integerForKey:entry.key];
            uint64_t stepper = rc_alloc_init("UIStepper");
            esp_menu_set_frame(stepper, (RCGRect){controlX, y + 6, 94, 32});
            rc_msg1(stepper, "setMinimumValue:", double_to_bits((double)def->minVal));
            rc_msg1(stepper, "setMaximumValue:", double_to_bits((double)def->maxVal));
            rc_msg1(stepper, "setStepValue:", double_to_bits(1.0));
            rc_msg1(stepper, "setValue:", double_to_bits((double)val));
            rc_msg1(gESPMenuScroll, "addSubview:", stepper);
            entry.control = stepper;

            uint64_t valLabel = esp_menu_create_label(
                (RCGRect){controlX + 100, y + 12, 40, 20},
                [[NSString stringWithFormat:@"%ld", (long)val] UTF8String],
                12.0, esp_menu_color_white_alpha(1.0, 0.6)
            );
            rc_msg1(gESPMenuScroll, "addSubview:", valLabel);
            entry.valueLabel = valLabel;
        }

        [gESPMenuEntries addObject:entry];
    }

    double contentH = rowY + count * rowH + 20;
    uint64_t trojan = remote_call_trojan_mem();
    double zero = 0;
    remote_write(trojan, &zero, sizeof(double));
    remote_write(trojan + 8, &contentH, sizeof(double));
    uint64_t sel = rc_sel("setContentSize:");
    do_remote_call_stable(200, "objc_msgSend", gESPMenuScroll, sel, trojan, 0, 0, 0, 0, 0);
}

#pragma mark - Layout

static void esp_menu_layout_windows(void) {
    esp_menu_read_window_bounds(&gESPMenuRawWidth, &gESPMenuRawHeight);

    double panelW = gESPMenuRawWidth * 0.85;
    double panelH = gESPMenuRawHeight * 0.70;
    double panelX = (gESPMenuRawWidth - panelW) / 2.0;
    double panelY = (gESPMenuRawHeight - panelH) / 2.0;

    esp_menu_set_frame(gESPMenuWindow, (RCGRect){0, 0, gESPMenuRawWidth, gESPMenuRawHeight});
    esp_menu_set_frame(gESPMenuRoot, (RCGRect){0, 0, gESPMenuRawWidth, gESPMenuRawHeight});
    esp_menu_set_frame(gESPMenuBackdrop, (RCGRect){0, 0, gESPMenuRawWidth, gESPMenuRawHeight});
    esp_menu_set_frame(gESPMenuPanel, (RCGRect){panelX, panelY, panelW, panelH});
    esp_menu_set_frame(gESPMenuScroll, (RCGRect){0, 44, panelW, panelH - 44});
    esp_menu_set_frame(gESPMenuTitle, (RCGRect){16, 10, panelW - 32, 28});

    if (!gESPMenuTriggerHasCustomPosition) {
        gESPMenuTriggerX = gESPMenuRawWidth - 60;
        gESPMenuTriggerY = gESPMenuRawHeight * 0.4;
    }
    esp_menu_set_frame(gESPMenuTriggerWindow, (RCGRect){0, 0, gESPMenuRawWidth, gESPMenuRawHeight});
    esp_menu_set_frame(gESPMenuTriggerButton, (RCGRect){gESPMenuTriggerX, gESPMenuTriggerY, 44, 44});
}

#pragma mark - Visibility

void esp_menu_apply_physical_visibility(BOOL visible) {
    if (gESPMenuWindow) {
        rc_msg1(gESPMenuWindow, "setHidden:", (uint64_t)!visible);
        if (gESPMenuVisibleByte)
            remote_write(gESPMenuVisibleByte, &(uint8_t){visible ? 1 : 0}, 1);
        if (gESPMenuHiddenByte)
            remote_write(gESPMenuHiddenByte, &(uint8_t){visible ? 0 : 1}, 1);
    }
    gESPMenuPhysicallySuspended = !visible;
}

#pragma mark - Initialize

ESPMenuOverlayState esp_menu_overlay_state(void) {
    return gESPMenuState;
}

int esp_menu_overlay_initialize_in_session(void) {
    if (gESPMenuState != ESPMenuOverlayStateIdle)
        return -1;

    if (!remote_call_has_local_state() || !remote_call_current_success())
        return -2;

    gESPMenuState = ESPMenuOverlayStateInitializing;

    gESPMenuApplication = rc_msg0(rc_cls("UIApplication"), "sharedApplication");
    if (!gESPMenuApplication) {
        gESPMenuState = ESPMenuOverlayStateIdle;
        return -3;
    }

    esp_menu_read_window_bounds(&gESPMenuRawWidth, &gESPMenuRawHeight);

    // Main menu window (windowLevel = 10000001)
    uint64_t scenes = rc_msg0(gESPMenuApplication, "connectedScenes");
    uint64_t sceneEnum = rc_msg0(scenes, "objectEnumerator");
    uint64_t windowScene = rc_msg0(sceneEnum, "nextObject");

    gESPMenuWindow = rc_alloc("UIWindow");
    gESPMenuWindow = rc_msg1(gESPMenuWindow, "initWithWindowScene:", windowScene);
    rc_msg1(gESPMenuWindow, "setWindowLevel:", double_to_bits(10000001.0));
    rc_msg1(gESPMenuWindow, "setHidden:", 1);
    uint64_t clearColor = rc_msg0(rc_cls("UIColor"), "clearColor");
    rc_msg1(gESPMenuWindow, "setBackgroundColor:", clearColor);
    rc_msg0(gESPMenuWindow, "makeKeyAndVisible");
    rc_msg1(gESPMenuWindow, "setHidden:", 1);

    // Root view
    gESPMenuRoot = esp_menu_create_view((RCGRect){0, 0, gESPMenuRawWidth, gESPMenuRawHeight});
    rc_msg1(gESPMenuRoot, "setBackgroundColor:", clearColor);
    rc_msg1(gESPMenuWindow, "addSubview:", gESPMenuRoot);

    // Backdrop (dark blur)
    uint64_t blurEffect = rc_msg1(rc_cls("UIBlurEffect"), "effectWithStyle:", 2); // UIBlurEffectStyleDark
    gESPMenuBackdrop = rc_msg1(rc_alloc("UIVisualEffectView"), "initWithEffect:", blurEffect);
    esp_menu_set_frame(gESPMenuBackdrop, (RCGRect){0, 0, gESPMenuRawWidth, gESPMenuRawHeight});
    rc_msg1(gESPMenuRoot, "addSubview:", gESPMenuBackdrop);

    // Panel (rounded card)
    double panelW = gESPMenuRawWidth * 0.85;
    double panelH = gESPMenuRawHeight * 0.70;
    double panelX = (gESPMenuRawWidth - panelW) / 2.0;
    double panelY = (gESPMenuRawHeight - panelH) / 2.0;

    gESPMenuPanel = esp_menu_create_view((RCGRect){panelX, panelY, panelW, panelH});
    uint64_t panelBg = esp_menu_color_white_alpha(0.12, 0.95);
    rc_msg1(gESPMenuPanel, "setBackgroundColor:", panelBg);
    uint64_t panelLayer = rc_msg0(gESPMenuPanel, "layer");
    rc_msg1(panelLayer, "setCornerRadius:", double_to_bits(16.0));
    rc_msg1(panelLayer, "setMasksToBounds:", 1);
    rc_msg1(gESPMenuRoot, "addSubview:", gESPMenuPanel);

    // Title label
    gESPMenuTitle = esp_menu_create_label(
        (RCGRect){16, 10, panelW - 32, 28},
        "DSWUnity ESP Menu",
        17.0,
        esp_menu_color_white_alpha(1.0, 1.0)
    );
    uint64_t boldFont = esp_menu_bold_font(17.0);
    rc_msg1(gESPMenuTitle, "setFont:", boldFont);
    rc_msg1(gESPMenuPanel, "addSubview:", gESPMenuTitle);

    // Separator
    uint64_t sep = esp_menu_create_view((RCGRect){0, 43, panelW, 1});
    rc_msg1(sep, "setBackgroundColor:", esp_menu_color_white_alpha(1.0, 0.15));
    rc_msg1(gESPMenuPanel, "addSubview:", sep);

    // Scroll view
    gESPMenuScroll = rc_alloc("UIScrollView");
    uint64_t trojan = remote_call_trojan_mem();
    rc_write_cgrect(trojan, (RCGRect){0, 44, panelW, panelH - 44});
    gESPMenuScroll = do_remote_call_stable(200, "objc_msgSend", gESPMenuScroll,
                                           rc_sel("initWithFrame:"), trojan, 0, 0, 0, 0, 0);
    rc_msg1(gESPMenuScroll, "setBackgroundColor:", clearColor);
    rc_msg1(gESPMenuPanel, "addSubview:", gESPMenuScroll);

    // Build control rows
    esp_menu_build_rows();

    // Trigger window (always on top, separate window)
    gESPMenuTriggerWindow = rc_alloc("UIWindow");
    gESPMenuTriggerWindow = rc_msg1(gESPMenuTriggerWindow, "initWithWindowScene:", windowScene);
    rc_msg1(gESPMenuTriggerWindow, "setWindowLevel:", double_to_bits(10000002.0));
    rc_msg1(gESPMenuTriggerWindow, "setBackgroundColor:", clearColor);
    rc_msg1(gESPMenuTriggerWindow, "setUserInteractionEnabled:", 1);

    // Trigger button
    if (!gESPMenuTriggerHasCustomPosition) {
        gESPMenuTriggerX = gESPMenuRawWidth - 60;
        gESPMenuTriggerY = gESPMenuRawHeight * 0.4;
    }

    gESPMenuTriggerButton = esp_menu_create_view((RCGRect){gESPMenuTriggerX, gESPMenuTriggerY, 44, 44});
    uint64_t triggerBg = esp_menu_color(0.0, 0.71, 0.68, 0.85);
    rc_msg1(gESPMenuTriggerButton, "setBackgroundColor:", triggerBg);
    uint64_t trigLayer = rc_msg0(gESPMenuTriggerButton, "layer");
    rc_msg1(trigLayer, "setCornerRadius:", double_to_bits(22.0));
    rc_msg1(gESPMenuTriggerButton, "setUserInteractionEnabled:", 1);
    rc_msg1(gESPMenuTriggerWindow, "addSubview:", gESPMenuTriggerButton);

    // Trigger icon label (⊕)
    uint64_t trigIcon = esp_menu_create_label(
        (RCGRect){0, 0, 44, 44},
        "⊕", 22.0,
        esp_menu_color_white_alpha(1.0, 1.0)
    );
    rc_msg1(trigIcon, "setTextAlignment:", 1); // NSTextAlignmentCenter
    rc_msg1(gESPMenuTriggerButton, "addSubview:", trigIcon);

    // Gesture recognizers on trigger
    // Single tap → toggle menu visibility
    gESPMenuTriggerSingleTap = rc_alloc_init("UITapGestureRecognizer");
    rc_msg1(gESPMenuTriggerSingleTap, "setNumberOfTapsRequired:", 1);
    rc_msg1(gESPMenuTriggerButton, "addGestureRecognizer:", gESPMenuTriggerSingleTap);

    // Double tap → quick ghost
    gESPMenuTriggerDoubleTap = rc_alloc_init("UITapGestureRecognizer");
    rc_msg1(gESPMenuTriggerDoubleTap, "setNumberOfTapsRequired:", 2);
    rc_msg1(gESPMenuTriggerButton, "addGestureRecognizer:", gESPMenuTriggerDoubleTap);

    // Single tap requires double tap to fail
    rc_msg1(gESPMenuTriggerSingleTap, "requireGestureRecognizerToFail:", gESPMenuTriggerDoubleTap);

    // Pan → drag trigger button
    gESPMenuTriggerPan = rc_alloc_init("UIPanGestureRecognizer");
    rc_msg1(gESPMenuTriggerButton, "addGestureRecognizer:", gESPMenuTriggerPan);

    // Make trigger window visible, menu stays hidden until single-tap
    rc_msg0(gESPMenuTriggerWindow, "makeKeyAndVisible");
    rc_msg1(gESPMenuTriggerWindow, "setUserInteractionEnabled:", 1);

    gESPMenuState = ESPMenuOverlayStateRunning;
    return 0;
}

#pragma mark - Stop

static void esp_menu_clear_local_state(void) {
    gESPMenuApplication = 0;
    gESPMenuWindow = 0;
    gESPMenuTriggerWindow = 0;
    gESPMenuRoot = 0;
    gESPMenuBackdrop = 0;
    gESPMenuPanel = 0;
    gESPMenuScroll = 0;
    gESPMenuTitle = 0;
    gESPMenuTriggerButton = 0;
    gESPMenuTriggerPan = 0;
    gESPMenuTriggerSingleTap = 0;
    gESPMenuTriggerDoubleTap = 0;
    gESPMenuTriggerDragIndex = 0;
    gESPMenuTriggerDoubleTapIndex = 0;
    gESPMenuMailbox = 0;
    gESPMenuMailboxBytes = 0;
    gESPMenuMailboxLength = 0;
    gESPMenuDirtyByte = 0;
    gESPMenuVisibleByte = 0;
    gESPMenuHiddenByte = 0;
    gESPMenuInitialOwnership = 0;
    gESPMenuPhysicallySuspended = NO;
    [gESPMenuEntries removeAllObjects];
    [gESPMenuActionControls removeAllObjects];
}

void esp_menu_overlay_stop_in_session(void) {
    if (gESPMenuState == ESPMenuOverlayStateIdle)
        return;

    gESPMenuState = ESPMenuOverlayStateStopping;

    if (gESPMenuTriggerWindow) {
        rc_msg1(gESPMenuTriggerWindow, "setHidden:", 1);
        rc_msg0(gESPMenuTriggerWindow, "resignKeyWindow");
    }
    if (gESPMenuWindow) {
        rc_msg1(gESPMenuWindow, "setHidden:", 1);
        rc_msg0(gESPMenuWindow, "resignKeyWindow");
    }

    if (gESPMenuMailbox) {
        do_remote_call_stable(200, "free", gESPMenuMailbox, 0, 0, 0, 0, 0, 0, 0);
    }

    esp_menu_clear_local_state();
    gESPMenuState = ESPMenuOverlayStateIdle;
}

void esp_menu_overlay_forget_remote_state(void) {
    esp_menu_clear_local_state();
    gESPMenuState = ESPMenuOverlayStateIdle;
}

#pragma mark - Value sync

void esp_menu_overlay_set_value_in_session(NSString *key, float value) {
    if (gESPMenuState != ESPMenuOverlayStateRunning) return;

    for (ESPMenuRemoteEntry *entry in gESPMenuEntries) {
        if (![entry.key isEqualToString:key]) continue;

        if ([entry.kind isEqualToString:@"toggle"]) {
            rc_msg1(entry.control, "setOn:", (uint64_t)(value != 0));
        }
        else if ([entry.kind isEqualToString:@"slider"]) {
            rc_msg1(entry.control, "setValue:", float_to_bits(value));
            if (entry.valueLabel) {
                char buf[32];
                snprintf(buf, sizeof(buf), "%.1f", value);
                esp_menu_set_label_text(entry.valueLabel, buf);
            }
        }
        else if ([entry.kind isEqualToString:@"segmented"]) {
            rc_msg1(entry.control, "setSelectedSegmentIndex:", (uint64_t)(NSInteger)value);
        }
        else if ([entry.kind isEqualToString:@"stepper"]) {
            rc_msg1(entry.control, "setValue:", double_to_bits((double)value));
            if (entry.valueLabel) {
                char buf[32];
                snprintf(buf, sizeof(buf), "%d", (int)value);
                esp_menu_set_label_text(entry.valueLabel, buf);
            }
        }
        break;
    }
}

static float esp_menu_read_control_value(ESPMenuRemoteEntry *entry) {
    if (!entry.control) return 0;

    if ([entry.kind isEqualToString:@"toggle"]) {
        uint64_t val = rc_msg0(entry.control, "isOn");
        return val ? 1.0f : 0.0f;
    }
    else if ([entry.kind isEqualToString:@"slider"]) {
        uint64_t nsKey = rc_remote_str("value");
        uint64_t nsNumber = rc_msg1(entry.control, "valueForKey:", nsKey);
        if (!nsNumber) return 0;
        uint64_t trojan = remote_call_trojan_mem();
        float zero = 0;
        remote_write(trojan, &zero, sizeof(float));
        rc_msg1(nsNumber, "getValue:", trojan);
        float val = 0;
        remote_read(trojan, &val, sizeof(float));
        return val;
    }
    else if ([entry.kind isEqualToString:@"segmented"]) {
        uint64_t val = rc_msg0(entry.control, "selectedSegmentIndex");
        return (float)(NSInteger)val;
    }
    else if ([entry.kind isEqualToString:@"stepper"]) {
        uint64_t nsKey = rc_remote_str("value");
        uint64_t nsNumber = rc_msg1(entry.control, "valueForKey:", nsKey);
        if (!nsNumber) return 0;
        uint64_t trojan = remote_call_trojan_mem();
        double zero = 0;
        remote_write(trojan, &zero, sizeof(double));
        rc_msg1(nsNumber, "getValue:", trojan);
        double val = 0;
        remote_read(trojan, &val, sizeof(double));
        return (float)val;
    }
    return 0;
}

int esp_menu_overlay_poll_changes_in_session(void (^changeHandler)(NSString *, float)) {
    if (gESPMenuState != ESPMenuOverlayStateRunning || !gESPMenuMailbox)
        return 0;

    uint8_t dirtyFlag = 0;
    remote_read(gESPMenuDirtyByte, &dirtyFlag, 1);
    if (!dirtyFlag) return 0;

    uint8_t zero = 0;
    remote_write(gESPMenuDirtyByte, &zero, 1);

    int changeCount = 0;

    for (ESPMenuRemoteEntry *entry in gESPMenuEntries) {
        if (!entry.control) continue;
        uint8_t dirty = 0;
        remote_read(gESPMenuMailbox + entry.dirtyIndex, &dirty, 1);
        if (!dirty) continue;

        remote_write(gESPMenuMailbox + entry.dirtyIndex, &zero, 1);

        float val = esp_menu_read_control_value(entry);
        if (changeHandler)
            changeHandler(entry.key, val);
        changeCount++;
    }

    return changeCount;
}

#pragma mark - Refresh layout

void esp_menu_overlay_refresh_layout_in_session(void) {
    if (gESPMenuState != ESPMenuOverlayStateRunning) return;
    esp_menu_layout_windows();
}
