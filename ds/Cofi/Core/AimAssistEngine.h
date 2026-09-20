#ifndef AimAssistEngine_h
#define AimAssistEngine_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "UnityMath.h"

@class ESPFrameSnapshot;

/// Overlay-facing result of one aim pass. The frame builder copies these
/// fields into the ESPDrawPacket so the SpringBoard-hosted overlay can draw
/// the FOV circle and the lock line without any game-memory access of its own.
struct AimAssistOutcome {
    BOOL active;          // Aimbot enabled AND a valid in-match frame ran.
    BOOL showFov;         // Draw the FOV circle this frame.
    float fovRadius;      // Circle radius in overlay points (aimFov).
    BOOL showLine;        // User enables the lock line (renew.aimLine).
    BOOL hasTarget;       // A locked target exists this frame.
    CGPoint targetPoint;  // Screen-space aim point of the locked target.
    float targetDistance; // 3D distance to the locked target (meters).
    BOOL firedRemote;     // At least one remote aim write was issued.
};

/// Dump-verified weapon readout used for bullet prediction.
struct AimWeaponData {
    float fireInterval;        // seconds between shots
    bool  isSingleShot;        // AWM / M590 style weapons
    float fullDamageDistance;  // range where damage falloff begins
    float range;               // effective range (m)
};

/// Aim assist engine (VIP-standard port). Runs on the ESP worker tick inside
/// the app process, reuses the frame snapshot + calibrated camera projection,
/// selects the best target inside the aim FOV, predicts bullet travel, and
/// steers the local player's aim rotation through the kernel write transport.
///
/// Every remote write is gated behind RemoteWriteDomain::Aim and fails closed.
@interface AimAssistEngine : NSObject

- (void)reset;

/// Lightweight preference mirror used when a frame has no projection (e.g.
/// zero enemies): keeps the FOV circle visible while in match.
- (BOOL)isFovVisible;
- (float)fovRadius;

/// Runs one aim pass. `projection` must be the calibrated projection from the
/// same frame as `snapshot`. Returns the overlay-facing state for this frame.
- (AimAssistOutcome)processSnapshot:(ESPFrameSnapshot *)snapshot
                         projection:(const CameraProjection *)projection
                        screenWidth:(float)screenWidth
                       screenHeight:(float)screenHeight;

/// Re-reads the aim preference set (renew.aim* keys) and re-arms the Aim
/// write domain accordingly. Cheap enough to call every tick; internal sync
/// counters throttle the actual NSUserDefaults traffic.
- (void)syncPreferences;

@end

#endif /* AimAssistEngine_h */
