#ifndef ESPDrawData_h
#define ESPDrawData_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// 64-slot cap so BR-mode roster scenes with valid counts above the
// legacy 16-cap aren't throttled by the packet.
#define ESP_MAX_DRAW_PLAYERS 64
#define ESP_DRAW_MAGIC 0x45535033 /* "ESP3": adds aim/FOV overlay fields */

#pragma pack(push, 4)

typedef struct {
    uint8_t valid;
    uint8_t isEnemy;
    uint8_t isVisible; // Projectable/on-screen eligibility, NOT verified game LOS.
    uint8_t hasBones;

    CGRect box;

    CGPoint headPos;
    CGPoint hipPos;
    CGPoint leftHandPos;
    CGPoint rightHandPos;
    CGPoint leftAnklePos;
    CGPoint rightAnklePos;
    CGPoint leftToePos;
    CGPoint rightToePos;

    float hpPercent;
    int32_t currentHP;
    int32_t maximumHP;
    float distanceMeters;
    char name[32];
} ESPPlayerDrawEntry;

typedef struct {
    uint32_t magic;
    uint32_t sequence;
    uint32_t count;

    uint8_t showLines;
    uint8_t showBoxes;
    uint8_t showHealth;
    uint8_t showNames;
    uint8_t showDistance;
    uint8_t showPlayerCount;
    // Aim overlay bundle (filled by the frame builder from AimAssistEngine):
    uint8_t showFov;       // draw the aim FOV circle
    uint8_t aimHasTarget;  // draw the aim lock line to aimTargetPoint
    float fovRadius;       // FOV circle radius in overlay points
    CGPoint aimTargetPoint;

    ESPPlayerDrawEntry players[ESP_MAX_DRAW_PLAYERS];
} ESPDrawPacket;

#pragma pack(pop)

#endif /* ESPDrawData_h */
