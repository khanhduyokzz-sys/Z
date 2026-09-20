#import "esp.h"
#import "ESPDataCollector.h"
#import "../Core/UnityMath.h"
#import "../Core/GameOffsets.h"
#import "../Core/MemoryUtils.h"
#import "../Core/AimAssistEngine.h"

#include <cmath>
#include <cstring>

// Screen-space box stabiliser keyed by pawn address. Small pose jitter is
// filtered heavily while the position/height still respond immediately when
// the camera pans or an enemy sprints across the screen.
static const NSInteger kProjectedTrackCapacity = ESP_MAX_DRAW_PLAYERS * 2;
static const uint64_t kProjectedBoxGraceFrames = 2;

typedef struct {
    uint64_t pawn;
    CGRect box;
    uint64_t lastFrame;
} ProjectedBoxTrack;

static ProjectedBoxTrack *FindProjectedBoxTrack(
    ProjectedBoxTrack *tracks, NSInteger capacity, uint64_t pawn,
    BOOL createIfMissing) {
    if (tracks == nullptr || capacity <= 0 || pawn == 0) return nullptr;

    ProjectedBoxTrack *empty = nullptr;
    ProjectedBoxTrack *oldest = &tracks[0];
    for (NSInteger index = 0; index < capacity; index++) {
        ProjectedBoxTrack *track = &tracks[index];
        if (track->pawn == pawn) return track;
        if (track->pawn == 0 && empty == nullptr) empty = track;
        if (track->lastFrame < oldest->lastFrame) oldest = track;
    }
    if (!createIfMissing) return nullptr;

    ProjectedBoxTrack *slot = empty != nullptr ? empty : oldest;
    *slot = {};
    slot->pawn = pawn;
    return slot;
}

static CGRect StabilizeProjectedBox(ProjectedBoxTrack *tracks,
                                    NSInteger capacity,
                                    uint64_t pawn,
                                    CGRect target,
                                    CGFloat distance,
                                    CGSize canvasSize,
                                    uint64_t frameIndex) {
    ProjectedBoxTrack *track = FindProjectedBoxTrack(tracks, capacity, pawn, YES);
    if (track == nullptr) return target;

    BOOL hasHistory = track->lastFrame > 0 &&
        frameIndex > track->lastFrame &&
        frameIndex - track->lastFrame <= kProjectedBoxGraceFrames + 1 &&
        !CGRectIsNull(track->box) && !CGRectIsInfinite(track->box) &&
        CGRectGetWidth(track->box) > 0.0f &&
        CGRectGetHeight(track->box) > 0.0f;

    CGRect result = target;
    if (hasHistory) {
        CGFloat prevCenterX = CGRectGetMidX(track->box);
        CGFloat prevBottomY = CGRectGetMaxY(track->box);
        CGFloat prevHeight = CGRectGetHeight(track->box);
        CGFloat targetCenterX = CGRectGetMidX(target);
        CGFloat targetBottomY = CGRectGetMaxY(target);
        CGFloat targetHeight = CGRectGetHeight(target);
        CGFloat positionDelta = hypot(targetCenterX - prevCenterX,
                                      targetBottomY - prevBottomY);
        CGFloat heightDelta = fabs(targetHeight - prevHeight) /
            MAX(prevHeight, 1.0f);

        BOOL discontinuity = positionDelta >
                MAX(canvasSize.width, canvasSize.height) * 0.32f ||
            heightDelta > 0.55f;
        if (!discontinuity) {
            CGFloat baseAlpha = distance < 25.0f
                ? 0.16f : (distance < 60.0f ? 0.22f : 0.30f);
            CGFloat sizeAlpha = MIN(0.82f, baseAlpha +
                MIN(heightDelta / 0.25f, 1.0f) * 0.52f);
            CGFloat centerX = targetCenterX;
            CGFloat bottomY = targetBottomY;
            if (positionDelta <= 1.0f) {
                centerX = prevCenterX;
                bottomY = prevBottomY;
            } else if (positionDelta <= 12.0f) {
                CGFloat posAlpha = 0.55f + (positionDelta / 12.0f) * 0.35f;
                centerX = prevCenterX + (targetCenterX - prevCenterX) * posAlpha;
                bottomY = prevBottomY + (targetBottomY - prevBottomY) * posAlpha;
            }
            CGFloat targetWidth = CGRectGetWidth(target);
            CGFloat prevWidth = CGRectGetWidth(track->box);
            CGFloat height = prevHeight + (targetHeight - prevHeight) * sizeAlpha;
            CGFloat width = prevWidth + (targetWidth - prevWidth) * sizeAlpha;
            result = CGRectMake(centerX - width * 0.5f,
                                bottomY - height, width, height);
        }
    }

    track->box = result;
    track->lastFrame = frameIndex;
    return result;
}

@interface ESPFrameBuilder () {
    ESPDataCollector *_collector;
    ProjectedBoxTrack _projectedBoxTracks[kProjectedTrackCapacity];
    uint64_t _projectionFrameIndex;
    uint64_t _projectedTrackMatch;
    uint64_t _projectedTrackCameraSource;
    uint64_t _projectedTrackNativeCameraSource;
    uint64_t _projectedTrackNativeOffset;
    CameraMatrixLayout _projectedTrackLayout;
    BOOL _hasProjectedTrackIdentity;
    uint32_t _sequence;
    AimAssistEngine *_aimEngine;
}
@end

@implementation ESPFrameBuilder

- (instancetype)init {
    self = [super init];
    if (self) {
        _collector = [[ESPDataCollector alloc] init];
        _collector.collectNames = YES;
        _collector.collectSkeleton = NO;
        _aimEngine = [[AimAssistEngine alloc] init];
        memset(_projectedBoxTracks, 0, sizeof(_projectedBoxTracks));
        _projectionFrameIndex = 0;
        _hasProjectedTrackIdentity = NO;
        _sequence = 0;
    }
    return self;
}

- (void)reset {
    memset(_projectedBoxTracks, 0, sizeof(_projectedBoxTracks));
    _projectionFrameIndex = 0;
    _projectedTrackMatch = 0;
    _projectedTrackCameraSource = 0;
    _projectedTrackNativeCameraSource = 0;
    _projectedTrackNativeOffset = 0;
    _hasProjectedTrackIdentity = NO;
    [_aimEngine reset];
}

- (BOOL)buildDrawPacket:(ESPDrawPacket *)packet
             screenWidth:(float)screenWidth
            screenHeight:(float)screenHeight {
    if (!packet) return NO;
    memset(packet, 0, sizeof(*packet));
    packet->magic = ESP_DRAW_MAGIC;
    packet->sequence = ++_sequence;
    packet->showBoxes = 1;
    packet->showLines = 1;
    packet->showHealth = 1;
    packet->showNames = 1;
    packet->showDistance = 1;
    packet->showPlayerCount = 1;

    if (!(screenWidth > 1.0f) || !(screenHeight > 1.0f)) return NO;

    CGSize overlaySize = CGSizeMake(screenWidth, screenHeight);
    ESPFrameSnapshot *snapshot = [_collector collectFrame:overlaySize];
    if (!snapshot.isValid) return NO;
    if (snapshot.enemyCount == 0 || snapshot.players.count == 0) {
        // Keep the FOV circle visible while in match even with no tracked
        // enemies — the aim pass needs a projection, but the circle itself
        // only depends on the preference mirror.
        [_aimEngine syncPreferences];
        packet->count = 0;
        packet->showFov = [_aimEngine isFovVisible] ? 1 : 0;
        packet->fovRadius = [_aimEngine fovRadius];
        packet->aimHasTarget = 0;
        return YES;
    }

    NSInteger playerCount = MIN((NSInteger)snapshot.players.count,
                                (NSInteger)ESP_MAX_DRAW_PLAYERS);
    CameraProjectionSample samples[ESP_MAX_DRAW_PLAYERS];
    for (NSInteger i = 0; i < playerCount; i++) {
        ESPPlayerData *p = snapshot.players[i];
        samples[i] = p.projectionSample;
    }

    uint64_t altCamera = 0;
    if (isValidPtr(snapshot.cameraManager)) {
        altCamera = ReadAddr<uint64_t>(snapshot.cameraManager +
                                       GameOffsets::CameraControllerManagerAltCamera);
    }

    CameraProjection projection = {};
    if (!FindCameraProjection(snapshot.camera, altCamera,
                              snapshot.localPosition,
                              snapshot.viewRotation,
                              snapshot.hasViewRotation,
                              snapshot.match,
                              samples, (size_t)playerCount,
                              screenWidth, screenHeight,
                              &projection)) {
        return NO;
    }
    if (!isfinite(projection.score) || projection.score < 0.0f) return NO;

    BOOL identityChanged = !_hasProjectedTrackIdentity ||
        _projectedTrackCameraSource != projection.cameraSource ||
        _projectedTrackNativeCameraSource != projection.nativeCameraSource ||
        _projectedTrackNativeOffset != projection.nativeOffset ||
        _projectedTrackLayout != projection.layout;
    if (_projectedTrackMatch != snapshot.match || identityChanged) {
        memset(_projectedBoxTracks, 0, sizeof(_projectedBoxTracks));
        _projectedTrackMatch = snapshot.match;
        _projectedTrackCameraSource = projection.cameraSource;
        _projectedTrackNativeCameraSource = projection.nativeCameraSource;
        _projectedTrackNativeOffset = projection.nativeOffset;
        _projectedTrackLayout = projection.layout;
        _hasProjectedTrackIdentity = YES;
        _projectionFrameIndex = 0;
    }
    if (++_projectionFrameIndex == 0) {
        memset(_projectedBoxTracks, 0, sizeof(_projectedBoxTracks));
        _projectionFrameIndex = 1;
    }

    const float *matrix = projection.matrix;
    CameraMatrixLayout matrixLayout = projection.layout;

    // Aim pass runs while the projection is hot: the engine reuses the same
    // snapshot + calibrated matrix that the ESP entries use below, selects
    // the target inside the aim FOV, and issues the kernel-steered writes.
    [_aimEngine syncPreferences];
    AimAssistOutcome aim = [_aimEngine processSnapshot:snapshot
                                            projection:&projection
                                           screenWidth:screenWidth
                                          screenHeight:screenHeight];
    packet->showFov = aim.active && aim.showFov ? 1 : 0;
    packet->fovRadius = aim.fovRadius;
    packet->aimHasTarget = (aim.hasTarget && aim.showLine) ? 1 : 0;
    packet->aimTargetPoint = aim.targetPoint;

    uint32_t drawCount = 0;
    for (NSInteger i = 0; i < playerCount && drawCount < ESP_MAX_DRAW_PLAYERS; i++) {
        ESPPlayerData *p = snapshot.players[i];
        if (p.pawn == 0 || p.isKnocked) continue;

        Vector3 w2sHead = WorldToScreen(p.headWorld, matrix, matrixLayout,
                                        screenWidth, screenHeight);
        Vector3 w2sToe = WorldToScreen(p.toeWorld, matrix, matrixLayout,
                                       screenWidth, screenHeight);
        BOOL headInFront = isfinite(w2sHead.x) && isfinite(w2sHead.y) &&
                           isfinite(w2sHead.z) && w2sHead.z > 0.01f;
        BOOL toeInFront = isfinite(w2sToe.x) && isfinite(w2sToe.y) &&
                          isfinite(w2sToe.z) && w2sToe.z > 0.01f;
        if (!headInFront || !toeInFront) continue;

        float dx = w2sToe.x - w2sHead.x;
        float dy = w2sToe.y - w2sHead.y;
        float bodySpan = hypotf(dx, dy);
        float minSpan = p.distance > 120.0f ? 1.25f
                        : (p.distance > 60.0f ? 2.0f
                                              : fmaxf(3.0f, screenHeight * 0.006f));

        float rawX = 0.0f, rawY = 0.0f, rawWidth = 0.0f, rawHeight = 0.0f;
        BOOL isUpright = (dy >= minSpan && fabsf(dx) <= fmaxf(16.0f, dy * 0.75f));

        if (isUpright) {
            rawHeight = dy;
            rawWidth = rawHeight * 0.5f;
            rawX = (w2sHead.x + w2sToe.x) * 0.5f - rawWidth * 0.5f;
            rawY = w2sHead.y;
        } else {
            // Adaptive box for aerial drops, parachuting, diving, and crawling.
            float paddingX = fmaxf(bodySpan * 0.22f, 4.0f);
            float paddingY = fmaxf(bodySpan * 0.15f, 3.0f);
            float minX = fminf(w2sHead.x, w2sToe.x) - paddingX;
            float maxX = fmaxf(w2sHead.x, w2sToe.x) + paddingX;
            float minY = fminf(w2sHead.y, w2sToe.y) - paddingY;
            float maxY = fmaxf(w2sHead.y, w2sToe.y) + paddingY;
            rawWidth = maxX - minX;
            rawHeight = maxY - minY;
            rawX = minX;
            rawY = minY;
        }

        float perspectiveScale = (bodySpan / screenHeight) * p.distance;
        BOOL geometryValid =
            isfinite(rawHeight) && isfinite(rawWidth) &&
            bodySpan >= minSpan &&
            rawWidth >= 0.6f && rawHeight >= 0.6f &&
            rawHeight <= screenHeight * 2.0f &&
            rawWidth <= screenWidth * 2.0f &&
            isfinite(perspectiveScale) && perspectiveScale >= 0.06f &&
            perspectiveScale <= 6.8f;
        if (!geometryValid) continue;

        CGRect stableBox = StabilizeProjectedBox(
            _projectedBoxTracks, kProjectedTrackCapacity, p.pawn,
            CGRectMake(rawX, rawY, rawWidth, rawHeight),
            p.distance, overlaySize, _projectionFrameIndex);

        float x = CGRectGetMinX(stableBox);
        float y = CGRectGetMinY(stableBox);
        float boxWidth = CGRectGetWidth(stableBox);
        float boxHeight = CGRectGetHeight(stableBox);

        if (x + boxWidth < -30.0f || x > screenWidth + 30.0f ||
            y + boxHeight < -30.0f || y > screenHeight + 30.0f) {
            continue;
        }

        ESPPlayerDrawEntry *entry = &packet->players[drawCount];
        entry->valid = 1;
        entry->isEnemy = 1;
        entry->isVisible = 1;
        entry->hasBones = 0;
        entry->pawn = p.pawn;
        entry->box = CGRectMake(x, y, boxWidth, boxHeight);
        entry->headPos = CGPointMake(w2sHead.x, w2sHead.y);
        entry->leftToePos = CGPointMake(w2sToe.x, w2sToe.y);

        int curHp = p.currentHP;
        int maxHp = p.maxHP > 0 ? p.maxHP : 200;
        if (curHp < 0) curHp = 0;
        if (curHp > maxHp) curHp = maxHp;
        entry->currentHP = curHp;
        entry->maximumHP = maxHp;
        entry->hpPercent = maxHp > 0 ? (float)curHp / (float)maxHp : 0.0f;
        entry->distanceMeters = p.distance;

        NSString *name = p.name;
        if (name.length == 0) {
            name = [NSString stringWithFormat:@"Enemy_%ld", (long)(i + 1)];
        }
        const char *utf8 = name.UTF8String ?: "";
        strncpy(entry->name, utf8, sizeof(entry->name) - 1);
        entry->name[sizeof(entry->name) - 1] = '\0';

        drawCount++;
    }

    packet->count = drawCount;
    return YES;
}

@end
