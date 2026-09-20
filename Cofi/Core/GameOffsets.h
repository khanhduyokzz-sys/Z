#ifndef GameOffsets_h
#define GameOffsets_h

#include <cstddef>
#include <cstdint>

namespace GameOffsets {

inline constexpr char ExpectedGameVersion[] = "1.132.1";

inline constexpr uint64_t GameFacadeTypeInfo = 0xBB46A50ULL;
inline constexpr uint64_t GameVarDefTypeInfo = 0xBB46AF8ULL;
inline constexpr uint64_t Il2CppClassStaticFields = 0xB8ULL;

inline constexpr uint64_t GameFacadeCurrentGame = 0x0ULL;
inline constexpr uint64_t GameFacadeCurrentMatchGame = 0x8ULL;
inline constexpr uint64_t GameFacadeIsObserver = 0x153ULL;
inline constexpr uint64_t GameFacadeIsMatchStarted = 0x209ULL;

inline constexpr uint64_t BaseGameHasInited = 0x80ULL;
inline constexpr uint64_t BaseGameHasLoadingFailed = 0x81ULL;
inline constexpr uint64_t BaseGameHasFixedUpdated = 0x82ULL;
inline constexpr uint64_t BaseGameSceneLoaded = 0x83ULL;
inline constexpr uint64_t BaseGameIsPaused = 0x84ULL;
inline constexpr uint64_t BaseGameIsMatchEnd = 0x8CULL;
inline constexpr uint64_t MatchGameMatch = 0x90ULL;
inline constexpr uint64_t MatchGameGRIDataPool = 0xD0ULL;
inline constexpr uint64_t MatchGameCameraControllerManager = 0xD8ULL;
inline constexpr uint64_t CameraControllerManagerGameCamera = 0x20ULL;
inline constexpr uint64_t CameraControllerManagerAltCamera = 0x28ULL;
inline constexpr uint64_t MatchLocalPlayer = 0xD8ULL;
inline constexpr uint64_t MatchShortIdToPlayers = 0x148ULL;

inline constexpr uint64_t EntityIsRecycle = 0x28ULL;
inline constexpr uint64_t EntityCachedTransform = 0x58ULL;
inline constexpr uint64_t EntityPRIReceivedFirstTime = 0x68ULL;
inline constexpr uint64_t PlayerPRIDataPool = 0x70ULL;
inline constexpr uint64_t PlayerIsDead = 0x7CULL;
inline constexpr uint64_t PlayerUGCStartFiring = 0x259ULL;
inline constexpr uint64_t PlayerIsInZeppelin = 0x2ECULL;
inline constexpr uint64_t PlayerLastStartFireTime = 0x37CULL;
inline constexpr uint64_t PlayerMainCameraTransform = 0x3E8ULL;
inline constexpr uint64_t PlayerId = 0x408ULL;
inline constexpr uint64_t PlayerNickName = 0x490ULL;
inline constexpr uint64_t PlayerOriginalNickName = 0x498ULL;
inline constexpr uint64_t PlayerIsClientBot = 0x4A0ULL;
inline constexpr uint64_t PlayerAvatarInitialized = 0x4C0ULL;
inline constexpr uint64_t PlayerIsInVehicle = 0x4F8ULL;
inline constexpr uint64_t PlayerAimRotation = 0x614ULL;
inline constexpr uint64_t PlayerAimRotationAux = 0x628ULL;
inline constexpr uint64_t PlayerModelVisibilityState = 0xAD0ULL;
inline constexpr uint64_t PlayerIsKnockedDownBleed = 0x1258ULL;
inline constexpr uint64_t PlayerIsKnockDownBleedingFromGS = 0x1259ULL;
inline constexpr uint64_t PlayerCurrentAimRotation = 0x1A8CULL;
inline constexpr uint64_t PlayerBeingRescuredState = 0x1CA2ULL;
inline constexpr uint64_t PlayerPhysXData = 0x1D48ULL;
inline constexpr uint64_t PhysXStateClassRef = 0x20ULL;
inline constexpr uint64_t PhysXGhgState = 0x10ULL;

inline constexpr uint64_t PlayerHeadNode = 0x6A0ULL;
inline constexpr uint64_t PlayerHipNode = 0x6A8ULL;
inline constexpr uint64_t PlayerLeftAnkleNode = 0x6D8ULL;
inline constexpr uint64_t PlayerRightAnkleNode = 0x6E0ULL;
inline constexpr uint64_t PlayerLeftToeNode = 0x6E8ULL;
inline constexpr uint64_t PlayerRightToeNode = 0x6F0ULL;
inline constexpr uint64_t PlayerLeftShoulderNode = 0x708ULL;
inline constexpr uint64_t PlayerRightShoulderNode = 0x710ULL;
inline constexpr uint64_t PlayerRightHandNode = 0x718ULL;
inline constexpr uint64_t PlayerLeftHandNode = 0x720ULL;
inline constexpr uint64_t PlayerRightForeArmNode = 0x728ULL;
inline constexpr uint64_t PlayerLeftForeArmNode = 0x730ULL;
inline constexpr uint64_t PlayerSpineBone = 0x9E8ULL;
inline constexpr uint64_t PlayerHeadBone = 0xA00ULL;
inline constexpr uint64_t PlayerHipsBone = 0xA08ULL;

inline constexpr uint64_t GameVarDefSensitivityBlock = 0x1140ULL;
inline constexpr uint64_t GameVarDefRotationSensitivityMax = 0x1144ULL;
inline constexpr uint64_t GameVarDefAimRotationSensitivityMin = 0x1148ULL;
inline constexpr uint64_t GameVarDefAimRotationSensitivityMax = 0x114CULL;

// ─── Aim Enhancement offsets (verified dump 55_3, mirrors reference Vip build) ───
inline constexpr uint64_t PlayerAuxAimResetTime = 0xE38ULL;   // float — 0 => immediate target switch
inline constexpr uint64_t PlayerMinAngleX = 0xE3CULL;         // float — pitch min (snap-aim window)
inline constexpr uint64_t PlayerMaxAngleX = 0xE40ULL;         // float — pitch max (snap-aim window)

// Avatar render chain (reference Vip getIsVisible): Player.AvatarManager ->
// IUmaAvatar -> private bool IsVisible. The Aim engine uses this proven
// 3-hop bool instead of the BitArray aggregate the ESP collector reads.
inline constexpr uint64_t PlayerAvatarManager = 0x770ULL;      // Player.m_AvatarManager
inline constexpr uint64_t AvatarManagerUmaAvatar = 0x138ULL;   // AvatarManager.m_Avatar
inline constexpr uint64_t UmaAvatarIsVisible = 0x101ULL;       // IUmaAvatar.IsVisible (bool)

// PhysicalCCT drive state — real velocity used for bullet-drop style
// prediction. Chain: Player.PhysicalCCT -> EOGPGNIDOKF.Velocity.
inline constexpr uint64_t PlayerPhysicalCCT = 0x268ULL;
inline constexpr uint64_t PhysicalCCTVelocity = 0x17CULL;

// Weapon data chain: Player.InventoryManager(0x740) -> itemOnHand(0xA0) ->
// weapon object -> UGCWeaponRepItem(0x768). All floats/bools live on the
// rep item and are dump-verified.
inline constexpr uint64_t PlayerInventoryManager = 0x740ULL;
inline constexpr uint64_t InventoryItemOnHand = 0xA0ULL;
inline constexpr uint64_t WeaponRepItem = 0x768ULL;
inline constexpr uint64_t WeaponRange = 0x1F4ULL;              // float — effective range (m)
inline constexpr uint64_t WeaponFireInterval = 0x1F8ULL;       // float — seconds between shots
inline constexpr uint64_t WeaponFullDamageDistance = 0x208ULL; // float — range where damage falls off
inline constexpr uint64_t WeaponIsSingleShot = 0x27CULL;       // bool  — AWM/M590 style weapons

inline constexpr uint64_t DictionaryEntries = 0x18ULL;
inline constexpr uint64_t DictionaryCount = 0x20ULL;
inline constexpr uint64_t ArrayLength = 0x18ULL;
inline constexpr uint64_t ArrayItems = 0x20ULL;
inline constexpr uint64_t BytePlayerEntryValue = 0x10ULL;
inline constexpr uint64_t BytePlayerEntrySize = 0x18ULL;
inline constexpr uint64_t StringLength = 0x10ULL;
inline constexpr uint64_t StringFirstChar = 0x14ULL;
inline constexpr uint64_t ReplicationDataPoolData = 0x10ULL;
inline constexpr uint64_t ReplicationDataGroup = 0x10ULL;
inline constexpr uint64_t ReplicationDataValue = 0x18ULL;
inline constexpr uint64_t TransformNodeTransform = 0x10ULL;

inline constexpr int PriVarScope = 12;
inline constexpr int PriVarFire = 21;
inline constexpr uint32_t ReplicationGroupUInt8 = 1U;
inline constexpr uint32_t ReplicationGroupUInt16 = 3U;
inline constexpr uint32_t ReplicationGroupUInt32 = 5U;
inline constexpr uint32_t PhysXPoseSkyDiving = 5U;
inline constexpr uint32_t PhysXPoseKnockDown = 8U;
inline constexpr uint32_t PhysXPoseParachuteFalling = 31U;

inline constexpr uint64_t UnityObjectCachedPtr = 0x10ULL;
inline constexpr uint64_t TransformAccess = 0x38ULL;
inline constexpr uint64_t TransformIndex = 0x40ULL;
inline constexpr uint64_t TransformData = 0x18ULL;
inline constexpr uint64_t TransformParents = 0x20ULL;

inline constexpr uint64_t BitArrayBooleanValue = 0x10ULL;
inline constexpr uint64_t BitArrayBooleanInitialValue = 0x14ULL;
inline constexpr uint64_t BitArrayBooleanMode = 0x18ULL;
inline constexpr int32_t BitArrayBooleanAndTrue = 0;
inline constexpr int32_t BitArrayBooleanOrTrue = 1;

} // namespace GameOffsets

struct BytePlayerDictionaryEntry {
    int32_t hashCode;
    int32_t next;
    uint8_t key;
    uint8_t padding[7];
    uint64_t value;
};

static_assert(sizeof(BytePlayerDictionaryEntry) == GameOffsets::BytePlayerEntrySize,
              "Unexpected Dictionary<byte, Player>.Entry layout");
static_assert(offsetof(BytePlayerDictionaryEntry, value) ==
                  GameOffsets::BytePlayerEntryValue,
              "Unexpected Dictionary<byte, Player>.Entry value offset");

#endif
