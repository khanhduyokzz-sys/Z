#ifndef UnityMath_h
#define UnityMath_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Screen-space geometry helpers shared by the drawing overlay. These functions
// have no dependency on remote memory and describe the exact rectangles the
// packet-based renderer expects.
typedef struct { double x, y; } UnityScreenPoint;
typedef struct { double x, y, width, height; } UnityScreenRect;
typedef struct {
    UnityScreenRect panel;
    UnityScreenRect nameBackground;
    UnityScreenRect healthFill;
    UnityScreenRect name;
    UnityScreenPoint triangle[3];
    UnityScreenRect distance;
} UnityPlayerInfoLayout;

bool unity_math_info_layout(double x, double y, double width, double height,
                            int32_t hp, int32_t maxHP,
                            UnityPlayerInfoLayout *out);

uint32_t unity_math_info_visibility(bool health, bool name);
double unity_math_line_end_offset(bool health, bool name);

#ifdef __cplusplus
}
#endif

#ifdef __cplusplus

#import "Vector3.h"
#import "Quaternion.h"
#import "MemoryUtils.h"
#import "GameOffsets.h"
#import "utf.h"
#import <Foundation/Foundation.h>

struct Vector4 {
    float x, y, z, w;
};

struct TMatrix {
    Vector4 position;
    Quaternion rotation;
    Vector4 scale;
};

enum class CameraMatrixLayout : uint8_t {
    ColumnVector = 0,
    RowVector = 1,
};

struct CameraProjectionSample {
    Vector3 head;
    Vector3 toe;
    float distance;
};

struct CameraProjection {
    float matrix[16];
    CameraMatrixLayout layout;
    uint64_t nativeOffset;
    float score;
    float anchorResidual;
    float lockScore;
    uint64_t cameraSource;
    uint64_t nativeCameraSource;
};

struct COW_GamePlay_PlayerID_o {
    uint32_t m_Value;
    uint32_t m_ID;
    uint8_t m_TeamID;
    uint8_t m_ShortID;
    uint64_t m_IDMask;
};

static_assert(sizeof(COW_GamePlay_PlayerID_o) == 0x18,
              "Unexpected COW.GamePlay.PlayerID layout");
static_assert(offsetof(COW_GamePlay_PlayerID_o, m_Value) == 0x0, "");
static_assert(offsetof(COW_GamePlay_PlayerID_o, m_ID) == 0x4, "");
static_assert(offsetof(COW_GamePlay_PlayerID_o, m_TeamID) == 0x8, "");
static_assert(offsetof(COW_GamePlay_PlayerID_o, m_ShortID) == 0x9, "");
static_assert(offsetof(COW_GamePlay_PlayerID_o, m_IDMask) == 0x10, "");

Vector3 WorldToScreen(Vector3 obj,
                      const float *matrix,
                      CameraMatrixLayout layout,
                      float screenX,
                      float screenY,
                      bool overlayBehindCamera = false);
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
                          CameraProjection *projection);
Vector3 getPositionExt(uint64_t transObj2);
Vector3 getPositionExtUncached(uint64_t transObj2);

void GXBeginTransformReadFrame(void);

NSString *GetNickName(uint64_t PawnObject);

#endif /* __cplusplus */

#endif /* UnityMath_h */
