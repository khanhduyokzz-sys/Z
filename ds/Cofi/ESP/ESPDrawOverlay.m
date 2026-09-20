#import "ESPDrawOverlay.h"
#import "ESPDrawData.h"
#import "../Core/UnityMath.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <os/lock.h>
#import <math.h>

#pragma mark - HUDMainWindow Subclass

@interface HUDMainWindow : UIWindow
- (unsigned int)_contextId;
- (BOOL)_ignoresHitTest;
@end

@implementation HUDMainWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (BOOL)_ignoresHitTest { return YES; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point;
    (void)event;
    return nil;
}
@end

#pragma mark - Player slot views

typedef struct {
    CAShapeLayer *boxLayer;
    CAShapeLayer *lineLayer;
    CAShapeLayer *infoTriangle;
    UIView *hpBg;
    UIView *hpFill;
    UIView *nameBg;
    UILabel *nameLabel;
    UILabel *distLabel;
    BOOL allocated;
} ESPPlayerSlotView;

// Screen-fixed aim overlay layers. They live on gDrawRoot (never per-slot)
// and are driven purely by the packet's aim bundle.
static CAShapeLayer *gFovLayer = nil;
static CAShapeLayer *gAimLineLayer = nil;

#pragma mark - State

typedef struct {
    ESPDrawOverlayState drawState;
    HUDMainWindow *overlayWindow;
    UIViewController *overlayController;
    UIView *drawRoot;
    ESPPlayerSlotView playerSlots[ESP_MAX_DRAW_PLAYERS];
    UILabel *countLabel;
    double screenWidth;
    double screenHeight;
    id fbsOrientationObserver;
    id deviceOrientationObserver;
    os_unfair_lock packetLock;
    ESPDrawPacket pendingPacket;
    BOOL packetDeliveryScheduled;
    uint64_t orientationUpdateGeneration;
    CGFloat lockedLandscapeAngle;
    BOOL hasLockedLandscapeAngle;
} ESPOverlayContext;

static ESPOverlayContext gOverlay = {
    .drawState = ESPDrawOverlayStateIdle,
    .screenWidth = 852.0,
    .screenHeight = 393.0,
    .packetLock = OS_UNFAIR_LOCK_INIT,
    .lockedLandscapeAngle = -M_PI_2
};

// Transitional aliases keep the existing, verified rendering code readable
// while making ownership explicit in one context object.
#define gDrawState gOverlay.drawState
#define gOverlayWindow gOverlay.overlayWindow
#define gOverlayController gOverlay.overlayController
#define gDrawRoot gOverlay.drawRoot
#define gPlayerSlots gOverlay.playerSlots
#define gCountLabel gOverlay.countLabel
#define gDrawScreenWidth gOverlay.screenWidth
#define gDrawScreenHeight gOverlay.screenHeight
#define gFBSOrientationObserver gOverlay.fbsOrientationObserver
#define gDeviceOrientationObserver gOverlay.deviceOrientationObserver
#define gPacketLock gOverlay.packetLock
#define gPendingPacket gOverlay.pendingPacket
#define gPacketDeliveryScheduled gOverlay.packetDeliveryScheduled
#define gOrientationUpdateGeneration gOverlay.orientationUpdateGeneration
#define gLockedLandscapeAngle gOverlay.lockedLandscapeAngle
#define gHasLockedLandscapeAngle gOverlay.hasLockedLandscapeAngle

static NSInteger esp_draw_overlay_active_interface_orientation(void) {
    SEL selector = sel_registerName("activeInterfaceOrientation");
    if (!gFBSOrientationObserver || ![gFBSOrientationObserver respondsToSelector:selector]) return 0;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(gFBSOrientationObserver, selector);
}

static CGFloat esp_draw_overlay_angle_for_interface_orientation(NSInteger orientation,
                                                                 CGFloat fallback) {
    // Match kf_orientAngle: 3 => +pi/2, 4 => -pi/2, 2 => pi.
    if (orientation == 3) return M_PI_2;
    if (orientation == 4) return -M_PI_2;
    if (orientation == 2) return M_PI;
    return fallback;
}

static CGFloat esp_draw_overlay_angle_for_device_orientation(UIDeviceOrientation orientation,
                                                              CGFloat fallback) {
    // Physical landscape orientation → clockwise / counter-clockwise / 180.
    if (orientation == UIDeviceOrientationLandscapeLeft) return M_PI_2;
    if (orientation == UIDeviceOrientationLandscapeRight) return -M_PI_2;
    if (orientation == UIDeviceOrientationPortraitUpsideDown) return M_PI;
    return fallback;
}

static BOOL esp_draw_overlay_device_is_flat(UIDeviceOrientation orientation) {
    return orientation == UIDeviceOrientationFaceUp
        || orientation == UIDeviceOrientationFaceDown
        || orientation == UIDeviceOrientationUnknown;
}

static UIBezierPath *esp_corner_box_path(CGRect box) {
    float cornerLen = fminf(box.size.width, box.size.height) * 0.25f;
    if (cornerLen < 4.0f) cornerLen = 4.0f;
    float x0 = box.origin.x, y0 = box.origin.y;
    float x1 = x0 + box.size.width, y1 = y0 + box.size.height;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(x0, y0 + cornerLen)];
    [path addLineToPoint:CGPointMake(x0, y0)];
    [path addLineToPoint:CGPointMake(x0 + cornerLen, y0)];
    [path moveToPoint:CGPointMake(x1 - cornerLen, y0)];
    [path addLineToPoint:CGPointMake(x1, y0)];
    [path addLineToPoint:CGPointMake(x1, y0 + cornerLen)];
    [path moveToPoint:CGPointMake(x1, y1 - cornerLen)];
    [path addLineToPoint:CGPointMake(x1, y1)];
    [path addLineToPoint:CGPointMake(x1 - cornerLen, y1)];
    [path moveToPoint:CGPointMake(x0 + cornerLen, y1)];
    [path addLineToPoint:CGPointMake(x0, y1)];
    [path addLineToPoint:CGPointMake(x0, y1 - cornerLen)];
    return path;
}

static void esp_draw_overlay_ensure_player_slot(NSUInteger index, UIView *parent) {
    if (index >= ESP_MAX_DRAW_PLAYERS) return;
    ESPPlayerSlotView *slot = &gPlayerSlots[index];
    if (slot->allocated) return;

    slot->lineLayer = [CAShapeLayer layer];
    slot->lineLayer.fillColor = nil;
    slot->lineLayer.strokeColor = [UIColor whiteColor].CGColor;
    slot->lineLayer.lineWidth = 0.5f;
    slot->lineLayer.actions = @{@"path": [NSNull null], @"hidden": [NSNull null]};
    slot->lineLayer.hidden = YES;
    [parent.layer addSublayer:slot->lineLayer];

    slot->boxLayer = [CAShapeLayer layer];
    slot->boxLayer.fillColor = nil;
    // VIP-standard box: cyan stroke, 0.6pt hairline, edge antialiasing on
    // 2x contentsScale — produces the crispest possible pixel border at 60Hz.
    slot->boxLayer.strokeColor = [UIColor colorWithRed:0.0f green:1.0f blue:1.0f alpha:1.0f].CGColor;
    slot->boxLayer.lineWidth = 0.6f;
    slot->boxLayer.lineJoin = kCALineJoinMiter;
    slot->boxLayer.lineCap = kCALineCapSquare;
    slot->boxLayer.allowsEdgeAntialiasing = YES;
    slot->boxLayer.contentsScale = UIScreen.mainScreen.scale * 2.0f;
    slot->boxLayer.actions = @{@"path": [NSNull null], @"hidden": [NSNull null]};
    slot->boxLayer.hidden = YES;
    [parent.layer addSublayer:slot->boxLayer];

    slot->infoTriangle = [CAShapeLayer layer];
    slot->infoTriangle.fillColor = [UIColor whiteColor].CGColor;
    slot->infoTriangle.actions = @{@"path": [NSNull null], @"hidden": [NSNull null]};
    slot->infoTriangle.hidden = YES;
    [parent.layer addSublayer:slot->infoTriangle];

    slot->hpBg = [[UIView alloc] initWithFrame:CGRectZero];
    slot->hpBg.backgroundColor = [UIColor colorWithRed:0.4 green:0.0 blue:0.0 alpha:0.8];
    slot->hpBg.hidden = YES;
    [parent addSubview:slot->hpBg];

    slot->hpFill = [[UIView alloc] initWithFrame:CGRectZero];
    slot->hpFill.hidden = YES;
    [parent addSubview:slot->hpFill];

    slot->nameBg = [[UIView alloc] initWithFrame:CGRectZero];
    slot->nameBg.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    slot->nameBg.hidden = YES;
    [parent addSubview:slot->nameBg];

    slot->nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    slot->nameLabel.font = [UIFont boldSystemFontOfSize:11.0f];
    slot->nameLabel.textColor = [UIColor whiteColor];
    slot->nameLabel.textAlignment = NSTextAlignmentCenter;
    slot->nameLabel.hidden = YES;
    [parent addSubview:slot->nameLabel];

    slot->distLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    slot->distLabel.font = [UIFont boldSystemFontOfSize:10.0f];
    slot->distLabel.textColor = [UIColor whiteColor];
    slot->distLabel.textAlignment = NSTextAlignmentCenter;
    slot->distLabel.hidden = YES;
    [parent addSubview:slot->distLabel];

    slot->allocated = YES;
}

static void esp_draw_overlay_hide_player_slot(ESPPlayerSlotView *slot) {
    if (!slot || !slot->allocated) return;
    slot->boxLayer.hidden = YES;
    slot->lineLayer.hidden = YES;
    slot->infoTriangle.hidden = YES;
    slot->hpBg.hidden = YES;
    slot->hpFill.hidden = YES;
    slot->nameBg.hidden = YES;
    slot->nameLabel.hidden = YES;
    slot->distLabel.hidden = YES;
}

static void esp_draw_overlay_destroy_slots(void) {
    for (NSUInteger i = 0; i < ESP_MAX_DRAW_PLAYERS; i++) {
        ESPPlayerSlotView *slot = &gPlayerSlots[i];
        if (!slot->allocated) continue;
        [slot->boxLayer removeFromSuperlayer];
        [slot->lineLayer removeFromSuperlayer];
        [slot->infoTriangle removeFromSuperlayer];
        [slot->hpBg removeFromSuperview];
        [slot->hpFill removeFromSuperview];
        [slot->nameBg removeFromSuperview];
        [slot->nameLabel removeFromSuperview];
        [slot->distLabel removeFromSuperview];
        slot->boxLayer = nil;
        slot->lineLayer = nil;
        slot->infoTriangle = nil;
        slot->hpBg = nil;
        slot->hpFill = nil;
        slot->nameBg = nil;
        slot->nameLabel = nil;
        slot->distLabel = nil;
        slot->allocated = NO;
    }
    [gCountLabel removeFromSuperview];
    gCountLabel = nil;
    [gFovLayer removeFromSuperlayer];
    gFovLayer = nil;
    [gAimLineLayer removeFromSuperlayer];
    gAimLineLayer = nil;
    [gDrawRoot removeFromSuperview];
    gDrawRoot = nil;
}

static void esp_draw_overlay_update_orientation(void) {
    if (!gOverlayWindow || !gOverlayController || gDrawState != ESPDrawOverlayStateRunning) return;

    UIDeviceOrientation devOrient = [UIDevice currentDevice].orientation;
    CGFloat currentAngle = atan2(gOverlayController.view.transform.b,
                                 gOverlayController.view.transform.a);
    CGFloat angle = currentAngle;
    NSInteger interfaceOrient = esp_draw_overlay_active_interface_orientation();

    if (esp_draw_overlay_device_is_flat(devOrient)) {
        // FaceUp/Down thrash made FBS flip 3↔4 (±π/2). Keep last stable landscape.
        if (gHasLockedLandscapeAngle) {
            angle = gLockedLandscapeAngle;
        } else {
            angle = esp_draw_overlay_angle_for_interface_orientation(interfaceOrient, currentAngle);
            if (fabs(angle) < 0.01 && fabs(fabs(angle) - M_PI) > 0.01) {
                angle = -M_PI_2;
            }
            gLockedLandscapeAngle = angle;
            gHasLockedLandscapeAngle = YES;
        }
    } else {
        angle = esp_draw_overlay_angle_for_device_orientation(devOrient, currentAngle);
        angle = esp_draw_overlay_angle_for_interface_orientation(interfaceOrient, angle);
        gLockedLandscapeAngle = angle;
        gHasLockedLandscapeAngle = YES;
    }

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    double portraitW = fmin(screenBounds.size.width, screenBounds.size.height);
    double portraitH = fmax(screenBounds.size.width, screenBounds.size.height);
    double landscapeW = portraitH;
    double landscapeH = portraitW;

    gDrawScreenWidth = landscapeW;
    gDrawScreenHeight = landscapeH;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    gOverlayWindow.transform = CGAffineTransformIdentity;
    gOverlayWindow.frame = CGRectMake(0, 0, portraitW, portraitH);

    UIView *overlayView = gOverlayController.view;
    overlayView.bounds = CGRectMake(0, 0, landscapeW, landscapeH);
    overlayView.layer.anchorPoint = CGPointMake(0.5f, 0.5f);
    overlayView.layer.position = CGPointMake(portraitW * 0.5f, portraitH * 0.5f);
    overlayView.transform = CGAffineTransformMakeRotation(angle);

    if (gDrawRoot) gDrawRoot.frame = overlayView.bounds;

    [CATransaction commit];
}

static void esp_draw_overlay_schedule_orientation_update(void) {
    uint64_t generation = ++gOrientationUpdateGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == gOrientationUpdateGeneration) {
            esp_draw_overlay_update_orientation();
        }
    });
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

#pragma mark - Public Getters

ESPDrawOverlayState esp_draw_overlay_state(void) {
    return gDrawState;
}

void esp_draw_overlay_get_screen_size(float *widthOut, float *heightOut) {
    if (widthOut) *widthOut = (float)gDrawScreenWidth;
    if (heightOut) *heightOut = (float)gDrawScreenHeight;
}

#pragma mark - Overlay Lifecycle

int esp_draw_overlay_initialize_in_session(void) {
    if (gDrawState == ESPDrawOverlayStateRunning && gOverlayWindow)
        return 0;

    if (!remote_call_has_local_state() || !remote_call_current_success())
        return -1;

    gDrawState = ESPDrawOverlayStateInitializing;

    CGRect screenBounds = [UIScreen mainScreen].bounds;
    double portraitW = fmin(screenBounds.size.width, screenBounds.size.height);
    double portraitH = fmax(screenBounds.size.width, screenBounds.size.height);
    double landscapeW = portraitH;
    double landscapeH = portraitW;

    gDrawScreenWidth = landscapeW;
    gDrawScreenHeight = landscapeH;

    __block unsigned int contextId = 0;

    void (^setupBlock)(void) = ^{
        if (!gOverlayWindow) {
            gOverlayWindow = [[HUDMainWindow alloc] initWithFrame:CGRectMake(0, 0, portraitW, portraitH)];
            gOverlayWindow.backgroundColor = [UIColor clearColor];
            gOverlayWindow.userInteractionEnabled = NO;
            gOverlayWindow.windowLevel = 10000010.0;
            gOverlayWindow.transform = CGAffineTransformIdentity;
            gOverlayWindow.layer.masksToBounds = NO;

            gOverlayController = [[UIViewController alloc] init];
            UIView *overlayView = gOverlayController.view;
            overlayView.backgroundColor = [UIColor clearColor];
            overlayView.userInteractionEnabled = NO;
            overlayView.bounds = CGRectMake(0, 0, landscapeW, landscapeH);
            overlayView.layer.anchorPoint = CGPointMake(0.5f, 0.5f);
            overlayView.layer.position = CGPointMake(portraitW * 0.5f, portraitH * 0.5f);

            Class observerClass = objc_getClass("FBSOrientationObserver");
            if (observerClass) {
                gFBSOrientationObserver = ((id (*)(id, SEL))objc_msgSend)(
                    ((id (*)(id, SEL))objc_msgSend)(observerClass, sel_registerName("alloc")),
                    sel_registerName("init"));
                SEL setHandler = sel_registerName("setHandler:");
                if (gFBSOrientationObserver && [gFBSOrientationObserver respondsToSelector:setHandler]) {
                    void (^handler)(id) = ^(id update) {
                        (void)update;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            esp_draw_overlay_schedule_orientation_update();
                        });
                    };
                    ((void (*)(id, SEL, id))objc_msgSend)(gFBSOrientationObserver, setHandler, handler);
                }
            }

            UIDeviceOrientation deviceOrient = [UIDevice currentDevice].orientation;
            NSInteger interfaceOrient = esp_draw_overlay_active_interface_orientation();
            CGFloat initialAngle = esp_draw_overlay_angle_for_device_orientation(deviceOrient, -M_PI_2);
            initialAngle = esp_draw_overlay_angle_for_interface_orientation(interfaceOrient, initialAngle);
            if (esp_draw_overlay_device_is_flat(deviceOrient)) {
                initialAngle = -M_PI_2;
            }
            gLockedLandscapeAngle = initialAngle;
            gHasLockedLandscapeAngle = YES;
            overlayView.transform = CGAffineTransformMakeRotation(initialAngle);
            gOverlayWindow.rootViewController = gOverlayController;

            // UIView root hosts CAShapeLayer + UILabel — no bitmap fallback.
            gDrawRoot = [[UIView alloc] initWithFrame:overlayView.bounds];
            gDrawRoot.backgroundColor = [UIColor clearColor];
            gDrawRoot.userInteractionEnabled = NO;
            gDrawRoot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [overlayView addSubview:gDrawRoot];

            // Static slots start empty; teardown releases each ARC reference.
            for (NSUInteger i = 0; i < ESP_MAX_DRAW_PLAYERS; i++) {
                esp_draw_overlay_ensure_player_slot(i, gDrawRoot);
            }

            gCountLabel = [[UILabel alloc] initWithFrame:CGRectZero];
            gCountLabel.font = [UIFont boldSystemFontOfSize:22.0f];
            // VIP-standard cyan enemy counter — pops cleanly against the dark
            // game scene without competing with the cyan ESP box stroke.
            gCountLabel.textColor = [UIColor colorWithRed:0.0f green:1.0f blue:1.0f alpha:1.0f];
            gCountLabel.textAlignment = NSTextAlignmentCenter;
            gCountLabel.hidden = YES;
            [gDrawRoot addSubview:gCountLabel];

            // Aim FOV circle — VIP mint styling (thin, antialiased, lowest z).
            gFovLayer = [CAShapeLayer layer];
            gFovLayer.strokeColor = [UIColor colorWithRed:0.4f green:0.9f blue:0.75f alpha:1.0f].CGColor;
            gFovLayer.fillColor = [UIColor clearColor].CGColor;
            gFovLayer.lineWidth = 1.0f;
            gFovLayer.lineJoin = kCALineJoinRound;
            gFovLayer.lineCap = kCALineCapRound;
            gFovLayer.contentsScale = UIScreen.mainScreen.scale * 2.0f;
            gFovLayer.allowsEdgeAntialiasing = YES;
            gFovLayer.zPosition = 0.0f;
            gFovLayer.hidden = YES;
            gFovLayer.actions = @{ @"path": [NSNull null], @"hidden": [NSNull null] };
            [gDrawRoot.layer addSublayer:gFovLayer];

            // Aim lock line: crosshair -> locked target (VIP mint).
            gAimLineLayer = [CAShapeLayer layer];
            gAimLineLayer.strokeColor = [UIColor colorWithRed:0.4f green:0.9f blue:0.75f alpha:0.9f].CGColor;
            gAimLineLayer.fillColor = nil;
            gAimLineLayer.lineWidth = 0.8f;
            gAimLineLayer.lineCap = kCALineCapRound;
            gAimLineLayer.contentsScale = UIScreen.mainScreen.scale;
            gAimLineLayer.allowsEdgeAntialiasing = YES;
            gAimLineLayer.zPosition = 1.0f;
            gAimLineLayer.hidden = YES;
            gAimLineLayer.actions = @{ @"path": [NSNull null], @"hidden": [NSNull null] };
            [gDrawRoot.layer addSublayer:gAimLineLayer];

            gOverlayWindow.hidden = NO;

            log_user("[ESPOverlay] setup interface=%ld device=%ld angle=%.3f screen=(%.0fx%.0f) window=(%.0fx%.0f) canvas=(%.0fx%.0f) uiview=1\n",
                     (long)interfaceOrient, (long)deviceOrient, initialAngle,
                     screenBounds.size.width, screenBounds.size.height,
                     portraitW, portraitH, landscapeW, landscapeH);

            if (!gDeviceOrientationObserver) {
                [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
                gDeviceOrientationObserver = [[NSNotificationCenter defaultCenter]
                    addObserverForName:UIDeviceOrientationDidChangeNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification * _Nonnull note) {
                    (void)note;
                    esp_draw_overlay_schedule_orientation_update();
                }];
            }

            if ([gOverlayWindow respondsToSelector:@selector(_contextId)]) {
                contextId = [gOverlayWindow _contextId];
            }
        } else if (gOverlayWindow && [gOverlayWindow respondsToSelector:@selector(_contextId)]) {
            contextId = [gOverlayWindow _contextId];
        }
    };

    if ([NSThread isMainThread]) {
        setupBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), setupBlock);
    }

    if (contextId > 0) {
        uint64_t trojan = remote_call_trojan_mem();
        if (trojan) {
            remote_writeStr(trojan, "SBSAccessibilityWindowHostingController");
            uint64_t hostCls = do_remote_call_stable(200, "objc_getClass", trojan, 0, 0, 0, 0, 0, 0, 0);

            remote_writeStr(trojan, "alloc");
            uint64_t selAlloc = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);

            remote_writeStr(trojan, "init");
            uint64_t selInit = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);

            uint64_t hostInst = 0;
            if (hostCls && selAlloc && selInit) {
                hostInst = do_remote_call_stable(200, "objc_msgSend", hostCls, selAlloc, 0, 0, 0, 0, 0, 0);
                if (hostInst) {
                    hostInst = do_remote_call_stable(200, "objc_msgSend", hostInst, selInit, 0, 0, 0, 0, 0, 0);
                }
            }

            log_user("[ESPOverlay] contextId=%u hostCls=0x%llx hostInst=0x%llx\n", contextId, hostCls, hostInst);
            if (hostInst) {
                remote_writeStr(trojan, "registerWindowWithContextID:atLevel:");
                uint64_t selRegister = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);

                remote_writeStr(trojan, "methodSignatureForSelector:");
                uint64_t selMethodSig = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);

                uint64_t sig = do_remote_call_stable(200, "objc_msgSend", hostInst, selMethodSig, selRegister, 0, 0, 0, 0, 0);

                remote_writeStr(trojan, "NSInvocation");
                uint64_t invCls = do_remote_call_stable(200, "objc_getClass", trojan, 0, 0, 0, 0, 0, 0, 0);

                remote_writeStr(trojan, "invocationWithMethodSignature:");
                uint64_t selInvWithSig = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);

                uint64_t inv = 0;
                if (invCls && selInvWithSig && sig) {
                    inv = do_remote_call_stable(200, "objc_msgSend", invCls, selInvWithSig, sig, 0, 0, 0, 0, 0);
                }

                if (inv) {
                    remote_writeStr(trojan, "setTarget:");
                    uint64_t selSetTarget = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                    do_remote_call_stable(200, "objc_msgSend", inv, selSetTarget, hostInst, 0, 0, 0, 0, 0);

                    remote_writeStr(trojan, "setSelector:");
                    uint64_t selSetSelector = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                    do_remote_call_stable(200, "objc_msgSend", inv, selSetSelector, selRegister, 0, 0, 0, 0, 0);

                    uint32_t cid = contextId;
                    double lvl = 10000010.0;
                    uint64_t argsBuffer = trojan + 256;
                    remote_write(argsBuffer, &cid, sizeof(uint32_t));
                    remote_write(argsBuffer + 8, &lvl, sizeof(double));

                    remote_writeStr(trojan, "setArgument:atIndex:");
                    uint64_t selSetArg = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                    do_remote_call_stable(200, "objc_msgSend", inv, selSetArg, argsBuffer, 2, 0, 0, 0, 0);
                    do_remote_call_stable(200, "objc_msgSend", inv, selSetArg, argsBuffer + 8, 3, 0, 0, 0, 0);

                    remote_writeStr(trojan, "invoke");
                    uint64_t selInvoke = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                    do_remote_call_stable(200, "objc_msgSend", inv, selInvoke, 0, 0, 0, 0, 0, 0);

                    log_user("[ESPOverlay] Registered context %u in SpringBoard via NSInvocation\n", contextId);
                } else if (selRegister) {
                    do_remote_call_stable(200, "objc_msgSend", hostInst, selRegister,
                        (uint64_t)contextId, double_to_bits(10000010.0), 0, 0, 0, 0);
                    log_user("[ESPOverlay] Registered context %u in SpringBoard (direct)\n", contextId);
                }
            } else if (!hostCls) {
                // iOS 26+: SBSAccessibilityWindowHostingController removed.
                // Attach CALayerHost to an EXISTING SpringBoard window's layer
                // to avoid creating a new UIWindow (which crashes on iOS 26).
                log_user("[ESPOverlay] SBSAccessibility missing, trying CALayerHost fallback...\n");

                // Get SpringBoard's existing key window
                remote_writeStr(trojan, "UIApplication");
                uint64_t appCls = do_remote_call_stable(200, "objc_getClass", trojan, 0, 0, 0, 0, 0, 0, 0);
                remote_writeStr(trojan, "sharedApplication");
                uint64_t selShared = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                uint64_t sbApp = do_remote_call_stable(200, "objc_msgSend", appCls, selShared, 0, 0, 0, 0, 0, 0);

                // Get windows from scene (iOS 26 compatible)
                remote_writeStr(trojan, "connectedScenes");
                uint64_t selScenes = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                uint64_t sbScenes = do_remote_call_stable(200, "objc_msgSend", sbApp, selScenes, 0, 0, 0, 0, 0, 0);

                remote_writeStr(trojan, "objectEnumerator");
                uint64_t selObjEnum = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                uint64_t sceneEnum = do_remote_call_stable(200, "objc_msgSend", sbScenes, selObjEnum, 0, 0, 0, 0, 0, 0);

                remote_writeStr(trojan, "nextObject");
                uint64_t selNextObj = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                uint64_t windowScene = do_remote_call_stable(200, "objc_msgSend", sceneEnum, selNextObj, 0, 0, 0, 0, 0, 0);

                // Get the scene's first window (SpringBoard always has at least one)
                uint64_t sbWin = 0;
                if (windowScene) {
                    remote_writeStr(trojan, "windows");
                    uint64_t selWins = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                    uint64_t sceneWins = do_remote_call_stable(200, "objc_msgSend", windowScene, selWins, 0, 0, 0, 0, 0, 0);

                    remote_writeStr(trojan, "firstObject");
                    uint64_t selFirst = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                    sbWin = do_remote_call_stable(200, "objc_msgSend", sceneWins, selFirst, 0, 0, 0, 0, 0, 0);
                }

                log_user("[ESPOverlay] sbApp=0x%llx scene=0x%llx existingWin=0x%llx\n", sbApp, windowScene, sbWin);

                if (sbWin) {
                    // Get the window's root layer
                    remote_writeStr(trojan, "layer");
                    uint64_t selLayer = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                    uint64_t winLayer = do_remote_call_stable(200, "objc_msgSend", sbWin, selLayer, 0, 0, 0, 0, 0, 0);

                    // Create CALayerHost (pure CoreAnimation, no UIKit)
                    remote_writeStr(trojan, "CALayerHost");
                    uint64_t lhCls = do_remote_call_stable(200, "objc_getClass", trojan, 0, 0, 0, 0, 0, 0, 0);

                    uint64_t layerHost = 0;
                    if (lhCls) {
                        remote_writeStr(trojan, "alloc");
                        uint64_t selAl2 = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                        layerHost = do_remote_call_stable(200, "objc_msgSend", lhCls, selAl2, 0, 0, 0, 0, 0, 0);

                        remote_writeStr(trojan, "init");
                        uint64_t selIn2 = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                        layerHost = do_remote_call_stable(200, "objc_msgSend", layerHost, selIn2, 0, 0, 0, 0, 0, 0);
                    }

                    log_user("[ESPOverlay] winLayer=0x%llx lhCls=0x%llx layerHost=0x%llx\n", winLayer, lhCls, layerHost);

                    if (layerHost && winLayer) {
                        // Set contextId — uint32 goes cleanly in integer register
                        remote_writeStr(trojan, "setContextId:");
                        uint64_t selSetCtxId = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                        do_remote_call_stable(200, "objc_msgSend", layerHost, selSetCtxId, (uint64_t)contextId, 0, 0, 0, 0, 0);

                        // Set bounds via NSInvocation to pass CGRect through ABI correctly
                        remote_writeStr(trojan, "setBounds:");
                        uint64_t selSetBounds = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);

                        remote_writeStr(trojan, "methodSignatureForSelector:");
                        uint64_t selMSFS = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                        uint64_t boundsSig = do_remote_call_stable(200, "objc_msgSend", layerHost, selMSFS, selSetBounds, 0, 0, 0, 0, 0);

                        remote_writeStr(trojan, "NSInvocation");
                        uint64_t invCls2 = do_remote_call_stable(200, "objc_getClass", trojan, 0, 0, 0, 0, 0, 0, 0);
                        remote_writeStr(trojan, "invocationWithMethodSignature:");
                        uint64_t selInvWSig = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);

                        uint64_t boundsInv = 0;
                        if (invCls2 && boundsSig) {
                            boundsInv = do_remote_call_stable(200, "objc_msgSend", invCls2, selInvWSig, boundsSig, 0, 0, 0, 0, 0);
                        }

                        if (boundsInv) {
                            remote_writeStr(trojan, "setTarget:");
                            uint64_t selST2 = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                            do_remote_call_stable(200, "objc_msgSend", boundsInv, selST2, layerHost, 0, 0, 0, 0, 0);

                            remote_writeStr(trojan, "setSelector:");
                            uint64_t selSS2 = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                            do_remote_call_stable(200, "objc_msgSend", boundsInv, selSS2, selSetBounds, 0, 0, 0, 0, 0);

                            uint64_t rectBuf = trojan + 256;
                            double bx = 0, by = 0, bw = portraitW, bh = portraitH;
                            remote_write(rectBuf, &bx, sizeof(double));
                            remote_write(rectBuf + 8, &by, sizeof(double));
                            remote_write(rectBuf + 16, &bw, sizeof(double));
                            remote_write(rectBuf + 24, &bh, sizeof(double));

                            remote_writeStr(trojan, "setArgument:atIndex:");
                            uint64_t selSA2 = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                            do_remote_call_stable(200, "objc_msgSend", boundsInv, selSA2, rectBuf, 2, 0, 0, 0, 0);

                            remote_writeStr(trojan, "invoke");
                            uint64_t selInv2 = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                            do_remote_call_stable(200, "objc_msgSend", boundsInv, selInv2, 0, 0, 0, 0, 0, 0);

                            log_user("[ESPOverlay] CALayerHost bounds set %.0fx%.0f\n", portraitW, portraitH);
                        }

                        // High zPosition so overlay renders on top of everything
                        remote_writeStr(trojan, "setZPosition:");
                        uint64_t selSetZ = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                        do_remote_call_stable(200, "objc_msgSend", layerHost, selSetZ, double_to_bits(100000.0), 0, 0, 0, 0, 0);

                        // Add CALayerHost to the existing window's layer
                        remote_writeStr(trojan, "addSublayer:");
                        uint64_t selAddSub = do_remote_call_stable(200, "sel_registerName", trojan, 0, 0, 0, 0, 0, 0, 0);
                        do_remote_call_stable(200, "objc_msgSend", winLayer, selAddSub, layerHost, 0, 0, 0, 0, 0);

                        log_user("[ESPOverlay] CALayerHost hosted context %u on existing SB window\n", contextId);
                    } else {
                        log_user("[ESPOverlay] CALayerHost alloc failed (lhCls=0x%llx winLayer=0x%llx)\n", lhCls, winLayer);
                    }
                } else {
                    log_user("[ESPOverlay] No existing SpringBoard window found\n");
                }
            }
        }
    } else {
        log_user("[ESPOverlay] Warning: contextId is 0, remote hosting failed\n");
    }

    gDrawState = ESPDrawOverlayStateRunning;
    return 0;
}

void esp_draw_overlay_stop_in_session(void) {
    gDrawState = ESPDrawOverlayStateStopping;
    ++gOrientationUpdateGeneration;
    void (^destroyBlock)(void) = ^{
        esp_draw_overlay_destroy_slots();
        if (gOverlayWindow) {
            gOverlayWindow.hidden = YES;
            gOverlayWindow.rootViewController = nil;
            gOverlayWindow = nil;
        }
        gOverlayController = nil;
        gHasLockedLandscapeAngle = NO;
        if (gDeviceOrientationObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:gDeviceOrientationObserver];
            gDeviceOrientationObserver = nil;
        }
        if (gFBSOrientationObserver) {
            SEL setHandler = sel_registerName("setHandler:");
            if ([gFBSOrientationObserver respondsToSelector:setHandler]) {
                ((void (*)(id, SEL, id))objc_msgSend)(gFBSOrientationObserver, setHandler, nil);
            }
            gFBSOrientationObserver = nil;
        }
        os_unfair_lock_lock(&gPacketLock);
        memset(&gPendingPacket, 0, sizeof(gPendingPacket));
        gPacketDeliveryScheduled = NO;
        os_unfair_lock_unlock(&gPacketLock);
        gDrawState = ESPDrawOverlayStateIdle;
    };

    // Teardown is synchronous so no provider/remote-call cleanup can race the
    // UIKit layer destruction. All layer removal happens before this returns.
    if ([NSThread isMainThread]) destroyBlock();
    else dispatch_sync(dispatch_get_main_queue(), destroyBlock);
}

#pragma mark - UIView Rendering

static CGRect esp_info_rect(UnityScreenRect rect) {
    return CGRectMake(rect.x, rect.y, rect.width, rect.height);
}

static void esp_draw_overlay_apply_line(ESPPlayerSlotView *slot,
                                        CGRect box,
                                        CGPoint origin,
                                        BOOL enabled,
                                        BOOL showHealth,
                                        BOOL showName) {
    if (!enabled) {
        slot->lineLayer.hidden = YES;
        slot->lineLayer.path = nil;
        return;
    }
    UIBezierPath *line = [UIBezierPath bezierPath];
    [line moveToPoint:origin];
    [line addLineToPoint:CGPointMake(CGRectGetMidX(box), CGRectGetMinY(box) -
        unity_math_line_end_offset(showHealth, showName))];
    slot->lineLayer.lineWidth = 0.5f;
    slot->lineLayer.path = line.CGPath;
    slot->lineLayer.hidden = NO;
}

static void esp_draw_overlay_apply_box(ESPPlayerSlotView *slot, CGRect box, BOOL enabled) {
    if (!enabled) {
        slot->boxLayer.hidden = YES;
        slot->boxLayer.path = nil;
        return;
    }
    slot->boxLayer.lineWidth = 0.6f;
    // Sub-pixel round the box coordinates. This is the single biggest
    // contributor to perceived smoothness at 60Hz — fractional positions make
    // CoreAnimation resample the path every frame, producing the "shimmer"
    // VIP removes by snapping every corner to a whole pixel.
    CGRect snapped = CGRectMake(roundf(box.origin.x),
                                roundf(box.origin.y),
                                roundf(box.size.width),
                                roundf(box.size.height));
    slot->boxLayer.path = esp_corner_box_path(snapped).CGPath;
    slot->boxLayer.hidden = NO;
}

static void esp_draw_overlay_apply_triangle(ESPPlayerSlotView *slot,
                                            const UnityPlayerInfoLayout *layout,
                                            BOOL enabled) {
    slot->infoTriangle.hidden = !enabled;
    if (!enabled) return;
    UIBezierPath *triangle = [UIBezierPath bezierPath];
    [triangle moveToPoint:CGPointMake(layout->triangle[0].x, layout->triangle[0].y)];
    [triangle addLineToPoint:CGPointMake(layout->triangle[1].x, layout->triangle[1].y)];
    [triangle addLineToPoint:CGPointMake(layout->triangle[2].x, layout->triangle[2].y)];
    [triangle closePath];
    slot->infoTriangle.path = triangle.CGPath;
}

static BOOL esp_draw_overlay_packet_header_is_valid(const ESPDrawPacket *packet);

static void esp_draw_overlay_apply_health(ESPPlayerSlotView *slot,
                                          const UnityPlayerInfoLayout *layout,
                                          BOOL enabled) {
    if (enabled) {
        CGFloat hpRatio = layout->healthFill.width / 75.0;
        CGRect bg = esp_info_rect(layout->healthFill);
        bg.size.width = 75.0;
        slot->hpBg.frame = bg;
        slot->hpFill.frame = esp_info_rect(layout->healthFill);
        slot->hpFill.backgroundColor = hpRatio > 0.5
            ? [UIColor colorWithRed:0 green:0.9 blue:0.2 alpha:1]
            : hpRatio > 0.25 ? [UIColor colorWithRed:1 green:0.7 blue:0 alpha:1]
            : [UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:1];
    }
    slot->hpBg.hidden = !enabled;
    slot->hpFill.hidden = !enabled;
}

// VIP-standard 3-colour name rotation. Hashing the pawn address keeps the
// colour stable across frames (so a moving enemy keeps the same colour) while
// giving each enemy a distinct tint so the eye can track individuals in a
// crowded BR roster.
static UIColor *esp_draw_overlay_name_color_for_pawn(uint64_t pawn, BOOL isKnocked) {
    if (isKnocked) return [UIColor colorWithRed:1.0f green:0.0f blue:0.0f alpha:1.0f];
    NSUInteger idx = (NSUInteger)(pawn % 3);
    switch (idx) {
        case 0:  return [UIColor colorWithRed:0.4f green:0.9f blue:0.75f alpha:1.0f]; // mint
        case 1:  return [UIColor colorWithRed:0.5f green:0.3f blue:0.9f alpha:1.0f];  // violet
        case 2:  return [UIColor colorWithRed:0.5f green:0.94f blue:1.0f alpha:1.0f];  // light cyan
        default: return UIColor.whiteColor;
    }
}

static void esp_draw_overlay_apply_name(ESPPlayerSlotView *slot,
                                        const ESPPlayerDrawEntry *player,
                                        const UnityPlayerInfoLayout *layout,
                                        BOOL enabled) {
    if (enabled) {
        size_t length = strnlen(player->name, sizeof(player->name));
        NSString *name = [[NSString alloc] initWithBytes:player->name length:length encoding:NSUTF8StringEncoding];
        slot->nameLabel.text = name ?: @"";
        slot->nameBg.frame = esp_info_rect(layout->nameBackground);
        slot->nameLabel.frame = esp_info_rect(layout->name);
        slot->nameLabel.adjustsFontSizeToFitWidth = YES;
        slot->nameLabel.minimumScaleFactor = 0.7;
        // Apply the VIP-standard 3-colour rotation so names are tinted by
        // stable pawn identity instead of all rendering in flat white.
        slot->nameLabel.textColor = esp_draw_overlay_name_color_for_pawn(player->pawn,
                                                                          /*isKnocked=*/NO);
    }
    slot->nameBg.hidden = !enabled;
    slot->nameLabel.hidden = !enabled;
}

static void esp_draw_overlay_apply_distance(ESPPlayerSlotView *slot,
                                            const ESPPlayerDrawEntry *player,
                                            const UnityPlayerInfoLayout *layout,
                                            BOOL enabled) {
    BOOL showDistance = enabled && isfinite(player->distanceMeters) &&
        player->distanceMeters >= 0 && player->distanceMeters < INT_MAX;
    if (showDistance) {
        slot->distLabel.text = [NSString stringWithFormat:@"[%dM]", (int)player->distanceMeters];
        slot->distLabel.frame = esp_info_rect(layout->distance);
    }
    slot->distLabel.hidden = !showDistance;
}

// Called inside the packet's main-thread CATransaction. Slot identity remains
// the packet index, and layout validation precedes every geometry update.
static BOOL esp_draw_overlay_apply_player(uint32_t index,
                                          const ESPDrawPacket *packet,
                                          CGPoint lineOrigin) {
    const ESPPlayerDrawEntry *player = &packet->players[index];
    ESPPlayerSlotView *slot = &gPlayerSlots[index];
    if (!slot->allocated) esp_draw_overlay_ensure_player_slot(index, gDrawRoot);

    UnityPlayerInfoLayout layout;
    if (!player->valid || !player->isVisible || !unity_math_info_layout(
            player->box.origin.x, player->box.origin.y, player->box.size.width, player->box.size.height,
            player->currentHP, player->maximumHP, &layout)) {
        esp_draw_overlay_hide_player_slot(slot);
        return NO;
    }

    esp_draw_overlay_apply_line(slot, player->box, lineOrigin, packet->showLines != 0,
                                packet->showHealth != 0, packet->showNames != 0);
    esp_draw_overlay_apply_box(slot, player->box, packet->showBoxes != 0);

    // Fixed geometry verified against reference implementations.
    uint32_t info = unity_math_info_visibility(packet->showHealth != 0, packet->showNames != 0);
    esp_draw_overlay_apply_health(slot, &layout, (info & 0x100) != 0);
    esp_draw_overlay_apply_name(slot, player, &layout, (info & 1) != 0);
    esp_draw_overlay_apply_triangle(slot, &layout, (info & 0x1000000) != 0);
    esp_draw_overlay_apply_distance(slot, player, &layout, packet->showDistance != 0);
    return YES;
}

static void esp_draw_overlay_hide_slots_from(uint32_t firstIndex) {
    for (uint32_t i = firstIndex; i < ESP_MAX_DRAW_PLAYERS; i++) {
        esp_draw_overlay_hide_player_slot(&gPlayerSlots[i]);
    }
}

static void esp_draw_overlay_apply_counter(uint32_t visible, CGFloat width, BOOL enabled) {
    if (!gCountLabel) return;
    if (gDrawState != ESPDrawOverlayStateRunning) {
        gCountLabel.hidden = YES;
        return;
    }

    if (enabled && visible > 0) {
        gCountLabel.text = [NSString stringWithFormat:@"%u", visible];
    } else {
        gCountLabel.text = @"--";
    }
    [gCountLabel sizeToFit];
    CGSize textSize = gCountLabel.bounds.size;
    gCountLabel.frame = CGRectMake((width - textSize.width) * 0.5f, 22.0f, textSize.width, textSize.height);
    gCountLabel.hidden = NO;
}

// Aim overlay: FOV circle centred on the screen plus the crosshair lock
// line. Both are packet-driven so the SpringBoard side never touches prefs.
static void esp_draw_overlay_apply_aim_overlay(const ESPDrawPacket *packet,
                                               CGFloat width,
                                               CGFloat height,
                                               BOOL validPacket) {
    if (!gFovLayer || !gAimLineLayer) return;

    BOOL showFov = validPacket && packet->showFov != 0 &&
        isfinite(packet->fovRadius) && packet->fovRadius > 0.0f;
    if (showFov) {
        CGFloat radius = (CGFloat)packet->fovRadius;
        UIBezierPath *circle = [UIBezierPath
            bezierPathWithArcCenter:CGPointMake(width * 0.5f, height * 0.5f)
                             radius:radius
                         startAngle:0.0f endAngle:M_PI * 2.0f clockwise:YES];
        gFovLayer.path = circle.CGPath;
        gFovLayer.hidden = NO;
    } else {
        gFovLayer.path = nil;
        gFovLayer.hidden = YES;
    }

    BOOL showLine = validPacket && packet->aimHasTarget != 0;
    if (showLine) {
        CGPoint target = packet->aimTargetPoint;
        if (isfinite(target.x) && isfinite(target.y)) {
            UIBezierPath *line = [UIBezierPath bezierPath];
            [line moveToPoint:CGPointMake(width * 0.5f, height * 0.5f)];
            [line addLineToPoint:target];
            gAimLineLayer.path = line.CGPath;
            gAimLineLayer.hidden = NO;
        } else {
            gAimLineLayer.path = nil;
            gAimLineLayer.hidden = YES;
        }
    } else {
        gAimLineLayer.path = nil;
        gAimLineLayer.hidden = YES;
    }
}

static void esp_draw_overlay_render_packet_internal(const ESPDrawPacket *packet) {
    if (gDrawState != ESPDrawOverlayStateRunning || !gDrawRoot)
        return;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    CGFloat width = (CGFloat)gDrawScreenWidth;
    CGFloat height = (CGFloat)gDrawScreenHeight;
    // Publish-frame line buffer uses y=35; subtract info offset at target.
    CGPoint lineOrigin = CGPointMake(width * 0.5f, 35.0f);
    BOOL validPacket = esp_draw_overlay_packet_header_is_valid(packet);
    uint32_t visible = 0;
    if (validPacket) {
        for (uint32_t i = 0; i < packet->count && i < ESP_MAX_DRAW_PLAYERS; i++) {
            if (esp_draw_overlay_apply_player(i, packet, lineOrigin)) visible++;
        }
        esp_draw_overlay_hide_slots_from(packet->count);
    } else {
        esp_draw_overlay_hide_slots_from(0);
    }
    esp_draw_overlay_apply_counter(visible, width, validPacket && packet->showPlayerCount);
    esp_draw_overlay_apply_aim_overlay(packet, width, height, validPacket);

    [CATransaction commit];
}

static BOOL esp_draw_overlay_packet_header_is_valid(const ESPDrawPacket *packet) {
    if (!packet || packet->magic != ESP_DRAW_MAGIC) return NO;
    if (packet->count > ESP_MAX_DRAW_PLAYERS) return NO;
    return YES;
}

static void esp_draw_overlay_drain_pending_packet(void) {
    ESPDrawPacket localPacket = {0};
    os_unfair_lock_lock(&gPacketLock);
    memcpy(&localPacket, &gPendingPacket, sizeof(localPacket));
    gPacketDeliveryScheduled = NO;
    os_unfair_lock_unlock(&gPacketLock);
    esp_draw_overlay_render_packet_internal(&localPacket);
}

static void esp_draw_overlay_enqueue_packet(const ESPDrawPacket *packet) {
    os_unfair_lock_lock(&gPacketLock);
    memcpy(&gPendingPacket, packet, sizeof(gPendingPacket));
    BOOL shouldSchedule = !gPacketDeliveryScheduled;
    gPacketDeliveryScheduled = YES;
    os_unfair_lock_unlock(&gPacketLock);
    if (!shouldSchedule) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        esp_draw_overlay_drain_pending_packet();
    });
}

void esp_draw_overlay_update_packet(const ESPDrawPacket *packet) {
    if (!packet) return;

    // Invalid headers are still forwarded to clear stale slots, but malformed
    // counts are rejected before they can reach the renderer's loop.
    if (packet->magic == ESP_DRAW_MAGIC && packet->count > ESP_MAX_DRAW_PLAYERS) {
        ESPDrawPacket empty = {0};
        packet = &empty;
    }

    if ([NSThread isMainThread]) {
        esp_draw_overlay_render_packet_internal(packet);
    } else {
        esp_draw_overlay_enqueue_packet(packet);
    }
}

void esp_draw_overlay_tick(void) {
    // Intentionally empty: packets arrive from the 15Hz worker via update_packet.
    // Kept for ABI compatibility with older callers.
}
