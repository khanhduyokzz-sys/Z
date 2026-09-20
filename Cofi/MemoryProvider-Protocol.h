#ifndef MemoryProvider_Protocol_h
#define MemoryProvider_Protocol_h

#import <Foundation/Foundation.h>

@protocol MemoryProvider <NSObject>

@required

- (instancetype)initWithTargetProcessName:(NSString *)name;
- (BOOL)isReady;
- (void)shutdown;

@optional

- (BOOL)beginReadTransaction;
- (void)endReadTransaction;

@end

#endif
