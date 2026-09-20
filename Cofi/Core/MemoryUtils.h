#ifndef MemoryUtils_h
#define MemoryUtils_h

#import "PhantomMemory.h"

#include <cstdint>
#include <cstddef>
#include <cstring>

#ifdef __cplusplus
#include <type_traits>

// Write-arm state for the Aim domain. Defined once in PhantomMemory.mm so
// every TU shares the same switch (the aim engine arms it when the user
// enables Aimbot, and disarms it when Aimbot or the session turns off).
extern bool cofi_aim_write_armed;

// Userspace pointer range for the Free Fire process on iOS. Alignment is not
// enforced here: struct/byte reads have no alignment requirement, while
// pointer targets are already 8-aligned by IL2CPP layout.
inline bool isValidPtr(uint64_t addr) {
    return addr >= 0x100000000ULL && addr < 0x1600000000ULL;
}

// Cofi routes memory access through the DarkSword provider. Remote writes are
// reserved for the Aim engine and must be explicitly armed by the user-facing
// toggle: every write helper fails closed while its domain is disabled, so a
// stray call can never mutate the game when Aim is off.
enum class RemoteWriteDomain : uint8_t {
    Aim = 0,
    Swipe = 1,
};

inline void SetRemoteWriteDomainEnabled(RemoteWriteDomain domain, bool enabled) {
    // Only the Aim domain exists today; the flag is intentionally a no-op for
    // every other value so future domains cannot inherit Aim's arm state.
    if (domain == RemoteWriteDomain::Aim)
        cofi_aim_write_armed = enabled;
}
inline bool IsRemoteWriteDomainEnabled(RemoteWriteDomain domain) {
    return domain == RemoteWriteDomain::Aim && cofi_aim_write_armed;
}
inline void SetPureSafeModeEnabled(bool) {}
inline bool IsPureSafeModeEnabled(void) { return false; }

// Session lifecycle is owned by the memory provider + installer view controller.
inline bool IsAuthorizedGameSessionAlive(void) {
    return phantom_memory_get_provider() != nil;
}

inline int GetAuthorizedGamePID(void) { return -1; }
inline void ReleaseGameTask(void) {}

// Read primitive backing every remote access. Uses the C wrapper in
// PhantomMemory so a single provider instance owns the underlying transport.
inline bool _read(uint64_t addr, void *buffer, int len) {
    if (!buffer || len <= 0) return false;
    if (addr < 0x100000000ULL || addr >= 0x1600000000ULL) return false;
    return phantom_read_bytes(addr, buffer, static_cast<size_t>(len));
}

// Aim write primitive. Fails closed unless the Aim write domain is armed AND
// the active provider exposes a write transport. Every caller must treat a
// false return as "the game state was not modified".
inline bool _write(RemoteWriteDomain domain, uint64_t addr, const void *buffer, int len) {
    if (!cofi_aim_write_armed || domain != RemoteWriteDomain::Aim) return false;
    if (!buffer || len <= 0) return false;
    if (addr < 0x100000000ULL || addr >= 0x1600000000ULL) return false;
    return phantom_write_bytes(addr, buffer, static_cast<size_t>(len));
}

template<typename T> bool TryReadAddr(uint64_t address, T *out) {
    static_assert(std::is_trivially_copyable<T>::value,
                  "Remote reads require trivially-copyable data");
    if (out == nullptr) return false;
    *out = T{};
    return phantom_read_bytes(address, static_cast<void *>(out), sizeof(T));
}

template<typename T> bool WriteAddr(RemoteWriteDomain domain, uint64_t address, const T &value) {
    static_assert(std::is_trivially_copyable<T>::value,
                  "Remote writes require trivially-copyable data");
    return _write(domain, address, &value, static_cast<int>(sizeof(T)));
}

#endif

#endif /* MemoryUtils_h */
