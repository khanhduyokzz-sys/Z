#ifndef MemoryProviderOwner_h
#define MemoryProviderOwner_h

#import <Foundation/Foundation.h>
#import <os/lock.h>
#import "MemoryProvider-Protocol.h"

@interface MemoryProviderOwner : NSObject {
    BOOL _shutDown;
    os_unfair_lock _stateLock;
}

@property (readonly, nonatomic) id<MemoryProvider> provider;
@property (readonly, nonatomic) BOOL ready;

- (instancetype)initWithTargetProcessName:(NSString *)name;
- (BOOL)isReady;
- (void)shutdown;

@end

#endif
