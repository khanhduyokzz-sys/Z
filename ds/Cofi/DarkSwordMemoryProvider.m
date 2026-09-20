#import "DarkSwordMemoryProvider.h"
#import "kexploit/kutils.h"
#import "kexploit/krw.h"
#import "kexploit/offsets.h"
#import "TaskRop/VM.h"

// Shared Aim write-arm switch (defined in PhantomMemory.mm). Only used here
// to widen the transaction map budget while the aim engine is live.
extern bool cofi_aim_write_armed;

#import <mach/mach.h>
#import <mach-o/loader.h>
#import <math.h>

extern kern_return_t mach_vm_deallocate(task_t task, mach_vm_address_t addr, mach_vm_size_t size);

#define DS_PAGE_SHIFT   14
#define DS_PAGE_SIZE    (1ULL << DS_PAGE_SHIFT)
#define DS_PAGE_MASK    (DS_PAGE_SIZE - 1)

static inline uint64_t ds_page_align(uint64_t addr) {
    return addr & ~DS_PAGE_MASK;
}

static inline uint32_t ds_page_hash(uint64_t pageAddr) {
    return (uint32_t)((pageAddr >> DS_PAGE_SHIFT) & (DS_PAGE_LOOKUP_COUNT - 1));
}

@implementation DarkSwordMemoryProvider

- (instancetype)initWithTargetProcessName:(NSString *)name {
    self = [super init];
    if (!self) return nil;

    _targetProcessName = [name copy];
    _stateLock = [[NSRecursiveLock alloc] init];
    _moduleBaseCache = [[NSMutableDictionary alloc] init];
    _ready = NO;
    _shutDown = NO;
    _degraded = NO;
    _pageUseCounter = 0;
    _consecutiveOperationalFailures = 0;
    _readTransactionDepth = 0;

    memset(_pageSlots, 0, sizeof(_pageSlots));
    memset(_recentPageSlots, 0, sizeof(_recentPageSlots));
    memset(_pageLookup, 0, sizeof(_pageLookup));
    memset(_failedPages, 0, sizeof(_failedPages));
    memset(_writeSlots, 0, sizeof(_writeSlots));

    _procAddress = proc_find_by_name([_targetProcessName UTF8String]);
    if (!_procAddress || _procAddress == (uint64_t)-1) {
        printf("[DarkSwordMemoryProvider] process not found: %s\n", [_targetProcessName UTF8String]);
        return self;
    }

    uint64_t procRo = kread64(_procAddress + off_proc_p_proc_ro);
    if (!procRo || !is_kaddr_valid(procRo)) {
        printf("[DarkSwordMemoryProvider] invalid proc_ro for %s\n", [_targetProcessName UTF8String]);
        return self;
    }

    _taskAddress = kread_ptr(procRo + off_proc_ro_pr_task);
    if (!_taskAddress || !is_kaddr_valid(_taskAddress)) {
        printf("[DarkSwordMemoryProvider] invalid task for %s\n", [_targetProcessName UTF8String]);
        return self;
    }

    _vmMapAddress = kread_ptr(_taskAddress + off_task_map);
    if (!_vmMapAddress || !is_kaddr_valid(_vmMapAddress)) {
        printf("[DarkSwordMemoryProvider] invalid vm_map for %s\n", [_targetProcessName UTF8String]);
        return self;
    }

    printf("[DarkSwordMemoryProvider] initialized: proc=0x%llx task=0x%llx vmMap=0x%llx\n",
           _procAddress, _taskAddress, _vmMapAddress);
    _ready = YES;
    return self;
}

- (BOOL)isReady {
    return _ready && !_shutDown;
}

#pragma mark - Transaction

- (BOOL)beginReadTransaction {
    [_stateLock lock];
    if (_shutDown) {
        [_stateLock unlock];
        return NO;
    }
    if (_readTransactionDepth == 0) {
        _transactionNewMapCount = 0;
        _readTransactionFailed = NO;
    }
    _readTransactionDepth++;
    [_stateLock unlock];
    return YES;
}

- (void)endReadTransaction {
    [_stateLock lock];
    if (_readTransactionDepth > 0)
        _readTransactionDepth--;
    [_stateLock unlock];
}

#pragma mark - Page Cache

- (struct DSPageSlot *)lookupPage:(uint64_t)pageAddr {
    for (int i = 0; i < DS_RECENT_SLOT_COUNT; i++) {
        struct DSPageSlot *slot = _recentPageSlots[i];
        if (slot && slot->mapping.used && slot->mapping.remoteAddress == pageAddr) {
            slot->lastUse = ++_pageUseCounter;
            return slot;
        }
    }

    uint32_t hash = ds_page_hash(pageAddr);
    for (uint32_t i = 0; i < DS_PAGE_LOOKUP_COUNT; i++) {
        uint32_t idx = (hash + i) & (DS_PAGE_LOOKUP_COUNT - 1);
        struct DSPageSlot *slot = _pageLookup[idx];
        if (!slot) break;
        if (slot->mapping.used && slot->mapping.remoteAddress == pageAddr) {
            slot->lastUse = ++_pageUseCounter;
            [self promoteToRecent:slot];
            return slot;
        }
    }

    return NULL;
}

- (void)promoteToRecent:(struct DSPageSlot *)slot {
    for (int i = DS_RECENT_SLOT_COUNT - 1; i > 0; i--)
        _recentPageSlots[i] = _recentPageSlots[i - 1];
    _recentPageSlots[0] = slot;
}

- (struct DSPageSlot *)evictLRUSlot {
    uint64_t oldest = UINT64_MAX;
    int oldestIdx = 0;

    for (int i = 0; i < DS_PAGE_SLOT_COUNT; i++) {
        if (!_pageSlots[i].mapping.used)
            return &_pageSlots[i];
        if (_pageSlots[i].lastUse < oldest) {
            oldest = _pageSlots[i].lastUse;
            oldestIdx = i;
        }
    }

    struct DSPageSlot *slot = &_pageSlots[oldestIdx];
    [self unmapSlot:slot];
    return slot;
}

- (void)removeFromLookup:(struct DSPageSlot *)slot {
    if (!slot->mapping.used) return;

    uint32_t hash = ds_page_hash(slot->mapping.remoteAddress);
    uint32_t gapIdx = UINT32_MAX;

    for (uint32_t i = 0; i < DS_PAGE_LOOKUP_COUNT; i++) {
        uint32_t idx = (hash + i) & (DS_PAGE_LOOKUP_COUNT - 1);
        if (_pageLookup[idx] == slot) {
            _pageLookup[idx] = NULL;
            gapIdx = idx;
            break;
        }
        if (!_pageLookup[idx]) break;
    }

    if (gapIdx != UINT32_MAX) {
        for (uint32_t i = 1; i < DS_PAGE_LOOKUP_COUNT; i++) {
            uint32_t probeIdx = (gapIdx + i) & (DS_PAGE_LOOKUP_COUNT - 1);
            struct DSPageSlot *probeSlot = _pageLookup[probeIdx];
            if (!probeSlot) break;

            uint32_t naturalIdx = ds_page_hash(probeSlot->mapping.remoteAddress);
            BOOL needsMove;
            if (gapIdx <= probeIdx)
                needsMove = (naturalIdx <= gapIdx || naturalIdx > probeIdx);
            else
                needsMove = (naturalIdx <= gapIdx && naturalIdx > probeIdx);

            if (needsMove) {
                _pageLookup[gapIdx] = probeSlot;
                _pageLookup[probeIdx] = NULL;
                gapIdx = probeIdx;
            }
        }
    }

    for (int i = 0; i < DS_RECENT_SLOT_COUNT; i++) {
        if (_recentPageSlots[i] == slot)
            _recentPageSlots[i] = NULL;
    }
}

- (void)insertIntoLookup:(struct DSPageSlot *)slot {
    uint32_t hash = ds_page_hash(slot->mapping.remoteAddress);
    for (uint32_t i = 0; i < DS_PAGE_LOOKUP_COUNT; i++) {
        uint32_t idx = (hash + i) & (DS_PAGE_LOOKUP_COUNT - 1);
        if (!_pageLookup[idx]) {
            _pageLookup[idx] = slot;
            break;
        }
    }
    [self promoteToRecent:slot];
}

- (void)unmapSlot:(struct DSPageSlot *)slot {
    if (!slot->mapping.used) return;

    [self removeFromLookup:slot];

    uint64_t mappingAddress = slot->mapping.mappingAddress
        ? slot->mapping.mappingAddress : slot->mapping.localAddress;
    uint64_t mappingSize = slot->mapping.mappingSize
        ? slot->mapping.mappingSize : DS_PAGE_SIZE;
    if (mappingAddress) {
        mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)mappingAddress, mappingSize);
    }
    if (slot->mapping.port) {
        mach_port_deallocate(mach_task_self(), (mach_port_t)slot->mapping.port);
    }

    memset(slot, 0, sizeof(*slot));
}

- (struct DSPageSlot *)mapPage:(uint64_t)pageAddr {
    uint32_t failedIdx = ds_page_hash(pageAddr) & (DS_FAILED_PAGE_COUNT - 1);
    struct DSFailedPageSlot *failed = &_failedPages[failedIdx];
    double now = [NSDate timeIntervalSinceReferenceDate];
    if (failed->pageAddress == pageAddr && failed->retryAfter > now) {
        return NULL;
    }

    if (_readTransactionDepth > 0 &&
        _transactionNewMapCount >= (cofi_aim_write_armed
            ? DS_TRANSACTION_MAP_BUDGET_AIM : DS_TRANSACTION_MAP_BUDGET)) {
        return NULL;
    }
    if (_readTransactionDepth > 0) _transactionNewMapCount++;

    struct DSPageSlot *slot = [self evictLRUSlot];

    struct VMShmem shmem = vm_map_remote_page_readonly(_vmMapAddress, pageAddr);
    if (!shmem.used) {
        _consecutiveOperationalFailures++;
        if (_consecutiveOperationalFailures > 10)
            _degraded = YES;
        uint32_t count = (failed->pageAddress == pageAddr) ? failed->failureCount + 1 : 1;
        if (count > 8) count = 8;
        failed->pageAddress = pageAddr;
        failed->failureCount = count;
        failed->retryAfter = now + fmin(2.0, 0.05 * (double)(1U << (count - 1)));
        return NULL;
    }

    _consecutiveOperationalFailures = 0;
    _degraded = NO;
    if (failed->pageAddress == pageAddr) memset(failed, 0, sizeof(*failed));

    slot->mapping = shmem;
    slot->lastUse = ++_pageUseCounter;

    [self insertIntoLookup:slot];

    return slot;
}

#pragma mark - Read

- (BOOL)readMemory:(uint64_t)address into:(void *)buffer size:(size_t)size {
    if (!_ready || _shutDown || !buffer || size == 0) return NO;
    if (address < 0x100000000 || address >= 0x1600000000) return NO;
    if ((uint64_t)size > 0x100000ULL || address > UINT64_MAX - (uint64_t)size ||
        address + (uint64_t)size > 0x1600000000ULL) return NO;

    memset(buffer, 0, size);
    [_stateLock lock];

    uint8_t *dst = (uint8_t *)buffer;
    uint64_t remaining = size;
    uint64_t currentAddr = address;

    while (remaining > 0) {
        uint64_t pageAddr = ds_page_align(currentAddr);
        uint64_t pageOffset = currentAddr & DS_PAGE_MASK;
        uint64_t chunkSize = DS_PAGE_SIZE - pageOffset;
        if (chunkSize > remaining)
            chunkSize = remaining;

        struct DSPageSlot *slot = [self lookupPage:pageAddr];
        if (!slot) {
            slot = [self mapPage:pageAddr];
        }

        if (!slot || !slot->mapping.localAddress) {
            _readTransactionFailed = YES;
            [_stateLock unlock];
            return NO;
        }
        memcpy(dst, (uint8_t *)slot->mapping.localAddress + pageOffset, chunkSize);

        dst += chunkSize;
        currentAddr += chunkSize;
        remaining -= chunkSize;
    }

    [_stateLock unlock];
    return YES;
}

- (uint64_t)readPointer:(uint64_t)address {
    if (address < 0x100000000 || address >= 0x1600000000) return 0;
    uint64_t value = 0;
    if (![self readMemory:address into:&value size:sizeof(value)])
        return 0;
    return value;
}

#pragma mark - Write (Aim transport)

- (void)unmapWriteSlot:(struct DSPageSlot *)slot {
    if (!slot->mapping.used) return;

    // Write slots are never registered in _pageLookup / _recentPageSlots, so
    // they must be released without touching the read-cache lookup tables.
    uint64_t mappingAddress = slot->mapping.mappingAddress
        ? slot->mapping.mappingAddress : slot->mapping.localAddress;
    uint64_t mappingSize = slot->mapping.mappingSize
        ? slot->mapping.mappingSize : DS_PAGE_SIZE;
    if (mappingAddress) {
        mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)mappingAddress, mappingSize);
    }
    if (slot->mapping.port) {
        mach_port_deallocate(mach_task_self(), (mach_port_t)slot->mapping.port);
    }
    memset(slot, 0, sizeof(*slot));
}

- (struct DSPageSlot *)lookupWriteSlot:(uint64_t)pageAddr {
    double now = [NSDate timeIntervalSinceReferenceDate];
    for (int i = 0; i < DS_WRITE_SLOT_COUNT; i++) {
        struct DSPageSlot *slot = &_writeSlots[i];
        if (slot->mapping.used && slot->mapping.remoteAddress == pageAddr) {
            if (now - slot->writeMappedAt > DS_WRITE_SLOT_MAX_AGE) {
                // The cached RW mapping is too old to trust: the remote page
                // may have been paged out and re-faulted elsewhere. Drop it
                // and let the caller build a fresh mapping.
                [self unmapWriteSlot:slot];
                return NULL;
            }
            slot->lastUse = ++_pageUseCounter;
            return slot;
        }
    }
    return NULL;
}

- (struct DSPageSlot *)mapWritePage:(uint64_t)pageAddr {
    struct DSPageSlot *slot = &_writeSlots[0];
    for (int i = 0; i < DS_WRITE_SLOT_COUNT; i++) {
        if (!_writeSlots[i].mapping.used) {
            slot = &_writeSlots[i];
            break;
        }
        if (_writeSlots[i].lastUse < slot->lastUse)
            slot = &_writeSlots[i];
    }
    if (slot->mapping.used)
        [self unmapWriteSlot:slot];

    // vm_map_remote_page (no _readonly suffix) maps the remote vm_object page
    // with VM_PROT_READ | VM_PROT_WRITE. Writes through the shared mapping
    // land on the live vm_page, so subsequent read-only cached reads stay
    // coherent because both mappings reference the same memory object.
    struct VMShmem shmem = vm_map_remote_page(_vmMapAddress, pageAddr);
    if (!shmem.used) return NULL;

    slot->mapping = shmem;
    slot->lastUse = ++_pageUseCounter;
    slot->writeMappedAt = [NSDate timeIntervalSinceReferenceDate];
    return slot;
}

- (BOOL)writeMemory:(uint64_t)address from:(const void *)buffer size:(size_t)size {
    if (!_ready || _shutDown || !buffer || size == 0) return NO;
    if (address < 0x100000000 || address >= 0x1600000000) return NO;
    if ((uint64_t)size > 0x100000ULL || address > UINT64_MAX - (uint64_t)size ||
        address + (uint64_t)size > 0x1600000000ULL) return NO;

    const uint8_t *src = (const uint8_t *)buffer;
    uint64_t remaining = size;
    uint64_t currentAddr = address;

    [_stateLock lock];

    while (remaining > 0) {
        uint64_t pageAddr = ds_page_align(currentAddr);
        uint64_t pageOffset = currentAddr & DS_PAGE_MASK;
        uint64_t chunkSize = DS_PAGE_SIZE - pageOffset;
        if (chunkSize > remaining)
            chunkSize = remaining;

        struct DSPageSlot *slot = [self lookupWriteSlot:pageAddr];
        if (!slot) slot = [self mapWritePage:pageAddr];

        if (!slot || !slot->mapping.localAddress) {
            [_stateLock unlock];
            return NO;
        }

        memcpy((uint8_t *)slot->mapping.localAddress + pageOffset, src, chunkSize);

        src += chunkSize;
        currentAddr += chunkSize;
        remaining -= chunkSize;
    }

    [_stateLock unlock];
    return YES;
}

- (uint64_t)findMainModuleBase {
    if (!_ready || _shutDown || !_vmMapAddress) return 0;

    NSNumber *cached = _moduleBaseCache[@"main"];
    if (cached) return cached.unsignedLongLongValue;

    __block uint64_t mainBase = 0;
    vm_map_iterate_entries(_vmMapAddress, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (start >= 0x100000000 && start < 0x1600000000) {
            struct mach_header_64 header = {0};
            if ([self readMemory:start into:&header size:sizeof(header)]) {
                if (header.magic == MH_MAGIC_64 && header.filetype == MH_EXECUTE &&
                    header.ncmds > 0 && header.ncmds < 256) {
                    mainBase = start;
                    *stop = YES;
                }
            }
        }
    });
    if (mainBase) _moduleBaseCache[@"main"] = @(mainBase);
    return mainBase;
}

- (uint64_t)findUnityFrameworkBase {
    if (!_ready || _shutDown || !_vmMapAddress) return 0;

    NSNumber *cached = _moduleBaseCache[@"unity"];
    if (cached) return cached.unsignedLongLongValue;

    __block uint64_t unityBase = 0;

    vm_map_iterate_entries(_vmMapAddress, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
        if (start >= 0x100000000 && start < 0x1600000000) {
            struct mach_header_64 header = {0};
            if ([self readMemory:start into:&header size:sizeof(header)]) {
                if (header.magic == MH_MAGIC_64 && header.filetype == MH_DYLIB &&
                    header.ncmds > 0 && header.ncmds < 256) {
                    uint64_t cmdOffset = start + sizeof(header);
                    uint64_t commandsEnd = cmdOffset + header.sizeofcmds;
                    if (commandsEnd < cmdOffset || commandsEnd > end) return;
                    for (uint32_t i = 0; i < header.ncmds; i++) {
                        uint32_t cmd = 0, cmdsize = 0;
                        if (![self readMemory:cmdOffset into:&cmd size:sizeof(cmd)] ||
                            ![self readMemory:cmdOffset + 4 into:&cmdsize size:sizeof(cmdsize)]) break;
                        if (cmdsize < 8 || cmdsize > 4096 || cmdOffset + cmdsize > commandsEnd) break;

                        if (cmd == 0xD /* LC_ID_DYLIB */) {
                            uint32_t strOffset = 0;
                            [self readMemory:cmdOffset + 8 into:&strOffset size:sizeof(strOffset)];
                            if (strOffset < cmdsize) {
                                char nameBuf[128] = {0};
                                if (![self readMemory:cmdOffset + strOffset into:nameBuf size:sizeof(nameBuf) - 1]) break;
                                if (strstr(nameBuf, "UnityFramework") != NULL) {
                                    unityBase = start;
                                    *stop = YES;
                                    return;
                                }
                            }
                            break;
                        }
                        cmdOffset += cmdsize;
                    }
                }
            }
        }
    });

    if (unityBase) _moduleBaseCache[@"unity"] = @(unityBase);
    return unityBase;
}

#pragma mark - Shutdown

- (void)shutdown {
    [_stateLock lock];
    _shutDown = YES;
    _ready = NO;

    for (int i = 0; i < DS_PAGE_SLOT_COUNT; i++)
        [self unmapSlot:&_pageSlots[i]];

    for (int i = 0; i < DS_WRITE_SLOT_COUNT; i++)
        [self unmapWriteSlot:&_writeSlots[i]];

    memset(_recentPageSlots, 0, sizeof(_recentPageSlots));
    memset(_pageLookup, 0, sizeof(_pageLookup));
    memset(_failedPages, 0, sizeof(_failedPages));
    [_moduleBaseCache removeAllObjects];

    _procAddress = 0;
    _taskAddress = 0;
    _vmMapAddress = 0;
    _pageUseCounter = 0;
    _consecutiveOperationalFailures = 0;
    _readTransactionDepth = 0;
    _transactionNewMapCount = 0;
    _readTransactionFailed = NO;

    printf("[DarkSwordMemoryProvider] shutdown complete\n");
    [_stateLock unlock];
}

- (void)dealloc {
    if (!_shutDown)
        [self shutdown];
}

#pragma mark - Diagnostics

- (uint64_t)diagnosticConsecutiveOperationalFailureCount {
    return _consecutiveOperationalFailures;
}

- (uint64_t)diagnosticModuleScanCount {
    return [_moduleBaseCache count];
}

- (BOOL)diagnosticIsDegraded {
    return _degraded;
}

- (BOOL)diagnosticCurrentTransactionFailed {
    return _readTransactionFailed;
}

@end
