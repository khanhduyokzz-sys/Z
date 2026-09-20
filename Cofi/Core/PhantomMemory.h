#ifndef PhantomMemory_h
#define PhantomMemory_h

#import <Foundation/Foundation.h>
#import "../DarkSwordMemoryProvider.h"

#ifdef __cplusplus
extern "C" {
#endif

void phantom_memory_set_provider(DarkSwordMemoryProvider *provider);
DarkSwordMemoryProvider *phantom_memory_get_provider(void);
bool phantom_read_bytes(uint64_t address, void *buffer, size_t size);
// Kernel-backed remote write. Fails closed when the active provider does not
// implement a write transport (or was built read-only).
bool phantom_write_bytes(uint64_t address, const void *buffer, size_t size);

#ifdef __cplusplus
}
#endif

#ifdef __cplusplus

inline bool is_valid_ptr(uint64_t addr) {
    return (addr >= 0x100000000 && addr < 0x1600000000 && (addr & 0x7) == 0);
}

template<typename T>
inline T ReadAddr(uint64_t address) {
    T data;
    memset(&data, 0, sizeof(T));
    phantom_read_bytes(address, &data, sizeof(T));
    return data;
}

#endif /* __cplusplus */

#endif /* PhantomMemory_h */
