// Core/AimAssistEngine.mm — VIP-standard aim assist for DSWUnity.
//
// Faithful port of the reference Vip build's aimbot pipeline:
//   target scan (FOV window + score) -> lock persistence -> velocity
//   prediction (PhysicalCCT + tracker + weapon data) -> quaternion steering
//   (Slerp + AuxAimResetTime + pitch limits) -> single-shot snap + auto-fire.
//
// Cofi differences that are deliberate:
//   * Prediction feeds the LOCAL player's weapon into GetWeaponData (the
//     reference comment states this intent but passed the target pawn).
//   * AimSpeed preference scales the Slerp factor; 1000 reproduces the
//     reference constants exactly.
//   * All writes flow through RemoteWriteDomain::Aim and fail closed.

#import "AimAssistEngine.h"
#import "../drawing_view/ESPDataCollector.h"
#import "MemoryUtils.h"
#import "GameOffsets.h"
#import "GameLogic.h"
#import "LogTextView.h"

#import <mach/mach_time.h>
#import <QuartzCore/QuartzCore.h>
#import <cmath>
#import <float.h>

#pragma mark - Tunables (reference defaults)

static const float kAimFovMin = 5.0f;
static const float kAimFovMax = 500.0f;
static const float kAimSpeedMin = 1.0f;
static const float kAimSpeedMax = 2000.0f;
static const float kAimSpeedReference = 1000.0f; // reproduces reference Slerp factors
static const float kAimMaxDistance = 1000.0f;    // reference hard cap
static const float kAimCloseRangeBonus = 50.0f;  // meters — near targets prioritised
static const int   kAimLockMaxLostFrames = 2;    // reference lock grace
static const int   kVelocityTrackerCapacity = 64;
static const float kVelocityMaxMagnitude = 100.0f;

#pragma mark - Preference cache

static bool   gAimbot = false;
static bool   gShowFov = true;
static bool   gAimLine = false;
static bool   gAimIgnoreBot = false;
static bool   gAimIgnoreKnock = false;
static bool   gAimCheckVisible = true;
static int    gAimPosition = 0;   // 0 head · 1 neck · 2 chest · 3 upper head
static int    gTriggerMode = 0;   // 0 always · 1 firing · 2 scoping · 3 fire|scope
static float  gAimFov = 250.0f;
static float  gAimSpeed = 1000.0f;

#pragma mark - Velocity tracker (per-pawn, reference behaviour)

struct AimVelocityTrack {
    uint64_t pawn;
    Vector3 lastPos;
    Vector3 velocity;
    double lastTime;
};

static AimVelocityTrack gVelocityTracker[kVelocityTrackerCapacity];
static int gVelocityTrackerCount = 0;

static uint64_t gAimLockTarget = 0;
static int gAimLockLostFrames = 0;
static bool gWasScoping = false;

#pragma mark - Write diagnostics (observable on the Log tab)

// Every kernel write issued by the engine flows through AimWrite so the
// session log can prove the transport works on device: a per-tick report
// shows attempted vs failed writes and the current lock state.
static unsigned long long gWriteCalls = 0;
static unsigned long long gWriteFails = 0;
static unsigned long long gWriteReported = 0;
static unsigned int      gWriteReportTick = 0;
static bool              gFirstWriteLogged = false;

template<typename T>
static inline bool AimWrite(uint64_t address, const T &value) {
    ++gWriteCalls;
    bool ok = WriteAddr<T>(RemoteWriteDomain::Aim, address, value);
    if (ok) {
        if (!gFirstWriteLogged) {
            gFirstWriteLogged = true;
            log_user("[AIM] First kernel write OK (0x%llx)\n",
                     (unsigned long long)address);
        }
    } else {
        ++gWriteFails;
    }
    return ok;
}

static void AimReportWriteStats(bool locked) {
    if (++gWriteReportTick < 60) return;   // ~2 s at 30 Hz
    gWriteReportTick = 0;
    if (gWriteCalls == gWriteReported) return;
    log_user("[AIM] writes=%llu (+%llu) fail=%llu lock=%s\n",
             gWriteCalls, gWriteCalls - gWriteReported, gWriteFails,
             locked ? "yes" : "no");
    gWriteReported = gWriteCalls;
}

#pragma mark - Small helpers

static inline bool AimIsZeroVec(const Vector3 &v) {
    return v.x == 0.0f && v.y == 0.0f && v.z == 0.0f;
}

static inline float AimClamp(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static double AimMediaTime(void) {
    return CACurrentMediaTime();
}

// Reference GetRotationToLocation (yBias removed upstream, kept removed).
static inline Quaternion GetRotationToLocation(Vector3 target, Vector3 myLoc) {
    return Quaternion::LookRotation(target - myLoc, Vector3(0, 1, 0));
}

static bool AimGetIsFiring(uint64_t player) {
    uint16_t value = 0;
    return TryGetDataUInt16(player, GameOffsets::PriVarFire, &value) && value == 2;
}

static bool AimGetIsScoping(uint64_t player) {
    uint16_t value = 0;
    return TryGetDataUInt16(player, GameOffsets::PriVarScope, &value) && value != 0;
}

#pragma mark - Aim point selection (reference GetAimTargetPos)

// Returns the world aim point for the requested body position, or a zero
// vector when the head/hip pair fails the reference 3D sanity window.
static Vector3 GetAimTargetPos(Vector3 head, Vector3 hip, int setting) {
    if (AimIsZeroVec(head) || AimIsZeroVec(hip)) return Vector3(0, 0, 0);

    float dx = head.x - hip.x;
    float dy = head.y - hip.y;
    float dz = head.z - hip.z;
    float dist3D = sqrtf(dx * dx + dy * dy + dz * dz);
    if (dist3D < 0.05f || dist3D > 5.0f) return Vector3(0, 0, 0);

    Vector3 bodyDir = Vector3(dx, dy, dz);
    switch (setting) {
        case 1:  return head - bodyDir * 0.18f;   // neck
        case 2:  return head - bodyDir * 0.30f;   // chest
        case 3:  return head - bodyDir * 0.072f;  // upper head
        case 0:
        default: return head;                     // head
    }
}

static uint64_t ReadHipTransform(uint64_t pawn) {
    uint64_t bodyPart = ReadAddr<uint64_t>(pawn + GameOffsets::PlayerHipNode);
    if (!isValidPtr(bodyPart)) return 0;
    return ReadAddr<uint64_t>(bodyPart + GameOffsets::TransformNodeTransform);
}

#pragma mark - Weapon data (dump-verified chain)

static AimWeaponData GetWeaponData(uint64_t pawn) {
    AimWeaponData wd{0.1f, false, 100.0f, 200.0f}; // reference defaults
    if (!isValidPtr(pawn)) return wd;

    uint64_t inventory = ReadAddr<uint64_t>(pawn + GameOffsets::PlayerInventoryManager);
    if (!isValidPtr(inventory)) return wd;

    uint64_t weapon = ReadAddr<uint64_t>(inventory + GameOffsets::InventoryItemOnHand);
    if (!isValidPtr(weapon)) return wd;

    uint64_t repItem = ReadAddr<uint64_t>(weapon + GameOffsets::WeaponRepItem);
    if (!isValidPtr(repItem)) return wd;

    wd.fireInterval       = ReadAddr<float>(repItem + GameOffsets::WeaponFireInterval);
    wd.isSingleShot       = ReadAddr<bool>(repItem + GameOffsets::WeaponIsSingleShot);
    wd.fullDamageDistance = ReadAddr<float>(repItem + GameOffsets::WeaponFullDamageDistance);
    wd.range              = ReadAddr<float>(repItem + GameOffsets::WeaponRange);

    // Reference validation clamps — keep implausible reads inert.
    if (!(wd.fireInterval >= 0.01f) || wd.fireInterval > 5.0f) wd.fireInterval = 0.1f;
    if (!(wd.fullDamageDistance >= 1.0f) || wd.fullDamageDistance > 1000.0f) wd.fullDamageDistance = 100.0f;
    if (!(wd.range >= 1.0f) || wd.range > 1000.0f) wd.range = 200.0f;
    return wd;
}

#pragma mark - Velocity sampling + prediction

static Vector3 SampleTargetVelocity(uint64_t pawn, Vector3 currentPos) {
    // 1. Authoritative engine velocity from PhysicalCCT.
    Vector3 gameVel = Vector3(0, 0, 0);
    uint64_t physCCT = ReadAddr<uint64_t>(pawn + GameOffsets::PlayerPhysicalCCT);
    if (isValidPtr(physCCT)) {
        gameVel = ReadAddr<Vector3>(physCCT + GameOffsets::PhysicalCCTVelocity);
        float vmag = sqrtf(gameVel.x * gameVel.x + gameVel.y * gameVel.y + gameVel.z * gameVel.z);
        if (!(vmag == vmag) || vmag > kVelocityMaxMagnitude) gameVel = Vector3(0, 0, 0);
    }

    // 2. Tracker fallback: finite-difference velocity across frames.
    double now = AimMediaTime();
    int idx = -1;
    for (int i = 0; i < gVelocityTrackerCount; i++) {
        if (gVelocityTracker[i].pawn == pawn) { idx = i; break; }
    }
    if (idx == -1) {
        if (gVelocityTrackerCount >= kVelocityTrackerCapacity) return gameVel;
        idx = gVelocityTrackerCount++;
        gVelocityTracker[idx].pawn = pawn;
        gVelocityTracker[idx].lastPos = currentPos;
        gVelocityTracker[idx].velocity = gameVel;
        gVelocityTracker[idx].lastTime = now;
        return gameVel;
    }

    double dt = now - gVelocityTracker[idx].lastTime;
    Vector3 finalVel = gameVel;
    if (dt > 0.001 && dt < 0.5) {
        Vector3 deltaPos = currentPos - gVelocityTracker[idx].lastPos;
        Vector3 calcVel = deltaPos / static_cast<float>(dt);
        if (AimIsZeroVec(gameVel)) {
            finalVel = gVelocityTracker[idx].velocity * 0.6f + calcVel * 0.4f;
        } else {
            finalVel = gameVel * 0.7f + calcVel * 0.3f;
        }
    }

    gVelocityTracker[idx].lastPos = currentPos;
    gVelocityTracker[idx].velocity = finalVel;
    gVelocityTracker[idx].lastTime = now;
    return finalVel;
}

// Reference PredictTargetPosition: blend engine + tracker velocity, convert
// distance into travel time via the weapon's damage/range profile, then
// extrapolate. `weapon` comes from the LOCAL player.
static Vector3 PredictTargetPosition(uint64_t pawn,
                                     Vector3 currentPos,
                                     float distance,
                                     const AimWeaponData &weapon) {
    if (!isValidPtr(pawn)) return currentPos;

    Vector3 finalVel = SampleTargetVelocity(pawn, currentPos);
    if (distance > weapon.range) return currentPos;

    float travelTime = distance / weapon.fullDamageDistance;
    if (travelTime > weapon.fireInterval) travelTime = weapon.fireInterval;
    if (travelTime < 0.0f) travelTime = 0.0f;

    return currentPos + finalVel * travelTime;
}

#pragma mark - Aim steering (reference set_aim)

// Reference write set: AuxAimResetTime=0 for instant retarget, widened pitch
// limits for snap-aim, then a Slerped quaternion into both rotation slots.
// AimSpeed scales the Slerp factor; 1000 == the reference constants.
static bool AimWriteSteering(uint64_t myPawn,
                             Quaternion rotation,
                             bool isFiring,
                             bool isScoping,
                             bool instant) {
    if (!isValidPtr(myPawn)) return false;

    bool wrote = false;
    float zero = 0.0f;
    wrote |= AimWrite(myPawn + GameOffsets::PlayerAuxAimResetTime, zero);
    wrote |= AimWrite(myPawn + GameOffsets::PlayerMinAngleX, -89.0f);
    wrote |= AimWrite(myPawn + GameOffsets::PlayerMaxAngleX, 89.0f);

    // Scope release: restore the current rotation instead of chasing the
    // stale target quaternion (reference gWasScoping transition).
    if (gWasScoping && !isScoping) {
        Quaternion currentRot = ReadAddr<Quaternion>(myPawn + GameOffsets::PlayerAimRotation);
        wrote |= AimWrite(myPawn + GameOffsets::PlayerAimRotation, currentRot);
        wrote |= AimWrite(myPawn + GameOffsets::PlayerAimRotationAux, currentRot);
        gWasScoping = false;
        return wrote;
    }
    gWasScoping = isScoping;

    Quaternion q = Quaternion::Normalized(rotation);
    Quaternion current = ReadAddr<Quaternion>(myPawn + GameOffsets::PlayerAimRotation);

    if (instant) {
        // Single-shot weapons: snap exactly onto the predicted point.
        wrote |= AimWrite(myPawn + GameOffsets::PlayerAimRotation, q);
        wrote |= AimWrite(myPawn + GameOffsets::PlayerAimRotationAux, q);
        return wrote;
    }

    float angle = Quaternion::Angle(current, q);
    if (angle < 0.0005f) return wrote;

    float scale = AimClamp(gAimSpeed / kAimSpeedReference, 0.1f, 2.0f);
    float t = isFiring ? fminf(0.97f, 0.97f * scale)
            : isScoping ? fminf(0.92f, 0.92f * scale)
                        : fminf(0.85f, 0.85f * scale);
    t = AimClamp(t, 0.25f, 0.97f);

    Quaternion out = Quaternion::Normalized(Quaternion::Slerp(current, q, t));
    wrote |= AimWrite(myPawn + GameOffsets::PlayerAimRotation, out);
    wrote |= AimWrite(myPawn + GameOffsets::PlayerAimRotationAux, out);
    return wrote;
}

#pragma mark - Engine

@implementation AimAssistEngine {
    uint32_t _syncCounter;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _syncCounter = 0;
    }
    return self;
}

- (void)reset {
    gAimLockTarget = 0;
    gAimLockLostFrames = 0;
    gWasScoping = false;
    gVelocityTrackerCount = 0;
    memset(gVelocityTracker, 0, sizeof(gVelocityTracker));
}

- (BOOL)isFovVisible {
    return gAimbot && gShowFov;
}

- (float)fovRadius {
    return gAimFov;
}

- (void)syncPreferences {
    // Prefs are cheap to read but the worker ticks up to 30 Hz; sync every
    // 8 ticks (~0.27 s at 30 Hz) so in-game menu changes land quickly while
    // keeping NSUserDefaults traffic negligible.
    if (++_syncCounter < 8) {
        return;
    }
    _syncCounter = 0;

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gAimbot          = [d boolForKey:@"renew.aimbot"];
    gShowFov         = [d objectForKey:@"renew.showFov"] ? [d boolForKey:@"renew.showFov"] : YES;
    gAimLine         = [d boolForKey:@"renew.aimLine"];
    gAimIgnoreBot    = [d boolForKey:@"renew.aimIgnoreBot"];
    gAimIgnoreKnock  = [d boolForKey:@"renew.aimIgnoreKnock"];
    gAimCheckVisible = [d objectForKey:@"renew.aimCheckVisible"] ? [d boolForKey:@"renew.aimCheckVisible"] : YES;

    NSInteger pos = [d integerForKey:@"renew.aimPos"];
    gAimPosition = (pos >= 0 && pos <= 3) ? static_cast<int>(pos) : 0;

    NSInteger trigger = [d integerForKey:@"renew.aimTrigger"];
    gTriggerMode = (trigger >= 0 && trigger <= 3) ? static_cast<int>(trigger) : 0;

    float fov = [d floatForKey:@"renew.aimFov"];
    if (fov != 0.0f) gAimFov = AimClamp(fov, kAimFovMin, kAimFovMax);
    else gAimFov = 250.0f;

    float speed = [d floatForKey:@"renew.aimSpeed"];
    if (speed != 0.0f) gAimSpeed = AimClamp(speed, kAimSpeedMin, kAimSpeedMax);
    else gAimSpeed = kAimSpeedReference;

    // Arm the write domain only while aimbot is on. The aim pass itself runs
    // even when writes are disarmed (the FOV circle still renders), but every
    // WriteAddr call below fails closed unless this is armed.
    SetRemoteWriteDomainEnabled(RemoteWriteDomain::Aim, gAimbot);
}

- (AimAssistOutcome)processSnapshot:(ESPFrameSnapshot *)snapshot
                         projection:(const CameraProjection *)projection
                        screenWidth:(float)screenWidth
                       screenHeight:(float)screenHeight {
    AimAssistOutcome outcome = {};
    outcome.showFov = gShowFov;
    outcome.fovRadius = gAimFov;
    outcome.showLine = gAimLine;
    outcome.active = gAimbot;

    if (!gAimbot || !snapshot.isValid || !projection ||
        !(screenWidth > 1.0f) || !(screenHeight > 1.0f)) {
        gAimLockTarget = 0;
        gAimLockLostFrames = 0;
        outcome.active = NO;
        outcome.showFov = NO;
        return outcome;
    }

    uint64_t myPawn = snapshot.localPlayer;
    if (!isValidPtr(myPawn)) {
        gAimLockTarget = 0;
        outcome.active = NO;
        outcome.showFov = NO;
        return outcome;
    }

    const float *matrix = projection->matrix;
    const CameraMatrixLayout layout = projection->layout;
    const CGPoint center = CGPointMake(screenWidth * 0.5f, screenHeight * 0.5f);
    const Vector3 myLoc = snapshot.localPosition;

    // Weapon profile of the LOCAL player — drives travel-time prediction and
    // the single-shot snap branch.
    const AimWeaponData myWeapon = GetWeaponData(myPawn);

    const float aimFov = gAimFov;
    const float selectRadius = aimFov * 3.0f; // reference selection window (3x drawn FOV)
    const float selectRadiusSq = selectRadius * selectRadius;

    uint64_t bestTarget = 0;
    Vector3 bestAimPos(0, 0, 0);
    float bestScore = FLT_MAX;
    float bestDistance = FLT_MAX;
    CGPoint bestScreen = center;

    for (ESPPlayerData *p in snapshot.players) {
        if (p.pawn == 0 || !isValidPtr(p.pawn)) continue;
        if (gAimIgnoreBot && p.isBot) continue;
        if (gAimIgnoreKnock && p.isKnocked) continue;
        if (p.distance > kAimMaxDistance || p.distance <= 0.0f) continue;

        // Cheap head projection first; only candidates near the crosshair
        // pay for hip/visibility reads.
        Vector3 w2sHead = WorldToScreen(p.headWorld, matrix, layout,
                                        screenWidth, screenHeight);
        if (!(w2sHead.z > 0.01f)) continue;
        float dxHead = w2sHead.x - center.x;
        float dyHead = w2sHead.y - center.y;
        float headDistSq = dxHead * dxHead + dyHead * dyHead;
        if (headDistSq > selectRadiusSq * 4.0f) continue; // coarse reject (>2x window)

        Vector3 hipWorld = Vector3(0, 0, 0);
        uint64_t hipTransform = ReadHipTransform(p.pawn);
        if (isValidPtr(hipTransform)) hipWorld = getPositionExt(hipTransform);

        Vector3 aimPos = GetAimTargetPos(p.headWorld, hipWorld, gAimPosition);
        if (AimIsZeroVec(aimPos)) continue;

        Vector3 w2sAim = WorldToScreen(aimPos, matrix, layout,
                                       screenWidth, screenHeight);
        if (!(w2sAim.z > 0.01f)) continue;

        float dx = w2sAim.x - center.x;
        float dy = w2sAim.y - center.y;
        float dSq = dx * dx + dy * dy;
        if (dSq > selectRadiusSq) continue;

        // Reference gate polarity: with "Aim Through Walls" ON (default) the
        // visible-only filter is skipped entirely; turning it OFF restricts
        // aim to avatars the game is actually rendering. The check uses the
        // proven AvatarManager -> IUmaAvatar -> IsVisible chain.
        if (!gAimCheckVisible && !IsPlayerAvatarRendered(p.pawn)) continue;

        // Reference scoring: screen distance dominates, locked target and
        // close-range enemies get multiplicative priority.
        float score = dSq;
        if (p.pawn == gAimLockTarget) score *= 0.5f;
        if (p.distance < kAimCloseRangeBonus) score *= 0.7f;

        if (score < bestScore) {
            bestScore = score;
            bestDistance = p.distance;
            bestTarget = p.pawn;
            bestAimPos = aimPos;
            bestScreen = CGPointMake(w2sAim.x, w2sAim.y);
        }
    }

    // Lock persistence (reference: 2 lost frames).
    if (bestTarget) {
        gAimLockTarget = bestTarget;
        gAimLockLostFrames = 0;
    } else if (gAimLockTarget) {
        if (++gAimLockLostFrames > kAimLockMaxLostFrames) {
            gAimLockTarget = 0;
            gAimLockLostFrames = 0;
        }
    }

    outcome.hasTarget = (bestTarget != 0 && gAimLockTarget != 0);
    if (outcome.hasTarget) {
        outcome.targetPoint = bestScreen;
        outcome.targetDistance = bestDistance;
    }

    if (!gAimbot) return outcome;

    const bool firing = AimGetIsFiring(myPawn);
    const bool scoping = AimGetIsScoping(myPawn);
    AimReportWriteStats(bestTarget != 0);

    bool shouldAim = false;
    switch (gTriggerMode) {
        case 1:  shouldAim = firing; break;
        case 2:  shouldAim = scoping; break;
        case 3:  shouldAim = (firing || scoping); break;
        case 0:
        default: shouldAim = true; break;
    }

    if (bestTarget && shouldAim && bestDistance >= 0.2f) {
        Vector3 finalTarget = PredictTargetPosition(bestTarget, bestAimPos,
                                                    bestDistance, myWeapon);
        if (!AimIsZeroVec(finalTarget)) {
            Quaternion exactQ = GetRotationToLocation(finalTarget, myLoc);

            bool wrote = AimWriteSteering(myPawn, exactQ, firing, scoping,
                                          /*instant=*/false);
            outcome.firedRemote |= wrote;

            // Single-shot weapons (AWM/M590): snap precisely onto the
            // velocity-extrapolated point before the trigger lands.
            if (myWeapon.isSingleShot) {
                Vector3 targetVel = SampleTargetVelocity(bestTarget, bestAimPos);
                float travelTime = bestDistance / myWeapon.fullDamageDistance;
                if (travelTime > myWeapon.fireInterval) travelTime = myWeapon.fireInterval;
                if (travelTime < 0.0f) travelTime = 0.0f;

                Vector3 preciseTarget = bestAimPos + targetVel * travelTime;
                Quaternion preciseQ = GetRotationToLocation(preciseTarget, myLoc);
                wrote = AimWriteSteering(myPawn, preciseQ, firing, scoping,
                                         /*instant=*/true);
                outcome.firedRemote |= wrote;
            }

            // While firing, force the exact rotation (reference hard-write).
            if (firing) {
                Quaternion q = Quaternion::Normalized(exactQ);
                bool forced =
                    AimWrite(myPawn + GameOffsets::PlayerAimRotation, q) ||
                    AimWrite(myPawn + GameOffsets::PlayerAimRotationAux, q);
                outcome.firedRemote |= forced;
            }

            // Auto-fire for trigger modes that hold the trigger for the user.
            if (gTriggerMode == 1 || (gTriggerMode == 3 && firing)) {
                uint16_t fireState = 2;
                ++gWriteCalls;
                bool fired = TrySetDataUInt16(myPawn, GameOffsets::PriVarFire, fireState);
                if (!fired) ++gWriteFails;
                outcome.firedRemote |= fired;
                if (fired) {
                    Quaternion q = Quaternion::Normalized(exactQ);
                    AimWrite(myPawn + GameOffsets::PlayerAimRotation, q);
                    AimWrite(myPawn + GameOffsets::PlayerAimRotationAux, q);
                }
            }

            gWasScoping = scoping;
        }
    } else {
        // No admissible target: keep the current rotation but continue
        // zeroing AuxAimResetTime / widening pitch limits so the next
        // acquisition is instant (reference behaviour).
        Quaternion currentRot = ReadAddr<Quaternion>(myPawn + GameOffsets::PlayerAimRotation);
        bool wrote = AimWriteSteering(myPawn, currentRot, firing, scoping,
                                      /*instant=*/false);
        outcome.firedRemote |= wrote;

        if (gAimLockTarget) {
            gAimLockTarget = 0;
            gAimLockLostFrames = 0;
            outcome.hasTarget = NO;
        }
    }

    return outcome;
}

@end
