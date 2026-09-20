#ifndef GameLogic_h
#define GameLogic_h

#import "MemoryUtils.h"
#import "UnityMath.h"
#import "GameOffsets.h"

#pragma mark - Function Game

uint64_t getMatchGame(uint64_t moduleBase);
uint64_t getMatch(uint64_t matchgame);
uint64_t CameraMain(uint64_t matchgame);
uint64_t getTransNode(uint64_t BodyPart);
uint64_t getHead(uint64_t player);
uint64_t getRightToeNode(uint64_t player);
uint64_t getBone(uint64_t player, int offset);
uint64_t getLocalPlayer(uint64_t match);
bool TryGetDataUInt8(uint64_t player, int varID, uint8_t *outValue);
bool TryGetDataUInt16(uint64_t player, int varID, uint16_t *outValue);
bool TryGetDataUInt32(uint64_t player, int varID, uint32_t *outValue);
// Write twin of TryGetDataUInt16. Resolves the same ReplicationData pool and
// stores the scalar either inline (+0x18) or through the unsafe-pool pointer.
// Used by the Aim engine for the auto-fire state (varID 21). Fails closed.
bool TrySetDataUInt16(uint64_t player, int varID, uint16_t value);
// Reads Player.CNELANECFHO, the dump-backed model/PVS aggregate. The Try API
// separates a real hidden result from an unreadable/transitional object.
bool TryGetPlayerModelVisibility(uint64_t player,
                                 bool *outVisible,
                                 uint32_t *outValue,
                                 uint8_t *outInitialValue,
                                 int32_t *outMode);
// Convenience gate used by Aim. Unknown state fails closed so an unreadable
// or changed layout can never authorize an active write.
bool IsPlayerModelVisible(uint64_t player);

// Reference Vip visibility check (getIsVisible): reads the rendered-avatar
// bool through Player.AvatarManager -> IUmaAvatar -> IsVisible. This is the
// mechanism the aim assist ships with — a missing manager/avatar reads as
// "not rendered", a present avatar reports its actual render state.
bool IsPlayerAvatarRendered(uint64_t player);

// Team comparison against a pre-read local PlayerID — lets the per-frame
// enemy loop test every pawn with ONE memory read instead of re-reading the
// local player's ID for each dictionary entry.
COW_GamePlay_PlayerID_o ReadPlayerID(uint64_t player);
bool PlayerIDIsTeamMate(const COW_GamePlay_PlayerID_o &localID,
                        const COW_GamePlay_PlayerID_o &otherID);

// Dump-backed lifecycle gate shared by ESP and Aim. Knockdown must be
// rejected immediately; unlike visibility/geometry it is not a transient
// rendering signal and therefore receives no grace period.
bool IsPlayerKnockedDown(uint64_t player);
// Variant for callers that already sampled the pose state in the same frame.
// It avoids traversing the PhysX pointer chain twice when pose is also needed
// for flight-state filtering.
bool IsPlayerKnockedDown(uint64_t player,
                         bool physXStateReadable,
                         uint32_t physXState);
// Reads the active EOGPGNIDOKF pose through Player.FGAHFBDAKPI. Callers can
// distinguish initial BR air states from ordinary falling without relying on
// a world-height heuristic.
bool TryGetPlayerPhysXState(uint64_t player, uint32_t *outState);

#endif
