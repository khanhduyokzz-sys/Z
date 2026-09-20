#ifndef ESPDataCollector_h
#define ESPDataCollector_h

#import <Foundation/Foundation.h>
#import "../Core/GameLogic.h"

/// Maximum number of players to track per frame
static const NSInteger kMaxTrackedPlayers = 120;

/// Hard view cap (meters) for both tracked ESP entities and directional lines.
static const float kEspMaxTrackDistance = 100.0f;
/// LOD threshold (meters): enemy names shown up to max track range
static const float kEspNameLodDistance = 100.0f;
/// LOD threshold (meters): enemy skeleton only shown closer than this to preserve performance
static const float kEspSkeletonLodDistance = 85.0f;
/// Airborne gate (meters): enemy head higher than this above the local camera
/// is treated as plane/glider phase and skipped (ghost boxes over empty map).
static const float kEspAirborneDeltaMeters = 110.0f;

/// Per-player data collected each frame (world-space, pre-projection)
@interface ESPPlayerData : NSObject
@property (nonatomic, assign) uint64_t pawn;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) Vector3 headWorld;
@property (nonatomic, assign) Vector3 toeWorld;
@property (nonatomic, assign) float distance;
@property (nonatomic, assign) int currentHP;
@property (nonatomic, assign) int maxHP;
@property (nonatomic, assign) BOOL isBot;
@property (nonatomic, assign) BOOL isInVehicle;
@property (nonatomic, assign) BOOL isKnocked;

// Skeleton bone transform pointers (for ESP skeleton rendering)
@property (nonatomic, assign) uint64_t bHead;
@property (nonatomic, assign) uint64_t bHeadBone;
@property (nonatomic, assign) uint64_t bSpine;
@property (nonatomic, assign) uint64_t bHipsBone;
@property (nonatomic, assign) uint64_t bHipsNode;
@property (nonatomic, assign) uint64_t bLShoulder;
@property (nonatomic, assign) uint64_t bRShoulder;
@property (nonatomic, assign) uint64_t bLElbow;
@property (nonatomic, assign) uint64_t bRElbow;
@property (nonatomic, assign) uint64_t bLHand;
@property (nonatomic, assign) uint64_t bRHand;
@property (nonatomic, assign) uint64_t bLAnkle;
@property (nonatomic, assign) uint64_t bRAnkle;

// Camera projection sample (head + toe for matrix validation)
@property (nonatomic, assign) CameraProjectionSample projectionSample;
@end

/// Result of a full frame data collection pass
@interface ESPFrameSnapshot : NSObject

@property (nonatomic, assign) BOOL isValid;
@property (nonatomic, assign) uint64_t camera;
@property (nonatomic, assign) uint64_t cameraManager;
@property (nonatomic, assign) uint64_t match;
@property (nonatomic, assign) uint64_t localPlayer;
@property (nonatomic, assign) Vector3 localPosition;
// Temporal view sample used to reject a camera matrix that has stopped
// updating while the player is still panning the camera.
@property (nonatomic, assign) Quaternion viewRotation;
@property (nonatomic, assign) BOOL hasViewRotation;

@property (nonatomic, assign) int enemyCount;
@property (nonatomic, strong) NSMutableArray<ESPPlayerData *> *players;

@property (nonatomic, copy) NSString *statusMessage;

@end

/// Global game module base address (defined in ESPDataCollector.mm)
extern uint64_t ModuleBase;

/// Collects player data from game memory each frame
@interface ESPDataCollector : NSObject
/// Expensive identity and skeleton streams are opt-in so disabled overlays do
/// not keep issuing cross-process reads.
@property (nonatomic, assign) BOOL collectNames;
@property (nonatomic, assign) BOOL collectSkeleton;
- (ESPFrameSnapshot *)collectFrame:(CGSize)overlaySize;
@end

#endif
