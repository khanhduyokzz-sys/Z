#import "UnityMath.h"
#include <cfloat>
#include <cstring>
#include <math.h>

#pragma mark - Player Info Layout (screen-space geometry helpers)

extern "C" {

bool unity_math_info_layout(double x, double y, double width, double height,
                            int32_t hp, int32_t maxHP,
                            UnityPlayerInfoLayout *out) {
    if (!out || !isfinite(x) || !isfinite(y) || !isfinite(width) ||
        !isfinite(height) || fmin(width, height) <= 0.0) return false;
    double ratio = maxHP > 0 ? (double)hp / (double)(uint32_t)maxHP : 0.0;
    if (ratio < 0.0) ratio = 0.0;
    if (ratio > 1.0) ratio = 1.0;
    double left = (x + width * 0.5) - 37.5;
    double top = (y - 40.0) + 2.0;
    double center = left + 37.5;
    out->panel = (UnityScreenRect){left, top + 10.0, 75.0, 22.0};
    out->nameBackground = (UnityScreenRect){left, top + 10.0, 75.0, 15.0};
    out->healthFill = (UnityScreenRect){left, top + 25.0, ratio * 75.0, 2.0};
    out->name = (UnityScreenRect){left + 12.5, (top + 10.0) + 2.0, 50.0, 12.0};
    out->triangle[0] = (UnityScreenPoint){center - 5.0, top + 27.0};
    out->triangle[1] = (UnityScreenPoint){center, (top + 27.0) + 5.0};
    out->triangle[2] = (UnityScreenPoint){center + 5.0, top + 27.0};
    out->distance = (UnityScreenRect){left, (y + height) + 4.0, 75.0, 12.0};
    return true;
}

uint32_t unity_math_info_visibility(bool health, bool name) {
    return (uint32_t)name | ((uint32_t)health << 8) |
           ((uint32_t)name << 16) | ((uint32_t)(health || name) << 24);
}

double unity_math_line_end_offset(bool health, bool name) {
    return name ? 31.0 : (health ? 14.0 : 0.0);
}

} // extern "C"

#pragma mark - Function Unity

Vector3 WorldToScreen(Vector3 obj,
                      const float *matrix,
                      CameraMatrixLayout layout,
                      float screenX,
                      float screenY,
                      bool overlayBehindCamera) {
    Vector3 screen(NAN, NAN, NAN);
    if (!matrix || !isfinite(obj.x) || !isfinite(obj.y) ||
        !isfinite(obj.z) || !isfinite(screenX) || !isfinite(screenY) ||
        screenX <= 1.0f || screenY <= 1.0f) {
        return screen;
    }

    float w = 0.0f;
    float clipX = 0.0f;
    float clipY = 0.0f;
    if (layout == CameraMatrixLayout::ColumnVector) {
        w = matrix[3] * obj.x + matrix[7] * obj.y +
            matrix[11] * obj.z + matrix[15];
        clipX = matrix[0] * obj.x + matrix[4] * obj.y +
                matrix[8] * obj.z + matrix[12];
        clipY = matrix[1] * obj.x + matrix[5] * obj.y +
                matrix[9] * obj.z + matrix[13];
    } else {
        w = matrix[12] * obj.x + matrix[13] * obj.y +
            matrix[14] * obj.z + matrix[15];
        clipX = matrix[0] * obj.x + matrix[1] * obj.y +
                matrix[2] * obj.z + matrix[3];
        clipY = matrix[4] * obj.x + matrix[5] * obj.y +
                matrix[6] * obj.z + matrix[7];
    }

    if (!isfinite(w) || (!overlayBehindCamera && w <= 0.01f)) return screen;
    // Rear overlay convention preserves camera-space left/right and up/down.
    // Keep signed depth; only the overlay opts into this projection.
    float divisor = overlayBehindCamera ? fmaxf(fabsf(w), 0.01f) : w;

    float x = (screenX * 0.5f) + (clipX / divisor) * (screenX * 0.5f);
    float y = (screenY * 0.5f) - (clipY / divisor) * (screenY * 0.5f);
    if (!isfinite(x) || !isfinite(y)) return screen;
    screen.x = x;
    screen.y = y;
    screen.z = w;
    return screen;
}

static bool IsFiniteProjectionMatrix(const float *matrix) {
    float magnitude = 0.0f;
    int nonZeroValues = 0;
    for (int index = 0; index < 16; index++) {
        float value = matrix[index];
        if (!isfinite(value) || fabsf(value) > 10000000.0f) return false;
        magnitude += fabsf(value);
        if (fabsf(value) > 0.00001f) nonZeroValues++;
    }
    return magnitude > 0.01f && nonZeroValues >= 6;
}

static bool IsPerspectiveProjectionMatrix(const float *matrix,
                                          CameraMatrixLayout layout) {
    if (!IsFiniteProjectionMatrix(matrix)) return false;

    // In Unity's composed perspective matrix, the XYZ coefficients that
    // produce clip-space depth and homogeneous W are nearly equal. Camera
    // translation only changes their fourth terms. bug.txt confirms this for
    // the real M+0x100/C matrix across all camera rotations, while the false
    // 0x330/0x2E0/0x2F4 selections are identity/view fragments or zero rows.
    float depthX = 0.0f;
    float depthY = 0.0f;
    float depthZ = 0.0f;
    float wX = 0.0f;
    float wY = 0.0f;
    float wZ = 0.0f;
    if (layout == CameraMatrixLayout::ColumnVector) {
        depthX = matrix[2];
        depthY = matrix[6];
        depthZ = matrix[10];
        wX = matrix[3];
        wY = matrix[7];
        wZ = matrix[11];
    } else {
        depthX = matrix[8];
        depthY = matrix[9];
        depthZ = matrix[10];
        wX = matrix[12];
        wY = matrix[13];
        wZ = matrix[14];
    }

    float depthNorm = sqrtf(depthX * depthX + depthY * depthY +
                            depthZ * depthZ);
    float wNorm = sqrtf(wX * wX + wY * wY + wZ * wZ);
    if (!isfinite(depthNorm) || !isfinite(wNorm) ||
        depthNorm < 0.70f || depthNorm > 1.30f ||
        wNorm < 0.70f || wNorm > 1.30f) {
        return false;
    }

    float diffX = depthX - wX;
    float diffY = depthY - wY;
    float diffZ = depthZ - wZ;
    float relativeDifference =
        sqrtf(diffX * diffX + diffY * diffY + diffZ * diffZ) /
        fmaxf(depthNorm, wNorm);
    float directionDot = depthX * wX + depthY * wY + depthZ * wZ;
    return isfinite(relativeDifference) && relativeDifference <= 0.05f &&
           directionDot > 0.0f;
}

static bool IsPointInsideExtendedCanvas(Vector3 point,
                                        float screenX,
                                        float screenY) {
    return isfinite(point.x) && isfinite(point.y) && isfinite(point.z) &&
           point.z > 0.01f && point.x >= -screenX &&
           point.x <= screenX * 2.0f && point.y >= -screenY &&
           point.y <= screenY * 2.0f;
}

static bool IsPointInsideCanvas(Vector3 point,
                                float screenX,
                                float screenY) {
    return point.x >= 0.0f && point.x <= screenX &&
           point.y >= 0.0f && point.y <= screenY;
}

static float ScoreCameraProjection(const float *matrix,
                                   CameraMatrixLayout layout,
                                   const CameraProjectionSample *samples,
                                   size_t sampleCount,
                                   float screenX,
                                   float screenY) {
    if (!IsPerspectiveProjectionMatrix(matrix, layout)) return -FLT_MAX;

    float score = 0.0f;
    float minX = FLT_MAX;
    float maxX = -FLT_MAX;
    float minY = FLT_MAX;
    float maxY = -FLT_MAX;
    float largestBodyHeight = 0.0f;
    size_t validPairs = 0;
    size_t uprightPairs = 0;
    size_t distortedPairs = 0;
    size_t onCanvasHeads = 0;

    for (size_t index = 0; index < sampleCount; index++) {
        Vector3 head = WorldToScreen(samples[index].head, matrix, layout,
                                     screenX, screenY);
        Vector3 toe = WorldToScreen(samples[index].toe, matrix, layout,
                                    screenX, screenY);
        if (!IsPointInsideExtendedCanvas(head, screenX, screenY) ||
            !IsPointInsideExtendedCanvas(toe, screenX, screenY)) {
            continue;
        }

        validPairs++;
        bool headOnCanvas = IsPointInsideCanvas(head, screenX, screenY);
        bool toeOnCanvas = IsPointInsideCanvas(toe, screenX, screenY);
        score += (headOnCanvas && toeOnCanvas) ? 8.0f : 1.0f;

        if (headOnCanvas) {
            onCanvasHeads++;
            minX = fminf(minX, head.x);
            maxX = fmaxf(maxX, head.x);
            minY = fminf(minY, head.y);
            maxY = fmaxf(maxY, head.y);
        }

        float dx = toe.x - head.x;
        float dy = toe.y - head.y;
        float bodySpan = sqrtf(dx * dx + dy * dy);
        largestBodyHeight = fmaxf(largestBodyHeight, bodySpan);
        float sampleDistance = samples[index].distance;
        float minimumUsefulHeight = sampleDistance > 120.0f
            ? 1.25f
            : (sampleDistance > 60.0f ? 2.0f
                                      : fmaxf(3.0f, screenY * 0.006f));

        bool isUpright = (dy >= minimumUsefulHeight && dy <= screenY * 1.25f &&
                          fabsf(dx) <= fmaxf(16.0f, dy * 0.85f));
        bool isPlausibleSpan = (bodySpan >= minimumUsefulHeight && bodySpan <= screenY * 1.25f);

        if (isPlausibleSpan) {
            float distance = sampleDistance;
            bool perspectiveValid = false;
            if (isfinite(distance) && distance > 0.5f) {
                float perspectiveScale = (bodySpan / screenY) * distance;
                if (perspectiveScale >= 0.07f && perspectiveScale <= 6.8f) {
                    perspectiveValid = true;
                }
                float depthRatio = head.z / distance;
                if (isfinite(depthRatio) && depthRatio > 0.01f && depthRatio <= 3.0f) {
                    score += 3.0f;
                } else {
                    score -= 8.0f;
                }
            }

            if (isUpright) {
                uprightPairs++;
                score += 12.0f + fminf(dy / screenY, 0.35f) * 20.0f;
                if (perspectiveValid) {
                    score += 8.0f;
                } else {
                    score -= 16.0f;
                }
            } else if (perspectiveValid) {
                // Aerial, parachuting, diving, or crawling targets have non-vertical
                // orientations but valid physical extent in perspective.
                uprightPairs++;
                score += 10.0f + fminf(bodySpan / screenY, 0.35f) * 16.0f;
            } else {
                distortedPairs++;
                score -= 6.0f;
            }
        } else if (bodySpan > 0.0f && bodySpan < minimumUsefulHeight) {
            // Very distant player (150-800m) can legitimately be sub-pixel/few pixels.
            if (sampleDistance <= 60.0f) distortedPairs++;
            score += sampleDistance > 60.0f ? 1.0f : -2.0f;
        } else {
            distortedPairs++;
            score -= 8.0f;
        }

        if (isUpright) {
            float horizontalBoneError = fabsf(dx);
            if (horizontalBoneError <= fmaxf(16.0f, fabsf(dy) * 0.75f)) {
                score += 2.0f;
            } else {
                score -= 2.0f;
            }
        }
    }

    if (validPairs == 0) return -FLT_MAX;
    // Entirely collapsed/inverted visible bodies are distortion, not the
    // neutral no-front-facing-samples case handled above.
    if (uprightPairs == 0) return distortedPairs == validPairs ? -1.0f : 0.0f;

    if (onCanvasHeads >= 2) {
        float spreadX = (maxX - minX) / screenX;
        float spreadY = (maxY - minY) / screenY;
        float spread = fmaxf(spreadX, spreadY);
        score += fminf(spread, 1.0f) * 12.0f;
        if (onCanvasHeads >= 3 && spread < 0.04f &&
            largestBodyHeight < screenY * 0.03f) {
            score -= 30.0f;
        }
    }

    score += static_cast<float>(validPairs) * 0.5f;
    return score;
}

bool FindCameraProjection(uint64_t cameraMain,
                          uint64_t alternateCamera,
                          Vector3 cameraPos,
                          Quaternion viewRotation,
                          bool hasViewRotation,
                          uint64_t matchId,
                          const CameraProjectionSample *samples,
                          size_t sampleCount,
                          float screenX,
                          float screenY,
                          CameraProjection *projection) {
    if (!projection || !samples || sampleCount == 0 ||
        !isValidPtr(cameraMain) ||
        !isfinite(cameraPos.x) || !isfinite(cameraPos.y) ||
        !isfinite(cameraPos.z) ||
        !isfinite(screenX) || !isfinite(screenY) ||
        screenX <= 1.0f || screenY <= 1.0f) {
        return false;
    }

    // Camera's native C++ layout changes between Unity revisions and is not
    // represented by IL2CPP metadata. Scan one bounded object window and score
    // each aligned 4x4 candidate against real head/toe geometry. This includes
    // the former hardcoded +0xD8 location without trusting it blindly.
    constexpr size_t kCameraScanSize = 0x480;
    constexpr size_t kMatrixBytes = sizeof(float) * 16;
    constexpr size_t kFirstMatrixOffset = 0x80;
    constexpr size_t kMatrixAlignment = sizeof(float);
    constexpr size_t kMatrixCandidateCount =
        ((kCameraScanSize - kMatrixBytes - kFirstMatrixOffset) /
         kMatrixAlignment) + 1;
    constexpr size_t kCandidateSlotCount = kMatrixCandidateCount * 2;
    constexpr int kCalibrationFrameCount = 3;
    constexpr int kLockedInvalidFrameLimit = 90;
    // Calibration only ever accepts candidates scoring >= 4.0f, so a score
    // below zero is a strong signal that the locked offset no longer holds
    // the camera matrix (FOV switch, cutscene, camera mode change, or memory
    // overwrite). Prefer missing one frame over drawing a confident-looking
    // false ESP. A real on-screen upright player scores comfortably above it.
    constexpr float kLockedScoreThreshold = 4.0f;
    // Anchor drift: the w-row evaluated at the camera position is a pose
    // fingerprint. The game rewrites a live matrix every frame, so the value
    // stays glued to the lock-time baseline; a stale matrix drifts away as
    // soon as the camera moves. Drift is the fastest reliable staleness
    // signal, so it gets a much shorter grace than geometric distortion.
    constexpr float kAnchorDriftLimit = 1.0f;
    constexpr int kAnchorDriftFrameLimit = 10;
    // Camera arbitration window: frames a chosen camera may fail to produce
    // any verified lock before the other managed Camera gets an equal chance.
    constexpr int kCameraSwitchFrameLimit = 90;

    // --- Static calibration state ---
    static uint64_t stateMatchId = 0;
    static uint64_t stateNativeCamera = 0;
    static bool hasLockedSelection = false;
    static size_t lockedOffset = 0;
    static CameraMatrixLayout lockedLayout =
        CameraMatrixLayout::ColumnVector;
    static int lockedInvalidFrames = 0;
    static int preferredValidFrames = 0;
    static int calibrationFrames = 0;
    static float accumulatedScores[kCandidateSlotCount] = {};
    static uint16_t validScoreFrames[kCandidateSlotCount] = {};
    static float lockedAnchorBaseline = 0.0f;
    static bool hasAnchorBaseline = false;
    static int chosenCameraFailFrames = 0;
    static bool usingAlternateCamera = false;
    static float previousLockedMatrix[16] = {};
    static Quaternion previousViewRotation = Quaternion::Identity();
    static bool hasTemporalSample = false;
    static int frozenMatrixViewMotionFrames = 0;

    auto AnchorResidual = [cameraPos](const float *matrix,
                                      CameraMatrixLayout layout) -> float {
        if (layout == CameraMatrixLayout::ColumnVector) {
            return matrix[3] * cameraPos.x + matrix[7] * cameraPos.y +
                   matrix[11] * cameraPos.z + matrix[15];
        }
        return matrix[12] * cameraPos.x + matrix[13] * cameraPos.y +
               matrix[14] * cameraPos.z + matrix[15];
    };

    auto ResetCalibration = [&]() {
        calibrationFrames = 0;
        memset(accumulatedScores, 0, sizeof(accumulatedScores));
        memset(validScoreFrames, 0, sizeof(validScoreFrames));
    };

    auto DropLock = [&]() {
        hasLockedSelection = false;
        lockedOffset = 0;
        lockedInvalidFrames = 0;
        hasAnchorBaseline = false;
        lockedAnchorBaseline = 0.0f;
        hasTemporalSample = false;
        frozenMatrixViewMotionFrames = 0;
        memset(previousLockedMatrix, 0, sizeof(previousLockedMatrix));
        previousViewRotation = Quaternion::Identity();
        ResetCalibration();
    };

    // A new match must never inherit the previous lock: Unity recycles native
    // object addresses, so a Clash-Squad lock can silently poison a fresh BR
    // session that reuses the same native Camera address.
    if (matchId != stateMatchId) {
        stateMatchId = matchId;
        stateNativeCamera = 0;
        usingAlternateCamera = false;
        chosenCameraFailFrames = 0;
        preferredValidFrames = 0;
        DropLock();
    }

    // Camera arbitration: the primary GameCamera (manager+0x20) is preferred
    // forever. Some BR camera states render through the manager's second
    // Camera (manager+0x28); when the chosen camera cannot produce or keep a
    // verified lock for a full window, give the other managed Camera an equal
    // window instead of staying blind on the wrong object.
    uint64_t chosenManaged = cameraMain;
    if (!isValidPtr(alternateCamera) || alternateCamera == cameraMain) {
        usingAlternateCamera = false;
        chosenCameraFailFrames = 0;
    } else {
        if (chosenCameraFailFrames >= kCameraSwitchFrameLimit) {
            usingAlternateCamera = !usingAlternateCamera;
            chosenCameraFailFrames = 0;
            stateNativeCamera = 0;
            DropLock();
        }
        if (usingAlternateCamera) chosenManaged = alternateCamera;
    }

    uint64_t nativeCamera = 0;
    if (!_read(chosenManaged + GameOffsets::UnityObjectCachedPtr,
               &nativeCamera, sizeof(nativeCamera)) ||
        !isValidPtr(nativeCamera)) {
        chosenCameraFailFrames++;
        return false;
    }

    uint8_t cameraBytes[kCameraScanSize] = {};
    if (!_read(nativeCamera, cameraBytes, sizeof(cameraBytes))) {
        chosenCameraFailFrames++;
        return false;
    }

    size_t scoringSamples = sampleCount < 24 ? sampleCount : 24;

    // Calibrate over multiple frames, then lock one offset/layout for the
    // lifetime of this native Camera. Selecting the per-frame winner caused
    // the ESP to alternate between a correct matrix and nearby finite data.
    if (stateNativeCamera != nativeCamera) {
        stateNativeCamera = nativeCamera;
        preferredValidFrames = 0;
        DropLock();
    }

    if (hasLockedSelection &&
        lockedOffset >= kFirstMatrixOffset &&
        lockedOffset + kMatrixBytes <= kCameraScanSize) {
        CameraProjection locked = {};
        memcpy(locked.matrix, cameraBytes + lockedOffset,
               sizeof(locked.matrix));

        bool structurallyValid =
            IsPerspectiveProjectionMatrix(locked.matrix, lockedLayout);
        float lockedScore = -FLT_MAX;
        float anchor = 0.0f;
        bool anchorDrifted = false;
        if (structurallyValid) {
            lockedScore = ScoreCameraProjection(
                locked.matrix, lockedLayout, samples, scoringSamples,
                screenX, screenY);
            anchor = AnchorResidual(locked.matrix, lockedLayout);
            anchorDrifted = hasAnchorBaseline &&
                fabsf(anchor - lockedAnchorBaseline) > kAnchorDriftLimit;
        }

        if (structurallyValid) {
            // A finite perspective matrix may belong to a camera buffer that
            // the game no longer updates. Compare frame-to-frame motion rather
            // than absolute camera angles: if view rotation moves but every
            // matrix element remains frozen, suppress the stale projection.
            if (hasViewRotation) {
                if (hasTemporalSample) {
                    float matrixDelta = 0.0f;
                    for (int matrixIndex = 0; matrixIndex < 16; matrixIndex++) {
                        matrixDelta = fmaxf(
                            matrixDelta,
                            fabsf(locked.matrix[matrixIndex] -
                                  previousLockedMatrix[matrixIndex]));
                    }
                    float rotationDot = fabsf(Quaternion::Dot(
                        previousViewRotation, viewRotation));
                    rotationDot = fmaxf(0.0f, fminf(1.0f, rotationDot));
                    float viewDeltaDegrees = 2.0f * acosf(rotationDot) *
                        (180.0f / 3.14159265f);
                    if (viewDeltaDegrees >= 0.35f &&
                        matrixDelta < 0.00001f) {
                        frozenMatrixViewMotionFrames++;
                    } else {
                        frozenMatrixViewMotionFrames = 0;
                    }
                }
                memcpy(previousLockedMatrix, locked.matrix,
                       sizeof(previousLockedMatrix));
                previousViewRotation = viewRotation;
                hasTemporalSample = true;
            } else {
                hasTemporalSample = false;
                frozenMatrixViewMotionFrames = 0;
            }

            if (frozenMatrixViewMotionFrames >= 2) {
                DropLock();
                chosenCameraFailFrames++;
                return false;
            }

            locked.layout = lockedLayout;
            locked.nativeOffset = lockedOffset;
            locked.anchorResidual = anchor;
            locked.cameraSource = chosenManaged;
            locked.nativeCameraSource = nativeCamera;

            if (anchorDrifted) {
                // Drift dominates every other signal: the game stopped
                // writing this matrix (camera mode switch, recycled object),
                // so whatever it projects is stale. Short grace only.
                lockedInvalidFrames++;
                if (lockedInvalidFrames >= kAnchorDriftFrameLimit) {
                    DropLock();
                    return false;
                }
                // Keep selection during grace, but never publish a stale matrix.
                return false;
            } else if (isfinite(lockedScore) &&
                       lockedScore >= kLockedScoreThreshold) {
                // High confidence projection on active enemies. Geometric
                // proof re-affirms the anchor baseline so a legitimately
                // re-verified matrix self-heals instead of drifting out.
                lockedInvalidFrames = 0;
                chosenCameraFailFrames = 0;
                if (hasAnchorBaseline) lockedAnchorBaseline = anchor;
                locked.score = lockedScore;
                locked.lockScore = lockedScore;
            } else if (lockedScore == -FLT_MAX) {
                // Enemies are off-screen or behind camera.
                // The camera matrix is live and verified by anchor residual.
                // Never drop lock simply because enemies are behind the camera.
                locked.score = 0.0f;
                locked.lockScore = 0.0f;
            } else if (isfinite(lockedScore) && lockedScore >= 0.0f) {
                // Neutral / partial visibility
                locked.score = lockedScore;
                locked.lockScore = lockedScore;
            } else {
                // Active distortion: negative geometric score on visible
                // enemies. Keep the longer BR transition grace before
                // recalibrating.
                lockedInvalidFrames++;
                if (lockedInvalidFrames >= kLockedInvalidFrameLimit) {
                    DropLock();
                    return false;
                }
                // If the anchor residual is still glued to baseline, the matrix is
                // live in game memory. Allow a short 4-frame grace before suppressing visuals.
                if (!anchorDrifted && lockedInvalidFrames <= 4) {
                    locked.score = 0.0f;
                    locked.lockScore = 0.0f;
                    *projection = locked;
                    return true;
                }
                // Keep the lock for recovery, suppress distorted frames.
                return false;
            }

            *projection = locked;
            return true;
        }

        // Structural invalidity (camera destroyed or memory corrupted on match exit):
        chosenCameraFailFrames++;
        lockedInvalidFrames++;
        if (lockedInvalidFrames < kLockedInvalidFrameLimit) return false;
        DropLock();
    }

    // OB54's composed camera matrix is consistently nativeCamera+0x100 in the
    // captured builds. The shortcut only accepts an offset that PROVES itself
    // geometrically on real head/toe samples for two consecutive frames — a
    // structurally-perspective-but-wrong matrix used to lock here blindly
    // (even with zero valid samples) and then drew confident ESP into empty
    // space for the rest of the match.
    constexpr size_t kPreferredMatrixOffset = 0x100;
    if (kPreferredMatrixOffset + kMatrixBytes <= kCameraScanSize) {
        CameraProjection preferred = {};
        memcpy(preferred.matrix, cameraBytes + kPreferredMatrixOffset,
               sizeof(preferred.matrix));
        preferred.layout = CameraMatrixLayout::ColumnVector;
        preferred.nativeOffset = kPreferredMatrixOffset;
        bool structurallyValid = IsPerspectiveProjectionMatrix(
            preferred.matrix, preferred.layout);
        float preferredScore = structurallyValid
            ? ScoreCameraProjection(preferred.matrix, preferred.layout,
                                    samples, scoringSamples,
                                    screenX, screenY)
            : -FLT_MAX;
        if (structurallyValid && isfinite(preferredScore) &&
            preferredScore >= kLockedScoreThreshold) {
            preferredValidFrames++;
        } else {
            preferredValidFrames = 0;
        }
        if (preferredValidFrames >= 2) {
            hasLockedSelection = true;
            lockedOffset = kPreferredMatrixOffset;
            lockedLayout = CameraMatrixLayout::ColumnVector;
            lockedInvalidFrames = 0;
            lockedAnchorBaseline =
                AnchorResidual(preferred.matrix, preferred.layout);
            hasAnchorBaseline = true;
            preferred.anchorResidual = lockedAnchorBaseline;
            preferred.cameraSource = chosenManaged;
            preferred.nativeCameraSource = nativeCamera;
            preferred.score = preferredScore;
            preferred.lockScore = preferredScore;
            chosenCameraFailFrames = 0;
            *projection = preferred;
            return true;
        }
    }

    for (size_t offset = kFirstMatrixOffset;
         offset + kMatrixBytes <= kCameraScanSize;
         offset += kMatrixAlignment) {
        float candidate[16] = {};
        memcpy(candidate, cameraBytes + offset, sizeof(candidate));
        if (!IsFiniteProjectionMatrix(candidate)) continue;

        CameraMatrixLayout layouts[] = {
            CameraMatrixLayout::ColumnVector,
            CameraMatrixLayout::RowVector,
        };
        for (CameraMatrixLayout layout : layouts) {
            float score = ScoreCameraProjection(candidate, layout, samples,
                                                scoringSamples,
                                                screenX, screenY);
            if (isfinite(score) && score >= 4.0f) {
                if (offset == 0x100 || offset == 0xD8 || offset == 0xDC ||
                    offset == 0x1B0 || offset == 0x1C0 || offset == 0x200 ||
                    offset == 0x280 || offset == 0x2C0 || offset == 0x300) {
                    score += 10.0f;
                }
                size_t candidateIndex =
                    (offset - kFirstMatrixOffset) / kMatrixAlignment;
                size_t layoutIndex =
                    layout == CameraMatrixLayout::ColumnVector ? 0 : 1;
                size_t slot = candidateIndex * 2 + layoutIndex;
                accumulatedScores[slot] += score;
                validScoreFrames[slot]++;
            }
        }
    }

    calibrationFrames++;
    if (calibrationFrames < kCalibrationFrameCount) {
        // Return valid instant projection if available while calibrating
        for (size_t offset = kFirstMatrixOffset; offset + kMatrixBytes <= kCameraScanSize; offset += kMatrixAlignment) {
            float cand[16] = {};
            memcpy(cand, cameraBytes + offset, sizeof(cand));
            if (!IsPerspectiveProjectionMatrix(cand, CameraMatrixLayout::ColumnVector)) continue;
            float sc = ScoreCameraProjection(cand, CameraMatrixLayout::ColumnVector, samples, scoringSamples, screenX, screenY);
            if (isfinite(sc) && sc >= 4.0f) {
                memcpy(projection->matrix, cand, sizeof(projection->matrix));
                projection->layout = CameraMatrixLayout::ColumnVector;
                projection->nativeOffset = offset;
                projection->score = sc;
                projection->lockScore = sc;
                projection->cameraSource = chosenManaged;
                projection->nativeCameraSource = nativeCamera;
                return true;
            }
        }
        chosenCameraFailFrames++;
        return false;
    }

    size_t winningSlot = kCandidateSlotCount;
    float winningAverage = -FLT_MAX;
    uint16_t minimumValidFrames = 1;
    for (size_t slot = 0; slot < kCandidateSlotCount; slot++) {
        if (validScoreFrames[slot] < minimumValidFrames) continue;
        float average = accumulatedScores[slot] /
                        static_cast<float>(kCalibrationFrameCount);
        if (average > winningAverage) {
            winningAverage = average;
            winningSlot = slot;
        }
    }

    if (winningSlot == kCandidateSlotCount ||
        !isfinite(winningAverage) || winningAverage < 4.0f) {
        ResetCalibration();
        chosenCameraFailFrames++;
        return false;
    }

    size_t winningCandidate = winningSlot / 2;
    lockedOffset = kFirstMatrixOffset +
                   winningCandidate * kMatrixAlignment;
    lockedLayout = (winningSlot % 2) == 0
        ? CameraMatrixLayout::ColumnVector
        : CameraMatrixLayout::RowVector;
    hasLockedSelection = true;
    lockedInvalidFrames = 0;

    CameraProjection locked = {};
    memcpy(locked.matrix, cameraBytes + lockedOffset,
           sizeof(locked.matrix));
    locked.layout = lockedLayout;
    locked.nativeOffset = lockedOffset;
    locked.cameraSource = chosenManaged;
    locked.nativeCameraSource = nativeCamera;
    locked.score = ScoreCameraProjection(
        locked.matrix, locked.layout, samples, scoringSamples,
        screenX, screenY);
    locked.lockScore = locked.score;
    if (!isfinite(locked.score) || locked.score < kLockedScoreThreshold) {
        // Fresh lock must prove itself on this very frame; otherwise return
        // no projection and let the locked path start counting invalid frames.
        chosenCameraFailFrames++;
        return false;
    }
    lockedAnchorBaseline = AnchorResidual(locked.matrix, lockedLayout);
    hasAnchorBaseline = true;
    locked.anchorResidual = lockedAnchorBaseline;
    chosenCameraFailFrames = 0;
    *projection = locked;
    return true;
}

// Native Unity Transform hierarchy layout (not emitted by IL2CPP metadata).
// Applies transform hierarchy calculations with rotation, scale, position

// --- Per-frame read caches -------------------------------------------------
// Every bone of one character walks the SAME ancestor chain; without caching
// a 12-bone skeleton re-reads the identical ancestor TMatices ~120 times per
// player per frame (~600+ Mach traps). Both caches are tagged with a frame
// counter bumped once per collection pass; entries older than the current
// frame are treated as invalid. All reads now run on the display-link thread.

static const size_t kGXMatrixCacheSize = 128;
static const size_t kGXParentSnapshotSize = 256;
static const size_t kGXParentSnapshotSlots = 4;

struct GXMatrixCacheEntry {
    uint64_t addr;
    TMatrix matrix;
    uint32_t frame;
};
static GXMatrixCacheEntry s_gxMatrixCache[kGXMatrixCacheSize];

struct GXParentSnapshotEntry {
    uint64_t base;
    uint32_t frame;
    uint32_t count;
    int32_t snapshot[kGXParentSnapshotSize];
};
static GXParentSnapshotEntry s_gxParentSnapshots[kGXParentSnapshotSlots] = {};
static uint32_t s_gxFrameTag = 0;

void GXBeginTransformReadFrame(void) {
    if (++s_gxFrameTag == 0) {
        memset(s_gxMatrixCache, 0, sizeof(s_gxMatrixCache));
        memset(s_gxParentSnapshots, 0, sizeof(s_gxParentSnapshots));
        s_gxFrameTag = 1;
    }
}

static inline size_t GXMatrixCacheHash(uint64_t addr) {
    // 64-bit Fibonacci hash with golden ratio constant: 2^64 / phi
    // Solves stride collisions from 48-byte TMatrix alignment, ensuring 100% of slots are reachable.
    uint64_t h = (addr >> 4) * 11400714819323198485ull;
    return (size_t)((h ^ (h >> 32)) & (kGXMatrixCacheSize - 1));
}

static bool GXCacheReadTMatrix(uint64_t addr, TMatrix *out) {
    uint32_t frame = s_gxFrameTag;
    size_t slot = GXMatrixCacheHash(addr);
    GXMatrixCacheEntry *entry = &s_gxMatrixCache[slot];
    if (entry->addr == addr && entry->frame == frame) {
        *out = entry->matrix;
        return true;
    }
    if (!_read(addr, out, sizeof(*out))) return false;
    if (s_gxFrameTag == frame) {
        entry->addr = addr;
        entry->matrix = *out;
        entry->frame = frame;
    }
    return true;
}

static bool GXCacheParentIndex(uint64_t indicesBase, int32_t index,
                               int32_t *out) {
    if (index < 0 || out == nullptr || !isValidPtr(indicesBase)) return false;
    if ((uint64_t)index >= kGXParentSnapshotSize) {
        return _read(indicesBase + sizeof(int32_t) * index,
                     out, sizeof(*out));
    }
    uint32_t frame = s_gxFrameTag;

    // Multi-base hierarchy snapshot support to prevent thrashing between
    // vehicle and player transform hierarchies.
    size_t slot = ((indicesBase >> 6) ^ (indicesBase >> 12)) % kGXParentSnapshotSlots;
    GXParentSnapshotEntry *snap = &s_gxParentSnapshots[slot];

    if (snap->base == indicesBase && snap->frame == frame && (uint32_t)index < snap->count) {
        *out = snap->snapshot[index];
        return true;
    }

    // Page boundary guard: prevent crossing into unmapped memory pages on Apple Silicon / arm64.
    // 16KB hardware page size on iOS. Clamp read length to bytes remaining in the page.
    size_t pageSize = 0x4000;
    size_t pageRemaining = pageSize - (size_t)(indicesBase & (pageSize - 1));
    size_t bytesToRead = (pageRemaining < sizeof(snap->snapshot)) ? pageRemaining : sizeof(snap->snapshot);

    if (bytesToRead >= sizeof(int32_t) * (index + 1)) {
        int32_t tempBuffer[kGXParentSnapshotSize];
        if (_read(indicesBase, tempBuffer, bytesToRead)) {
            if (s_gxFrameTag == frame) {
                snap->base = indicesBase;
                snap->frame = frame;
                snap->count = (uint32_t)(bytesToRead / sizeof(int32_t));
                memcpy(snap->snapshot, tempBuffer, bytesToRead);
            }
            *out = tempBuffer[index];
            return true;
        }
    }

    // Fallback: direct read of the single parent index
    return _read(indicesBase + sizeof(int32_t) * index, out, sizeof(*out));
}

static Vector3 GXGetPositionExt(uint64_t transObj2, bool useFrameCache) {
    if (!isValidPtr(transObj2)) return Vector3::zero();

    uint64_t transObj = ReadAddr<uint64_t>(
        transObj2 + GameOffsets::UnityObjectCachedPtr);
    if (!isValidPtr(transObj)) return Vector3::zero();

    uint64_t matrix = ReadAddr<uint64_t>(
        transObj + GameOffsets::TransformAccess);
    int32_t index = ReadAddr<int32_t>(
        transObj + GameOffsets::TransformIndex);
    if (!isValidPtr(matrix) || index < 0 || index > 100000) {
        return Vector3::zero();
    }

    uint64_t matrix_list = ReadAddr<uint64_t>(
        matrix + GameOffsets::TransformData);
    uint64_t matrix_indices = ReadAddr<uint64_t>(
        matrix + GameOffsets::TransformParents);
    if (!isValidPtr(matrix_list) || !isValidPtr(matrix_indices)) {
        return Vector3::zero();
    }

    Vector3 result = Vector3::zero();
    if (!_read(matrix_list + sizeof(TMatrix) * index, &result, sizeof(result))) {
        return Vector3::zero();
    }

    int32_t transformIndex = -1;
    bool parentRead = useFrameCache
        ? GXCacheParentIndex(matrix_indices, index, &transformIndex)
        : _read(matrix_indices + sizeof(int32_t) * index,
                &transformIndex, sizeof(transformIndex));
    if (!parentRead) {
        return Vector3::zero();
    }

    for (int depth = 0; transformIndex >= 0 && depth < 128; depth++) {
        if (transformIndex > 100000) return Vector3::zero();

        TMatrix tMatrix = {};
        uint64_t parentMatrixAddress =
            matrix_list + sizeof(TMatrix) * transformIndex;
        bool matrixRead = useFrameCache
            ? GXCacheReadTMatrix(parentMatrixAddress, &tMatrix)
            : _read(parentMatrixAddress, &tMatrix, sizeof(tMatrix));
        if (!matrixRead) {
            return Vector3::zero();
        }

        float rotX = tMatrix.rotation.x;
        float rotY = tMatrix.rotation.y;
        float rotZ = tMatrix.rotation.z;
        float rotW = tMatrix.rotation.w;

        float scaleX = result.x * tMatrix.scale.x;
        float scaleY = result.y * tMatrix.scale.y;
        float scaleZ = result.z * tMatrix.scale.z;

        result.x = tMatrix.position.x + scaleX +
                    (scaleX * ((rotY * rotY * -2.0) - (rotZ * rotZ * 2.0))) +
                    (scaleY * ((rotW * rotZ * -2.0) - (rotY * rotX * -2.0))) +
                    (scaleZ * ((rotZ * rotX * 2.0) - (rotW * rotY * -2.0)));
        result.y = tMatrix.position.y + scaleY +
                    (scaleX * ((rotX * rotY * 2.0) - (rotW * rotZ * -2.0))) +
                    (scaleY * ((rotZ * rotZ * -2.0) - (rotX * rotX * 2.0))) +
                    (scaleZ * ((rotW * rotX * -2.0) - (rotZ * rotY * -2.0)));
        result.z = tMatrix.position.z + scaleZ +
                    (scaleX * ((rotW * rotY * -2.0) - (rotX * rotZ * -2.0))) +
                    (scaleY * ((rotY * rotZ * 2.0) - (rotW * rotX * -2.0))) +
                    (scaleZ * ((rotX * rotX * -2.0) - (rotY * rotY * 2.0)));

        int32_t parentIndex = -1;
        bool nextParentRead = useFrameCache
            ? GXCacheParentIndex(matrix_indices, transformIndex, &parentIndex)
            : _read(matrix_indices + sizeof(int32_t) * transformIndex,
                    &parentIndex, sizeof(parentIndex));
        if (!nextParentRead) {
            return Vector3::zero();
        }
        if (parentIndex == transformIndex) return Vector3::zero();
        transformIndex = parentIndex;
    }

    if (transformIndex >= 0 || !isfinite(result.x) ||
        !isfinite(result.y) || !isfinite(result.z)) {
        return Vector3::zero();
    }

    return result;
}

Vector3 getPositionExt(uint64_t transObj2) {
    return GXGetPositionExt(transObj2, true);
}

Vector3 getPositionExtUncached(uint64_t transObj2) {
    return GXGetPositionExt(transObj2, false);
}

// Player nickname fields and System.String layout for Unity 2022 IL2CPP.
NSString *GetNickName(uint64_t PawnObject) {
    uint64_t name = ReadAddr<uint64_t>(
        PawnObject + GameOffsets::PlayerOriginalNickName);
    if (!isValidPtr(name)) {
        name = ReadAddr<uint64_t>(PawnObject + GameOffsets::PlayerNickName);
    }
    if (!isValidPtr(name)) return @"";

    UTF8 PlayerName[64] = {0};
    UTF16 buf16[32] = {0};
    int32_t stringLength = ReadAddr<int32_t>(
        name + GameOffsets::StringLength);
    if (stringLength <= 0 || stringLength > 128) return @"";
    int32_t charsToRead = stringLength < 31 ? stringLength : 31;

    if (!_read(name + GameOffsets::StringFirstChar,
               buf16,
               charsToRead * sizeof(UTF16))) {
        return @"";
    }
    buf16[charsToRead] = 0;
    Utf16_To_Utf8(buf16, PlayerName, sizeof(PlayerName) - 1, lenientConversion);
    PlayerName[sizeof(PlayerName) - 1] = '\0';

    NSString *result = [NSString stringWithUTF8String:(const char *)PlayerName];
    return result ?: @"";
}
