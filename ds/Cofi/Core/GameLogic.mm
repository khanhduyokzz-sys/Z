#import "GameLogic.h"

#include <cstring>

#pragma mark - Function Game

static bool MatchGameHasLocalPlayer(uint64_t matchGame) {
    if (!isValidPtr(matchGame)) return false;
    uint64_t match = ReadAddr<uint64_t>(
        matchGame + GameOffsets::MatchGameMatch);
    if (!isValidPtr(match)) return false;
    return isValidPtr(ReadAddr<uint64_t>(
        match + GameOffsets::MatchLocalPlayer));
}

// GameFacade.CurrentMatchGame/CurrentGame (Free Fire 1.130.1,
// TypeDefIndex 12041). GameFacade.CurrentMatch() selects between these two
// fields at runtime; prefer the strongly typed MatchGame field at +0x8.
uint64_t getMatchGame(uint64_t moduleBase) {
    uint64_t GameFacade_TypeInfo = ReadAddr<uint64_t>(
        moduleBase + GameOffsets::GameFacadeTypeInfo);
    if (!isValidPtr(GameFacade_TypeInfo)) return 0;

    uint64_t GameFacade_Static = ReadAddr<uint64_t>(
        GameFacade_TypeInfo + GameOffsets::Il2CppClassStaticFields);
    if (!isValidPtr(GameFacade_Static)) return 0;

    uint64_t currentMatchGame = ReadAddr<uint64_t>(
        GameFacade_Static + GameOffsets::GameFacadeCurrentMatchGame);
    uint64_t currentGame = ReadAddr<uint64_t>(
        GameFacade_Static + GameOffsets::GameFacadeCurrentGame);

    // Keep the last facade candidate that actually owned a local player.
    // During BR transitions both facade fields may remain valid while only one
    // is the active MatchGame, and blindly falling back to CurrentMatchGame
    // makes the collector jump to a different Match object for a few frames.
    static uint64_t lastLiveMatchGame = 0;

    // Prefer whichever candidate owns a live local player. This mirrors the
    // mode-dependent choice made inside GameFacade.CurrentMatch().
    if (MatchGameHasLocalPlayer(currentMatchGame)) {
        lastLiveMatchGame = currentMatchGame;
        return currentMatchGame;
    }
    if (MatchGameHasLocalPlayer(currentGame)) {
        lastLiveMatchGame = currentGame;
        return currentGame;
    }
    if (isValidPtr(lastLiveMatchGame) &&
        (lastLiveMatchGame == currentMatchGame ||
         lastLiveMatchGame == currentGame)) {
        return lastLiveMatchGame;
    }
    if (isValidPtr(currentMatchGame)) return currentMatchGame;

    return currentGame;
}

// MatchGame.m_Match (TypeDefIndex 12048).
uint64_t getMatch(uint64_t matchgame) {
    return ReadAddr<uint64_t>(matchgame + GameOffsets::MatchGameMatch);
}

// MatchGame.m_CameraControllerManager -> CameraControllerManager.GameCamera.
uint64_t CameraMain(uint64_t matchgame) {
    uint64_t CameraControllerManager = ReadAddr<uint64_t>(
        matchgame + GameOffsets::MatchGameCameraControllerManager);
    return ReadAddr<uint64_t>(
        CameraControllerManager + GameOffsets::CameraControllerManagerGameCamera);
}

// Transform node accessor.
uint64_t getTransNode(uint64_t BodyPart) {
    if (!isValidPtr(BodyPart)) return 0;
    return ReadAddr<uint64_t>(
        BodyPart + GameOffsets::TransformNodeTransform);
}

// Player.HeadNode (TypeDefIndex 30887).
uint64_t getHead(uint64_t player) {
    uint64_t BodyPart = ReadAddr<uint64_t>(
        player + GameOffsets::PlayerHeadNode);
    return getTransNode(BodyPart);
}

// Player.m_RightToeNode.
uint64_t getRightToeNode(uint64_t player) {
    uint64_t BodyPart = ReadAddr<uint64_t>(
        player + GameOffsets::PlayerRightToeNode);
    return getTransNode(BodyPart);
}

// Generic bone accessor
uint64_t getBone(uint64_t player, int offset) {
    uint64_t BodyPart = ReadAddr<uint64_t>(player + offset);
    return getTransNode(BodyPart);
}

// Match.m_LocalPlayer (obfuscated class EMKJHAJNPDH, TypeDefIndex 31032).
uint64_t getLocalPlayer(uint64_t match) {
    return ReadAddr<uint64_t>(match + GameOffsets::MatchLocalPlayer);
}

COW_GamePlay_PlayerID_o ReadPlayerID(uint64_t player) {
    COW_GamePlay_PlayerID_o id = {};
    if (isValidPtr(player)) {
        id = ReadAddr<COW_GamePlay_PlayerID_o>(player + GameOffsets::PlayerId);
    }
    return id;
}

bool PlayerIDIsTeamMate(const COW_GamePlay_PlayerID_o &myPlayerID,
                        const COW_GamePlay_PlayerID_o &playerID) {
    int myTeamID = myPlayerID.m_TeamID;
    int TeamID = playerID.m_TeamID;

    // In Solo mode or unassigned team (both 0), only match if they share identity
    if (myTeamID == 0 && TeamID == 0) {
        return (myPlayerID.m_ShortID == playerID.m_ShortID) ||
               (myPlayerID.m_ID != 0 && myPlayerID.m_ID == playerID.m_ID);
    }

    return myTeamID == TeamID;
}

bool TryGetPlayerPhysXState(uint64_t player, uint32_t *outState) {
    if (outState == nullptr) return false;
    *outState = 0;
    if (!isValidPtr(player)) return false;

    uint64_t physXData = 0;
    if (!_read(static_cast<long>(
                   player + GameOffsets::PlayerPhysXData),
               &physXData, sizeof(physXData)) ||
        !isValidPtr(physXData)) {
        return false;
    }

    uint64_t poseState = 0;
    if (!_read(static_cast<long>(
                   physXData + GameOffsets::PhysXStateClassRef),
               &poseState, sizeof(poseState)) ||
        !isValidPtr(poseState)) {
        return false;
    }

    uint32_t state = 0;
    if (!_read(static_cast<long>(
                   poseState + GameOffsets::PhysXGhgState),
               &state, sizeof(state)) ||
        state >= 38) {
        return false;
    }

    *outState = state;
    return true;
}

bool IsPlayerKnockedDown(uint64_t player,
                         bool physXStateReadable,
                         uint32_t physXState) {
    if (!isValidPtr(player)) return false;

    // data.cs Player TypeDefIndex 30887. Read the two adjacent authoritative
    // bleed flags together so ESP and Aim cannot disagree for one frame.
    uint8_t knockFlags[2] = {};
    if (_read(static_cast<long>(
                  player + GameOffsets::PlayerIsKnockedDownBleed),
              knockFlags, sizeof(knockFlags)) &&
        (knockFlags[0] != 0 || knockFlags[1] != 0)) {
        return true;
    }

    // A player being rescued is necessarily still knocked. This also covers
    // the short transition where the bleed flags are updated out of order.
    uint8_t rescueState = 0;
    if (_read(static_cast<long>(
                  player + GameOffsets::PlayerBeingRescuredState),
              &rescueState, sizeof(rescueState)) && rescueState >= 2) {
        return true;
    }

    // PhysX pose is an independent fallback:
    // Player.FGAHFBDAKPI @ Player+0x1B80 -> active pose object @+0x20 ->
    // EOGPGNIDOKF @+0x10, where EPHYSXPOSE_KNOCKDOWN == 8.
    return physXStateReadable &&
        physXState == GameOffsets::PhysXPoseKnockDown;
}

bool IsPlayerKnockedDown(uint64_t player) {
    uint32_t physXState = 0;
    bool physXStateReadable = TryGetPlayerPhysXState(player, &physXState);
    return IsPlayerKnockedDown(player, physXStateReadable, physXState);
}

// GCommon.BitArrayBoolean (data.cs TypeDefIndex 35092): BitArray.m_Value at
// 0x10, m_InitialValue at 0x14 and m_Mode at 0x18. Player.CNELANECFHO at
// 0xA50 is the aggregate that tracks whether the avatar model is rendered.
bool TryGetPlayerModelVisibility(uint64_t player,
                                 bool *outVisible,
                                 uint32_t *outValue,
                                 uint8_t *outInitialValue,
                                 int32_t *outMode) {
    if (outVisible == nullptr) return false;
    *outVisible = true;
    if (outValue != nullptr) *outValue = 0;
    if (outInitialValue != nullptr) *outInitialValue = 0;
    if (outMode != nullptr) *outMode = -1;
    if (!isValidPtr(player)) return false;

    uint64_t visibilityState = 0;
    if (!_read(static_cast<long>(
                   player + GameOffsets::PlayerModelVisibilityState),
               &visibilityState, sizeof(visibilityState)) ||
        !isValidPtr(visibilityState)) {
        return false;
    }

    struct VisibilityBits {
        uint32_t value;
        uint8_t initialValue;
        uint8_t padding[3];
        int32_t mode;
    } bits{};
    static_assert(sizeof(VisibilityBits) == 12,
                  "Unexpected BitArrayBoolean field layout");

    if (!_read(static_cast<long>(
                   visibilityState + GameOffsets::BitArrayBooleanValue),
               &bits, sizeof(bits)) ||
        bits.initialValue > 1) {
        return false;
    }

    if (outValue != nullptr) *outValue = bits.value;
    if (outInitialValue != nullptr) *outInitialValue = bits.initialValue;
    if (outMode != nullptr) *outMode = bits.mode;

    // BitArrayBoolean stores the boolean value of every registered flag
    // directly: true adds its bit, false removes it. AND_TRUE is true only
    // when every bit is set; OR_TRUE is true when at least one bit is set.
    // Runtime confirmation from OB54:
    //   mode=0, value=0xFFFFFDFB -> hidden (STREAMER/ZoneChange cleared)
    //   mode=0, value=0xFFFFFFFF -> visible
    if (bits.mode == GameOffsets::BitArrayBooleanAndTrue) {
        *outVisible = bits.value == UINT32_MAX;
        return true;
    }
    if (bits.mode == GameOffsets::BitArrayBooleanOrTrue) {
        *outVisible = bits.value != 0;
        return true;
    }

    // Unknown mode means the runtime layout no longer matches this dump.
    return false;
}

bool IsPlayerModelVisible(uint64_t player) {
    bool visible = true;
    if (!TryGetPlayerModelVisibility(
            player, &visible, nullptr, nullptr, nullptr)) {
        // Aim writes must fail closed when PVS cannot be verified. The
        // collector independently handles admission and visual invalidation.
        return false;
    }
    return visible;
}

// Reference Vip getIsVisible: Player.AvatarManager(0x770) ->
// IUmaAvatar(0x138) -> private bool IsVisible(0x101). Simple and proven;
// used by the aim engine so a stale/unsupported BitArray aggregate can never
// silently filter out every target.
bool IsPlayerAvatarRendered(uint64_t player) {
    if (!isValidPtr(player)) return false;

    uint64_t avatarManager = ReadAddr<uint64_t>(
        player + GameOffsets::PlayerAvatarManager);
    if (!isValidPtr(avatarManager)) return false;

    uint64_t avatar = ReadAddr<uint64_t>(
        avatarManager + GameOffsets::AvatarManagerUmaAvatar);
    if (!isValidPtr(avatar)) return false;

    return ReadAddr<bool>(avatar + GameOffsets::UmaAvatarIsVisible);
}

// Player.m_PRIDataPool -> ReplicationDataPool.m_Datas -> ReplicationData.Value.
//
// ReplicationData stores its scalar inline at +0x18, while
// ReplicationDataUnsafe stores a pointer to the scalar at the same offset.
// Every read is checked so an invalid pointer chain or a wrong PRI type cannot
// silently turn into an unrelated gameplay value.
template <typename T>
static bool TryGetReplicationScalar(uint64_t player,
                                    int varID,
                                    uint32_t expectedGroup,
                                    T *outValue) {
    static_assert(sizeof(T) <= sizeof(uint64_t),
                  "Replication scalar is too large");

    if (outValue == nullptr) return false;
    *outValue = {};

    if (!isValidPtr(player) || varID < 0) return false;

    uint64_t priDataPool = 0;
    if (!_read(static_cast<long>(
                   player + GameOffsets::PlayerPRIDataPool),
               &priDataPool, sizeof(priDataPool)) ||
        !isValidPtr(priDataPool)) {
        return false;
    }

    uint64_t dataArray = 0;
    if (!_read(static_cast<long>(
                   priDataPool + GameOffsets::ReplicationDataPoolData),
               &dataArray, sizeof(dataArray)) ||
        !isValidPtr(dataArray)) {
        return false;
    }

    uint64_t dataCount = 0;
    if (!_read(static_cast<long>(
                   dataArray + GameOffsets::ArrayLength),
               &dataCount, sizeof(dataCount))) {
        return false;
    }

    if (dataCount == 0 || dataCount > 4096 ||
        static_cast<uint64_t>(varID) >= dataCount) {
        return false;
    }

    uint64_t replicationData = 0;
    uint64_t slotAddress =
        dataArray + GameOffsets::ArrayItems +
        sizeof(uint64_t) * static_cast<uint64_t>(varID);
    if (!_read(static_cast<long>(slotAddress),
               &replicationData, sizeof(replicationData)) ||
        !isValidPtr(replicationData)) {
        return false;
    }

    uint32_t group = UINT32_MAX;
    if (!_read(static_cast<long>(
                   replicationData + GameOffsets::ReplicationDataGroup),
               &group, sizeof(group)) ||
        group != expectedGroup) {
        return false;
    }

    uint64_t rawStorage = 0;
    if (!_read(static_cast<long>(
                   replicationData + GameOffsets::ReplicationDataValue),
               &rawStorage, sizeof(rawStorage))) {
        return false;
    }

    // Unsafe pool: +0x18 is a pointer. If dereferencing fails, fall back to
    // the inline-union layout used by the regular ReplicationData pool.
    if (isValidPtr(rawStorage)) {
        T indirectValue{};
        if (_read(static_cast<long>(rawStorage),
                  &indirectValue, sizeof(indirectValue))) {
            *outValue = indirectValue;
            return true;
        }
    }

    std::memcpy(outValue, &rawStorage, sizeof(T));
    return true;
}

bool TryGetDataUInt8(uint64_t player, int varID, uint8_t *outValue) {
    return TryGetReplicationScalar<uint8_t>(
        player, varID, GameOffsets::ReplicationGroupUInt8, outValue);
}

bool TryGetDataUInt16(uint64_t player, int varID, uint16_t *outValue) {
    return TryGetReplicationScalar<uint16_t>(
        player, varID, GameOffsets::ReplicationGroupUInt16, outValue);
}

bool TryGetDataUInt32(uint64_t player, int varID, uint32_t *outValue) {
    return TryGetReplicationScalar<uint32_t>(
        player, varID, GameOffsets::ReplicationGroupUInt32, outValue);
}

// Mirror of TryGetReplicationScalar that stores instead of loads. The pool
// layout must match the read side exactly: ReplicationData stores its scalar
// inline at +0x18 unless the slot holds an unsafe-pool pointer, in which case
// the scalar lives behind the pointer. The incoming value is read-verified
// after the write so a silent failure cannot be reported as success.
bool TrySetDataUInt16(uint64_t player, int varID, uint16_t value) {
    if (!isValidPtr(player) || varID < 0) return false;

    uint64_t priDataPool = 0;
    if (!_read(static_cast<long>(
                   player + GameOffsets::PlayerPRIDataPool),
               &priDataPool, sizeof(priDataPool)) ||
        !isValidPtr(priDataPool)) {
        return false;
    }

    uint64_t dataArray = 0;
    if (!_read(static_cast<long>(
                   priDataPool + GameOffsets::ReplicationDataPoolData),
               &dataArray, sizeof(dataArray)) ||
        !isValidPtr(dataArray)) {
        return false;
    }

    uint64_t dataCount = 0;
    if (!_read(static_cast<long>(
                   dataArray + GameOffsets::ArrayLength),
               &dataCount, sizeof(dataCount))) {
        return false;
    }

    if (dataCount == 0 || dataCount > 4096 ||
        static_cast<uint64_t>(varID) >= dataCount) {
        return false;
    }

    uint64_t replicationData = 0;
    uint64_t slotAddress =
        dataArray + GameOffsets::ArrayItems +
        sizeof(uint64_t) * static_cast<uint64_t>(varID);
    if (!_read(static_cast<long>(slotAddress),
               &replicationData, sizeof(replicationData)) ||
        !isValidPtr(replicationData)) {
        return false;
    }

    uint32_t group = UINT32_MAX;
    if (!_read(static_cast<long>(
                   replicationData + GameOffsets::ReplicationDataGroup),
               &group, sizeof(group)) ||
        group != GameOffsets::ReplicationGroupUInt16) {
        return false;
    }

    uint64_t rawStorage = 0;
    if (!_read(static_cast<long>(
                   replicationData + GameOffsets::ReplicationDataValue),
               &rawStorage, sizeof(rawStorage))) {
        return false;
    }

    uint64_t targetAddress = replicationData + GameOffsets::ReplicationDataValue;
    if (isValidPtr(rawStorage)) targetAddress = rawStorage;

    if (!_write(RemoteWriteDomain::Aim, targetAddress, &value, sizeof(value))) {
        return false;
    }

    uint16_t verify = 0;
    if (_read(static_cast<long>(targetAddress), &verify, sizeof(verify)) &&
        verify == value) {
        return true;
    }
    return false;
}
