#import "ESPDataCollector.h"

#include <climits>

// String literals stay in the clear; the app doesn't rely on the external
// obfuscation macro that the original module used.
#ifndef GX_SECURE_NS
#define GX_SECURE_NS(x) @x
#endif
#ifndef GX_SECURE_C
#define GX_SECURE_C(x) x
#endif

uint64_t ModuleBase = 0;
static const NSUInteger kEntityTrackCapacity = kMaxTrackedPlayers * 2;

// Slow-stream refresh cadences: positions stay per-frame fresh, while data
// that barely changes (names, HP, bone references) is re-read far
// less often — each skipped refresh saves several cross-process Mach traps.
static const uint64_t kMetaRefreshFrames = 8;      // HP: ~7.5 Hz @60fps
static const uint64_t kIdentityRefreshFrames = 60; // nicknames: 1 Hz
static const uint64_t kBoneRefreshFrames = 30;     // 2x per second
// Cross-process transform/PVS reads are not atomic with the game's animation
// update. A confirmed actor therefore gets a very short grace window for soft
// read misses. Hard lifecycle gates (dead/knocked/recycled/missing pawn) still
// invalidate immediately, so this removes blink without leaving ghost ESP.
static const int kVisibilityHiddenGraceFrames = 2;
static const int kVisibilityUnreadableGraceFrames = 3;
static const int kGeometryGraceFrames = 2;
static const int kAvatarGraceFrames = 2;
static const float kDistanceEnterHysteresisMeters = 3.0f;
static const float kMaxBodyRootExtentMeters = 7.0f;

struct ESPEntityTrack {
    uint64_t pawn;
    uint64_t playerId;
    Vector3 root;
    Vector3 head;
    Vector3 toe;
    uint64_t lastFrame;
    int stableFrames;
    int geometryMissFrames;
    int avatarMissFrames;
    bool withinDistance;

    // Two visible samples admit an actor; any hidden/unreadable sample then
    // invalidates spatial state immediately.
    int visibleFrames;
    int hiddenFrames;
    int visibilityUnreadableFrames;

    // Metadata slow stream.
    __strong NSString *name;
    int cachedCurHP;
    int cachedMaxHP;
    bool hasCachedCurHP;
    bool isBot;
    bool hasBotState;
    bool isInVehicle;
    bool hasVehicleState;
    bool isKnocked;
    bool hasKnockedState;
    uint64_t metaLastFrame;
    uint64_t identityLastFrame;

    // Skeleton transform-node references (stable while a pawn lives).
    uint64_t bHead, bHipsNode, bLAnkle, bRAnkle, bLShoulder, bRShoulder;
    uint64_t bRHand, bLHand, bRElbow, bLElbow, bSpine, bHeadBone, bHipsBone;
    uint64_t bonesLastFrame;
};

static inline BOOL ContainsAddress(const uint64_t *values,
                                   NSUInteger count,
                                   uint64_t value) {
    for (NSUInteger i = 0; i < count; i++) {
        if (values[i] == value) return YES;
    }
    return NO;
}

static ESPEntityTrack *FindOrCreateTrack(ESPEntityTrack *tracks,
                                         NSUInteger capacity,
                                         uint64_t pawn) {
    ESPEntityTrack *emptySlot = nullptr;
    ESPEntityTrack *oldestSlot = &tracks[0];

    for (NSUInteger i = 0; i < capacity; i++) {
        ESPEntityTrack *track = &tracks[i];
        if (track->pawn == pawn) return track;
        if (track->pawn == 0 && emptySlot == nullptr) emptySlot = track;
        if (track->lastFrame < oldestSlot->lastFrame) oldestSlot = track;
    }

    ESPEntityTrack *slot = emptySlot != nullptr ? emptySlot : oldestSlot;
    *slot = ESPEntityTrack();
    slot->pawn = pawn;
    return slot;
}

static inline BOOL IsValidWorldPosition(Vector3 point) {
    if (!isfinite(point.x) || !isfinite(point.y) || !isfinite(point.z)) {
        return NO;
    }
    float magnitude = fabsf(point.x) + fabsf(point.y) + fabsf(point.z);
    return magnitude > 0.001f && magnitude < 10000000.0f;
}

static inline int IncrementSaturated(int value) {
    return value < INT_MAX ? value + 1 : INT_MAX;
}

static inline void InvalidateTrackSpatialState(ESPEntityTrack *track) {
    if (track == nullptr) return;
    track->head = Vector3::zero();
    track->toe = Vector3::zero();
    track->root = Vector3::zero();
    track->stableFrames = 0;
    track->geometryMissFrames = 0;
    track->visibleFrames = 0;
    track->withinDistance = false;
}

static inline void InvalidateTrackBones(ESPEntityTrack *track) {
    if (track == nullptr) return;
    track->bHead = 0;
    track->bHipsNode = 0;
    track->bLAnkle = 0;
    track->bRAnkle = 0;
    track->bLShoulder = 0;
    track->bRShoulder = 0;
    track->bRHand = 0;
    track->bLHand = 0;
    track->bRElbow = 0;
    track->bLElbow = 0;
    track->bSpine = 0;
    track->bHeadBone = 0;
    track->bHipsBone = 0;
    track->bonesLastFrame = 0;
}

@implementation ESPPlayerData
@end

@implementation ESPFrameSnapshot
- (instancetype)init {
    if (self = [super init]) {
        _players = [NSMutableArray arrayWithCapacity:kMaxTrackedPlayers];
    }
    return self;
}
@end


@implementation ESPDataCollector {
    int _invalidMatchFrames;
    uint64_t _frameIndex;
    uint64_t _activeMatch;
    // Fixed storage keeps the collector independent from the host C++
    // hash-table runtime when cross-compiling the iOS target on Termux.
    ESPEntityTrack _entityTracks[kEntityTrackCapacity];
}

- (ESPFrameSnapshot *)collectFrame:(CGSize)overlaySize {
    @autoreleasepool {
        if (++_frameIndex == 0) {
            for (NSUInteger i = 0; i < kEntityTrackCapacity; i++) {
                _entityTracks[i] = ESPEntityTrack();
            }
            _frameIndex = 1;
        }
        ESPFrameSnapshot *snapshot = [[ESPFrameSnapshot alloc] init];
        snapshot.isValid = NO;
        snapshot.enemyCount = 0;

        if (!isfinite(overlaySize.width) || !isfinite(overlaySize.height) ||
            overlaySize.width <= 1.0 || overlaySize.height <= 1.0 ||
            overlaySize.width > 16384.0 || overlaySize.height > 16384.0) {
            snapshot.statusMessage = GX_SECURE_NS("Invalid overlay bounds");
            return snapshot;
        }

        // --- 1. Module Base ---
        // Module base is owned by the installer view controller; the
        // collector waits until it becomes available instead of attaching
        // through its own primitive.
        if (!isValidPtr(ModuleBase)) {
            snapshot.statusMessage = GX_SECURE_NS("Waiting for game module");
            return snapshot;
        }
        // --- 2. Pointer Chain: matchGame -> camera -> match -> localPlayer ---
        uint64_t matchGame = getMatchGame(ModuleBase);
        if (!isValidPtr(matchGame)) {
            _invalidMatchFrames = IncrementSaturated(_invalidMatchFrames);
            if (_invalidMatchFrames > 100) {
                // Drop the stale image; the outer installer will re-populate
                // ModuleBase once a live UnityFramework mapping is found.
                ModuleBase = 0;
                _invalidMatchFrames = 0;
            }
            snapshot.statusMessage = GX_SECURE_NS("Waiting for match");
            return snapshot;
        }
        _invalidMatchFrames = 0;
        uint64_t camera = CameraMain(matchGame);
        if (!isValidPtr(camera)) {
            snapshot.statusMessage = GX_SECURE_NS("Waiting for camera");
            return snapshot;
        }
        snapshot.camera = camera;
        snapshot.cameraManager = ReadAddr<uint64_t>(
            matchGame + GameOffsets::MatchGameCameraControllerManager);

        uint64_t match = getMatch(matchGame);
        if (!isValidPtr(match)) {
            snapshot.statusMessage = GX_SECURE_NS("Waiting for match data");
            return snapshot;
        }
        snapshot.match = match;

        if (_activeMatch != match) {
            for (NSUInteger i = 0; i < kEntityTrackCapacity; i++) {
                _entityTracks[i] = ESPEntityTrack();
            }
            _activeMatch = match;
        }

        uint64_t localPlayer = getLocalPlayer(match);
        if (!isValidPtr(localPlayer)) {
            snapshot.statusMessage = GX_SECURE_NS("Waiting for local player");
            return snapshot;
        }
    snapshot.localPlayer = localPlayer;

    uint64_t localPlayerClass = 0;
    if (!TryReadAddr(localPlayer, &localPlayerClass) ||
        !isValidPtr(localPlayerClass)) {
        snapshot.statusMessage = GX_SECURE_NS("Invalid local player class");
        return snapshot;
    }

    // --- 3. Local Player Validation ---
    uint64_t mainCameraTransform = ReadAddr<uint64_t>(
        localPlayer + GameOffsets::PlayerMainCameraTransform);
    Vector3 localPos = getPositionExt(mainCameraTransform);
    if (!IsValidWorldPosition(localPos)) {
        snapshot.statusMessage = GX_SECURE_NS("Waiting for local transform");
        return snapshot;
    }
    snapshot.localPosition = localPos;

    Quaternion viewRotation = {};
    if (TryReadAddr(localPlayer + GameOffsets::PlayerAimRotation,
                    &viewRotation)) {
        float rotationNorm = Quaternion::Norm(viewRotation);
        if (isfinite(rotationNorm) && rotationNorm > 0.5f &&
            rotationNorm < 1.5f) {
            snapshot.viewRotation = Quaternion::Normalized(viewRotation);
            snapshot.hasViewRotation = YES;
        }
    }

    // --- 4. Player Dictionary ---
    uint64_t playerDictionary = 0;
    if (!TryReadAddr(match + GameOffsets::MatchShortIdToPlayers,
                     &playerDictionary) || !isValidPtr(playerDictionary)) {
        snapshot.statusMessage = GX_SECURE_NS("Waiting for players");
        return snapshot;
    }

    uint64_t playerEntries = 0;
    int countValue = 0;
    if (!TryReadAddr(playerDictionary + GameOffsets::DictionaryEntries,
                     &playerEntries) ||
        !TryReadAddr(playerDictionary + GameOffsets::DictionaryCount,
                     &countValue) ||
        !isValidPtr(playerEntries)) {
        snapshot.statusMessage = GX_SECURE_NS("Waiting for player entries");
        return snapshot;
    }

    uint64_t entryCapacity = 0;
    if (!TryReadAddr(playerEntries + GameOffsets::ArrayLength,
                     &entryCapacity) ||
        countValue < 0 || countValue > kMaxTrackedPlayers ||
        entryCapacity < static_cast<uint64_t>(countValue) ||
        entryCapacity > 256) {
        snapshot.statusMessage = GX_SECURE_NS("Invalid player container");
        return snapshot;
    }

    // --- 5. Enumerate Enemies ---
    // One transform-cache generation per collection pass: all bones of a
    // character share ancestor chains, so cached reads collapse ~600+ Mach
    // traps per skeleton down to a handful.
    GXBeginTransformReadFrame();

    // Local team identity read ONCE for the whole loop (was re-read inside
    // isLocalTeamMate for every dictionary entry).
    COW_GamePlay_PlayerID_o localPlayerID = ReadPlayerID(localPlayer);

    uint64_t seenPawns[kMaxTrackedPlayers] = {};
    uint64_t seenPlayerIds[kMaxTrackedPlayers] = {};
    NSUInteger seenPawnCount = 0;
    NSUInteger seenPlayerIdCount = 0;
    NSUInteger visibilityRejectedCount = 0;
    NSUInteger visibilityUnknownCount = 0;
    uint32_t visibilitySampleValue = 0;
    uint8_t visibilitySampleInitial = 0;
    int32_t visibilitySampleMode = -1;
    BOOL hasVisibilitySample = NO;
    // Scan the complete dictionary backing array. Valid entries can sit beyond
    // slot 119 after deletions/collisions even when Dictionary.Count <= 120.
    int totalSlots = static_cast<int>(entryCapacity);
    for (int i = 0; i < totalSlots && snapshot.enemyCount < kMaxTrackedPlayers; i++) {
        BytePlayerDictionaryEntry entry = {};
        uint64_t entryAddress = playerEntries + GameOffsets::ArrayItems +
            GameOffsets::BytePlayerEntrySize * static_cast<uint64_t>(i);
        if (!TryReadAddr(entryAddress, &entry)) continue;

        // 1. Skip deleted / empty dictionary buckets (.NET Dictionary hashCode < 0)
        if (entry.hashCode < 0) continue;

        uint64_t pawn = entry.value;
        if (!isValidPtr(pawn) || pawn == localPlayer) {
            continue;
        }

        // Validate player class and ID
        if (ReadAddr<uint64_t>(pawn) != localPlayerClass) continue;
        COW_GamePlay_PlayerID_o playerID = ReadPlayerID(pawn);
        if (PlayerIDIsTeamMate(localPlayerID, playerID)) continue;
        uint64_t stablePlayerId =
            (static_cast<uint64_t>(playerID.m_Value) << 32) | playerID.m_ID;
        if (playerID.m_ShortID != entry.key ||
            (playerID.m_Value == 0 && playerID.m_ID == 0) ||
            ContainsAddress(seenPawns, seenPawnCount, pawn) ||
            ContainsAddress(seenPlayerIds, seenPlayerIdCount, stablePlayerId)) {
            continue;
        }
        if (seenPawnCount >= kMaxTrackedPlayers ||
            seenPlayerIdCount >= kMaxTrackedPlayers) {
            break;
        }
        seenPawns[seenPawnCount++] = pawn;
        seenPlayerIds[seenPlayerIdCount++] = stablePlayerId;

        ESPEntityTrack *track = FindOrCreateTrack(
            _entityTracks, kEntityTrackCapacity, pawn);
        if (track->playerId != 0 && track->playerId != stablePlayerId) {
            *track = ESPEntityTrack();
            track->pawn = pawn;
        }
        track->playerId = stablePlayerId;

        // Lifecycle gates: batch read EntityIsRecycle (0x28), EntityCachedTransform (0x58),
        // and PlayerIsDead (0x7C) in a single Mach syscall (0x60 bytes) instead of multiple traps.
        uint8_t entityChunk[0x60] = {0};
        if (!_read(pawn + GameOffsets::EntityIsRecycle, entityChunk, sizeof(entityChunk))) {
            *track = ESPEntityTrack();
            continue;
        }
        uint8_t recycleState = entityChunk[0];
        uint8_t deadState = entityChunk[GameOffsets::PlayerIsDead - GameOffsets::EntityIsRecycle];
        if (recycleState != 0 || deadState != 0) {
            *track = ESPEntityTrack();
            continue;
        }
        uint64_t preloadedRootTransform = 0;
        memcpy(&preloadedRootTransform,
               &entityChunk[GameOffsets::EntityCachedTransform - GameOffsets::EntityIsRecycle],
               sizeof(uint64_t));

        // Sample once and share it between knockdown and air-phase gates.
        // Traversing this pointer chain twice would add three remote reads per
        // active enemy on every display frame.
        uint32_t physXState = 0;
        bool physXReadable = TryGetPlayerPhysXState(pawn, &physXState);
        track->isKnocked = IsPlayerKnockedDown(pawn, physXReadable, physXState);
        track->hasKnockedState = true;
        if (track->isKnocked) {
            InvalidateTrackSpatialState(track);
            continue;
        }

        // Batch read PlayerIsClientBot (0x438), PlayerAvatarInitialized (0x458),
        // and PlayerIsInVehicle (0x490) in a single Mach syscall (0x60 bytes).
        uint8_t playerStateChunk[0x60] = {0};
        if (!_read(pawn + GameOffsets::PlayerIsClientBot, playerStateChunk, sizeof(playerStateChunk))) {
            InvalidateTrackSpatialState(track);
            continue;
        }
        uint8_t preloadedBotState = playerStateChunk[0];
        uint8_t avatarInit = playerStateChunk[GameOffsets::PlayerAvatarInitialized - GameOffsets::PlayerIsClientBot];
        uint8_t vehicleState = playerStateChunk[GameOffsets::PlayerIsInVehicle - GameOffsets::PlayerIsClientBot];

        if (avatarInit == 0) {
            track->avatarMissFrames = IncrementSaturated(
                track->avatarMissFrames);
            if (track->stableFrames == 0 ||
                track->avatarMissFrames > kAvatarGraceFrames) {
                InvalidateTrackSpatialState(track);
                continue;
            }
        } else {
            track->avatarMissFrames = 0;
        }

        // Zeppelin cabin gate: only skip players while they are inside the
        // plane cabin before jumping. Once skydiving or parachuting within ESP
        // range, track them so aerial drops and landing approaches are visible.
        uint8_t zeppelinState = 0;
        BOOL zeppelinReadable = TryReadAddr(
            pawn + GameOffsets::PlayerIsInZeppelin, &zeppelinState);
        if (zeppelinReadable && zeppelinState != 0) {
            InvalidateTrackSpatialState(track);
            continue;
        }

        bool isAirborne = physXReadable &&
            (physXState == GameOffsets::PhysXPoseSkyDiving ||
             physXState == GameOffsets::PhysXPoseParachuteFalling);

        if (vehicleState <= 1) {
            track->isInVehicle = vehicleState != 0;
            track->hasVehicleState = true;
        }

        // Model/PVS is the authoritative "game can currently render this
        // actor" signal. Airborne enemies receive an extended grace window
        // because parachute animations and transitional bitmasks can briefly
        // toggle visibility flags.
        bool modelVisible = true;
        uint32_t visibilityValue = 0;
        uint8_t visibilityInitial = 0;
        int32_t visibilityMode = -1;
        bool visibilityReadable = TryGetPlayerModelVisibility(
            pawn, &modelVisible, &visibilityValue,
            &visibilityInitial, &visibilityMode);

        if (visibilityReadable) {
            track->visibilityUnreadableFrames = 0;
            if (!modelVisible) {
                visibilityRejectedCount++;
                if (!hasVisibilitySample) {
                    visibilitySampleValue = visibilityValue;
                    visibilitySampleInitial = visibilityInitial;
                    visibilitySampleMode = visibilityMode;
                    hasVisibilitySample = YES;
                }
                track->visibleFrames = 0;
                track->hiddenFrames = IncrementSaturated(track->hiddenFrames);
                int hiddenGraceLimit = isAirborne ? 8 : kVisibilityHiddenGraceFrames;
                if (track->stableFrames == 0 ||
                    track->hiddenFrames > hiddenGraceLimit) {
                    InvalidateTrackSpatialState(track);
                    continue;
                }
            } else {
                track->visibleFrames = IncrementSaturated(track->visibleFrames);
                track->hiddenFrames = 0;
                int requiredVisibleFrames = isAirborne ? 1 : 2;
                if (track->stableFrames == 0 && track->visibleFrames < requiredVisibleFrames) {
                    continue;
                }
            }
        } else {
            visibilityUnknownCount++;
            track->visibilityUnreadableFrames = IncrementSaturated(
                track->visibilityUnreadableFrames);
            int unreadableGraceLimit = isAirborne ? 6 : kVisibilityUnreadableGraceFrames;
            if (track->stableFrames == 0 ||
                track->visibilityUnreadableFrames > unreadableGraceLimit) {
                InvalidateTrackSpatialState(track);
                continue;
            }
        }

        // Health is needed by target filtering even when its visual rail is
        // hidden, so it remains a low-rate stream.
        BOOL metaStale = (_frameIndex - track->metaLastFrame) >= kMetaRefreshFrames || track->metaLastFrame == 0;
        if (metaStale) {
            uint16_t freshCurHP = 0;
            uint16_t freshMaxHP = 0;
            bool curHPReadable = TryGetDataUInt16(pawn, 0, &freshCurHP);
            bool maxHPReadable = TryGetDataUInt16(pawn, 1, &freshMaxHP);

            constexpr uint16_t kMaximumPlausibleHP = 10000;
            if (curHPReadable && freshCurHP <= kMaximumPlausibleHP) {
                track->cachedCurHP = (int)freshCurHP;
                track->hasCachedCurHP = true;
            }
            if (maxHPReadable && freshMaxHP > 0 &&
                freshMaxHP <= kMaximumPlausibleHP) {
                track->cachedMaxHP = (int)freshMaxHP;
            }
            uint8_t freshBotState = preloadedBotState;
            if (freshBotState <= 1) {
                track->isBot = freshBotState != 0;
                track->hasBotState = true;
            }
            track->metaLastFrame = _frameIndex;
        }

        // Nickname traversal is substantially more expensive and has no
        // consumer when the Names overlay is disabled.
        BOOL identityStale = self.collectNames &&
            (track->identityLastFrame == 0 ||
             (_frameIndex - track->identityLastFrame) >= kIdentityRefreshFrames);
        if (identityStale) {
            NSString *freshName = GetNickName(pawn);
            if (freshName.length > 0) track->name = freshName;
            track->identityLastFrame = _frameIndex;
        }
        NSString *name = track->name.length > 0 ? track->name : GX_SECURE_NS("Enemy");
        int currentHP = track->hasCachedCurHP ? track->cachedCurHP : 100;
        int maxHP = track->cachedMaxHP > 0 ? track->cachedMaxHP : 200;
        currentHP = MAX(0, MIN(currentHP, maxHP));

        // Geometry validation: root + head + toe. Bone transforms may retain a
        // numerically valid final pose after a parachuting/streamed actor leaves
        // the active cell. The Entity root is updated independently and lets us
        // reject a detached/stale bone graph instead of freezing ESP in place.
        uint64_t rootTransform = preloadedRootTransform;
        BOOL rootTransformReadable = isValidPtr(rootTransform);
        Vector3 root = rootTransformReadable
            ? getPositionExt(rootTransform) : Vector3::zero();
        Vector3 head = rootTransformReadable
            ? getPositionExt(getHead(pawn)) : Vector3::zero();
        Vector3 leftToe = rootTransformReadable
            ? getPositionExt(getBone(pawn, GameOffsets::PlayerLeftToeNode))
            : Vector3::zero();
        Vector3 rightToe = rootTransformReadable
            ? getPositionExt(getRightToeNode(pawn)) : Vector3::zero();
        Vector3 toe = Vector3::zero();
        BOOL leftToeValid = IsValidWorldPosition(leftToe);
        BOOL rightToeValid = IsValidWorldPosition(rightToe);
        if (leftToeValid && rightToeValid) {
            // Midpoint keeps the box centered between the feet; the lower Y
            // keeps its base planted on slopes and asymmetric run animations.
            toe = Vector3::Lerp(leftToe, rightToe, 0.5f);
            toe.y = fminf(leftToe.y, rightToe.y);
        } else if (leftToeValid) {
            toe = leftToe;
        } else if (rightToeValid) {
            toe = rightToe;
        }
        BOOL poseFromGraceCache = NO;

        if (!IsValidWorldPosition(root) || !IsValidWorldPosition(head)) {
            track->geometryMissFrames = IncrementSaturated(
                track->geometryMissFrames);
            if (track->stableFrames > 0 &&
                track->geometryMissFrames <= kGeometryGraceFrames &&
                IsValidWorldPosition(track->root) &&
                IsValidWorldPosition(track->head) &&
                IsValidWorldPosition(track->toe)) {
                root = track->root;
                head = track->head;
                toe = track->toe;
                poseFromGraceCache = YES;
            } else {
                InvalidateTrackSpatialState(track);
                continue;
            }
        } else {
            track->geometryMissFrames = 0;
        }

        float rootHeadExtent = Vector3::Distance(root, head);
        if (!isfinite(rootHeadExtent) || rootHeadExtent <= 0.05f ||
            rootHeadExtent > kMaxBodyRootExtentMeters) {
            InvalidateTrackSpatialState(track);
            continue;
        }

        if (!IsValidWorldPosition(toe)) {
            Vector3 leftAnkle = getPositionExt(
                getBone(pawn, GameOffsets::PlayerLeftAnkleNode));
            Vector3 rightAnkle = getPositionExt(
                getBone(pawn, GameOffsets::PlayerRightAnkleNode));
            BOOL leftAnkleValid = IsValidWorldPosition(leftAnkle);
            BOOL rightAnkleValid = IsValidWorldPosition(rightAnkle);
            if (leftAnkleValid && rightAnkleValid) {
                toe = Vector3::Lerp(leftAnkle, rightAnkle, 0.5f);
                toe.y = fminf(leftAnkle.y, rightAnkle.y);
            } else {
                toe = leftAnkleValid ? leftAnkle : rightAnkle;
            }
            if (!IsValidWorldPosition(toe)) {
                if (track->stableFrames > 0 &&
                    track->geometryMissFrames <= kGeometryGraceFrames &&
                    IsValidWorldPosition(track->toe)) {
                    toe = track->toe;
                } else {
                    toe = head - Vector3(0, 1.65f, 0);
                }
            }
        }
        float rootToeExtent = Vector3::Distance(root, toe);
        if (!isfinite(rootToeExtent) || rootToeExtent > kMaxBodyRootExtentMeters) {
            toe = head - Vector3(0, 1.65f, 0);
        }
        float headToeDistance = Vector3::Distance(head, toe);
        if (!isfinite(headToeDistance) || headToeDistance > 2.6f || headToeDistance < 0.2f) {
            toe = head - Vector3(0, 1.65f, 0);
        }

        // Height remains a fallback for transitional objects whose explicit
        // zeppelin/PhysX state could not be read this frame.
        if (!zeppelinReadable && !physXReadable &&
            (head.y - localPos.y) > kEspAirborneDeltaMeters) {
            InvalidateTrackSpatialState(track);
            continue;
        }

        // Distance accounts for both root and head so high aerial drops remain trackable.
        float dist = fminf(Vector3::Distance(localPos, root),
                           Vector3::Distance(localPos, head));
        if (!isfinite(dist) || dist <= 0.0f) {
            InvalidateTrackSpatialState(track);
            continue;
        }
        // Strict track cap: confirmed actors remain visible up to the cap, while
        // an actor that left the range must come back 3 m inside it before
        // re-entry. This prevents boundary flicker without ever drawing >100 m.
        float distanceLimit = track->withinDistance
            ? kEspMaxTrackDistance
            : kEspMaxTrackDistance - kDistanceEnterHysteresisMeters;
        if (dist > distanceLimit) {
            InvalidateTrackSpatialState(track);
            continue;
        }
        track->withinDistance = true;

        // Head/toe are read through separate transform chains and can straddle
        // two game animation updates. Smooth only small, continuous movement;
        // large deltas snap immediately so teleports and rapid camera changes
        // never trail behind. The same alpha preserves body proportions.
        if (!poseFromGraceCache && track->stableFrames > 0 &&
            IsValidWorldPosition(track->head) &&
            IsValidWorldPosition(track->toe)) {
            float headDelta = Vector3::Distance(track->head, head);
            float toeDelta = Vector3::Distance(track->toe, toe);
            float poseDelta = fmaxf(headDelta, toeDelta);
            if (isfinite(poseDelta) && poseDelta < 2.5f) {
                float alpha = 0.62f + fminf(poseDelta / 0.75f, 1.0f) * 0.30f;
                head = Vector3::Lerp(track->head, head, alpha);
                toe = Vector3::Lerp(track->toe, toe, alpha);
            }
        }

        track->root = root;
        track->head = head;
        track->toe = toe;
        track->lastFrame = _frameIndex;
        track->stableFrames = IncrementSaturated(track->stableFrames);

        // --- Build ESPPlayerData ---
        ESPPlayerData *pData = [[ESPPlayerData alloc] init];
        pData.pawn = pawn;
        pData.name = name;
        pData.headWorld = head;
        pData.toeWorld = toe;
        pData.distance = dist;
        pData.currentHP = currentHP;
        pData.maxHP = maxHP;
        pData.isBot = track->hasBotState && track->isBot;
        pData.isInVehicle = track->hasVehicleState && track->isInVehicle;
        pData.isKnocked = track->hasKnockedState && track->isKnocked;

        // Skeleton transform-node references — stable while a pawn lives, so
        // re-resolve them only twice a second (14 Mach traps saved per enemy
        // per frame in between).
        BOOL wantsSkeleton = self.collectSkeleton && !pData.isInVehicle &&
            dist < kEspSkeletonLodDistance;
        BOOL bonesStale = wantsSkeleton &&
            (track->bonesLastFrame == 0 ||
             (_frameIndex - track->bonesLastFrame) >= kBoneRefreshFrames);
        if (bonesStale) {
            // Batch read for nodes layout: HeadNode (0x638) to LeftForeArmNode
            // (0x6C8) = 0x98 bytes.
            uint64_t nodeBlock[19] = {0};
            bool nodeBlockReadable = _read(
                pawn + GameOffsets::PlayerHeadNode,
                nodeBlock, sizeof(nodeBlock));

            auto getTransNodeFromBlock = [](uint64_t bodyPart) -> uint64_t {
                if (!isValidPtr(bodyPart)) return 0;
                return ReadAddr<uint64_t>(bodyPart + GameOffsets::TransformNodeTransform);
            };

            if (!nodeBlockReadable) {
                InvalidateTrackBones(track);
            } else {
                track->bHead      = getTransNodeFromBlock(nodeBlock[0]);
                track->bHipsNode  = getTransNodeFromBlock(nodeBlock[1]);
                track->bLAnkle    = getTransNodeFromBlock(nodeBlock[7]);
                track->bRAnkle    = getTransNodeFromBlock(nodeBlock[8]);
                track->bLShoulder = getTransNodeFromBlock(nodeBlock[13]);
                track->bRShoulder = getTransNodeFromBlock(nodeBlock[14]);
                track->bRHand     = getTransNodeFromBlock(nodeBlock[15]);
                track->bLHand     = getTransNodeFromBlock(nodeBlock[16]);
                track->bRElbow    = getTransNodeFromBlock(nodeBlock[17]);
                track->bLElbow    = getTransNodeFromBlock(nodeBlock[18]);
            }

            // Batch read for bones layout: SpineBone (0x970) to HipsBone
            // (0x990) = 0x28 bytes.
            uint64_t boneBlock[5] = {0};
            bool boneBlockReadable = _read(
                pawn + GameOffsets::PlayerSpineBone,
                boneBlock, sizeof(boneBlock));
            if (boneBlockReadable) {
                track->bSpine = getTransNodeFromBlock(boneBlock[0]);
                track->bHeadBone = getTransNodeFromBlock(boneBlock[3]);
                track->bHipsBone = getTransNodeFromBlock(boneBlock[4]);
            } else {
                track->bSpine = 0;
                track->bHeadBone = 0;
                track->bHipsBone = 0;
            }
            if (nodeBlockReadable && boneBlockReadable) {
                track->bonesLastFrame = _frameIndex;
            }
        }

        if (wantsSkeleton) {
            pData.bHead      = track->bHead;
            pData.bHipsNode  = track->bHipsNode;
            pData.bLAnkle    = track->bLAnkle;
            pData.bRAnkle    = track->bRAnkle;
            pData.bLShoulder = track->bLShoulder;
            pData.bRShoulder = track->bRShoulder;
            pData.bRHand     = track->bRHand;
            pData.bLHand     = track->bLHand;
            pData.bRElbow    = track->bRElbow;
            pData.bLElbow    = track->bLElbow;
            pData.bSpine     = track->bSpine;
            pData.bHeadBone  = track->bHeadBone;
            pData.bHipsBone  = track->bHipsBone;
        }

        // Camera projection sample
        CameraProjectionSample sample = {head, toe, dist};
        pData.projectionSample = sample;

        [snapshot.players addObject:pData];
        snapshot.enemyCount++;
    }

    // Absence from the authoritative player dictionary ends spatial
    // continuity immediately. Keep the slot/metadata for cheap reuse, but
    // force a returning pawn through fresh visibility and geometry admission.
    for (NSUInteger ti = 0; ti < kEntityTrackCapacity; ti++) {
        ESPEntityTrack *track = &_entityTracks[ti];
        if (track->pawn != 0 &&
            !ContainsAddress(seenPawns, seenPawnCount, track->pawn)) {
            InvalidateTrackSpatialState(track);
        }
    }

    // Keep the scalar count derived from the owning collection so downstream
    // fixed buffers can never observe a count larger than the snapshot array.
    snapshot.enemyCount = (int)MIN(snapshot.players.count,
                                   (NSUInteger)kMaxTrackedPlayers);

    if ((_frameIndex % 120) == 0) {
        for (NSUInteger i = 0; i < kEntityTrackCapacity; i++) {
            ESPEntityTrack *track = &_entityTracks[i];
            if (track->pawn != 0 &&
                _frameIndex > track->lastFrame &&
                (_frameIndex - track->lastFrame) > 90) {
                *track = ESPEntityTrack();
            }
        }
    }

    if (snapshot.enemyCount == 0) {
        if (visibilityRejectedCount > 0) {
            snapshot.statusMessage = [NSString stringWithFormat:
                GX_SECURE_NS("Waiting for player positions [VIS A50 R%lu/U%lu V0x%X I%u M%d]"),
                (unsigned long)visibilityRejectedCount,
                (unsigned long)visibilityUnknownCount,
                visibilitySampleValue,
                visibilitySampleInitial,
                visibilitySampleMode];
        } else {
            snapshot.statusMessage = GX_SECURE_NS("Waiting for player positions");
        }
        snapshot.isValid = YES; // Pointer chain valid, just no enemies
        return snapshot;
    }

    snapshot.isValid = YES;
    snapshot.statusMessage = GX_SECURE_NS("ESP Active");
    return snapshot;
    }
}

@end
