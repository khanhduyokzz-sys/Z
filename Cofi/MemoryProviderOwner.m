#import "MemoryProviderOwner.h"
#import "DarkSwordMemoryProvider.h"

@implementation MemoryProviderOwner {
    id<MemoryProvider> _provider;
}

- (instancetype)initWithTargetProcessName:(NSString *)name {
    self = [super init];
    if (!self) return nil;

    _shutDown = NO;
    _stateLock = OS_UNFAIR_LOCK_INIT;
    _provider = [[DarkSwordMemoryProvider alloc] initWithTargetProcessName:name];

    return self;
}

- (id<MemoryProvider>)provider {
    os_unfair_lock_lock(&_stateLock);
    id<MemoryProvider> p = _provider;
    os_unfair_lock_unlock(&_stateLock);
    return p;
}

- (BOOL)ready {
    os_unfair_lock_lock(&_stateLock);
    BOOL r = !_shutDown && [_provider isReady];
    os_unfair_lock_unlock(&_stateLock);
    return r;
}

- (BOOL)isReady {
    return [self ready];
}

- (void)shutdown {
    os_unfair_lock_lock(&_stateLock);
    if (_shutDown) {
        os_unfair_lock_unlock(&_stateLock);
        return;
    }
    _shutDown = YES;
    id<MemoryProvider> p = _provider;
    os_unfair_lock_unlock(&_stateLock);

    [p shutdown];
}

- (void)dealloc {
    if (!_shutDown)
        [self shutdown];
}

@end
