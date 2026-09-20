#import "PhantomMemory.h"

static __weak DarkSwordMemoryProvider *s_activeProvider = nil;

// Shared Aim write-arm switch (declared in MemoryUtils.h). Never defaults to
// true: the aim engine flips it only while the user has Aimbot enabled and a
// healthy provider session is active.
bool cofi_aim_write_armed = false;

void phantom_memory_set_provider(DarkSwordMemoryProvider *provider) {
    s_activeProvider = provider;
}

DarkSwordMemoryProvider *phantom_memory_get_provider(void) {
    return s_activeProvider;
}

bool phantom_read_bytes(uint64_t address, void *buffer, size_t size) {
    if (!s_activeProvider || !buffer || size == 0) return false;
    return [s_activeProvider readMemory:address into:buffer size:size];
}

bool phantom_write_bytes(uint64_t address, const void *buffer, size_t size) {
    if (!s_activeProvider || !buffer || size == 0) return false;
    DarkSwordMemoryProvider *provider = s_activeProvider;
    if (![provider respondsToSelector:@selector(writeMemory:from:size:)]) return false;
    return [provider writeMemory:address from:buffer size:size];
}
