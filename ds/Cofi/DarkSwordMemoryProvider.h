#ifndef DarkSwordMemoryProvider_h
#define DarkSwordMemoryProvider_h

#import <Foundation/Foundation.h>
#import "MemoryProvider-Protocol.h"
#import "TaskRop/RemoteCall.h"

struct DSPageSlot {
    struct VMShmem mapping;
    uint64_t lastUse;
    double writeMappedAt;   // wall-clock time the RW mapping was created
};

struct DSFailedPageSlot {
    uint64_t pageAddress;
    double retryAfter;
    uint32_t failureCount;
};

#define DS_PAGE_SLOT_COUNT      256
#define DS_RECENT_SLOT_COUNT    8
#define DS_PAGE_LOOKUP_COUNT    512
#define DS_FAILED_PAGE_COUNT    128
#define DS_TRANSACTION_MAP_BUDGET 16
// While the Aim engine is armed its steering/prediction reads run inside the
// same transaction as the collector sweep; widen the budget so aim-critical
// pointer chains can never starve on cold pages at match start.
#define DS_TRANSACTION_MAP_BUDGET_AIM 28
// Write slots older than this are remapped so the game's own page churn
// (decommit / compressor reclaim / swap-in) can never leave the transport
// writing into a detached vm_page.
#define DS_WRITE_SLOT_MAX_AGE 1.0

// Small dedicated pool of READ|WRITE page mappings used by the Aim write
// transport. Kept separate from the read-only cache so a bulk read sweep can
// never evict a hot aim page, and so unwritable pages fail independently.
#define DS_WRITE_SLOT_COUNT     24

@interface DarkSwordMemoryProvider : NSObject <MemoryProvider> {
    NSString *_targetProcessName;
    uint64_t _procAddress;
    uint64_t _taskAddress;
    uint64_t _vmMapAddress;
    BOOL _ready;
    BOOL _shutDown;
    BOOL _degraded;
    NSRecursiveLock *_stateLock;
    NSMutableDictionary *_moduleBaseCache;
    struct DSPageSlot _pageSlots[DS_PAGE_SLOT_COUNT];
    struct DSPageSlot *_recentPageSlots[DS_RECENT_SLOT_COUNT];
    struct DSPageSlot *_pageLookup[DS_PAGE_LOOKUP_COUNT];
    struct DSFailedPageSlot _failedPages[DS_FAILED_PAGE_COUNT];
    struct DSPageSlot _writeSlots[DS_WRITE_SLOT_COUNT];
    uint64_t _pageUseCounter;
    uint64_t _consecutiveOperationalFailures;
    uint64_t _readTransactionDepth;
    uint32_t _transactionNewMapCount;
    BOOL _readTransactionFailed;
}

@property (readonly, nonatomic) uint64_t diagnosticConsecutiveOperationalFailureCount;
@property (readonly, nonatomic) uint64_t diagnosticModuleScanCount;
@property (readonly, nonatomic) BOOL diagnosticIsDegraded;
@property (readonly, nonatomic) BOOL diagnosticCurrentTransactionFailed;

- (instancetype)initWithTargetProcessName:(NSString *)name;
- (BOOL)isReady;
- (BOOL)beginReadTransaction;
- (void)endReadTransaction;
- (void)shutdown;

- (BOOL)readMemory:(uint64_t)address into:(void *)buffer size:(size_t)size;
- (uint64_t)readPointer:(uint64_t)address;
- (BOOL)writeMemory:(uint64_t)address from:(const void *)buffer size:(size_t)size;
- (uint64_t)findMainModuleBase;
- (uint64_t)findUnityFrameworkBase;

@end

#endif
