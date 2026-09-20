#ifndef ESPMenuRemoteEntry_h
#define ESPMenuRemoteEntry_h
#import <Foundation/Foundation.h>

@interface ESPMenuRemoteEntry : NSObject

@property (copy, nonatomic) NSString *key;
@property (copy, nonatomic) NSString *kind;
@property (nonatomic) unsigned long long control;
@property (nonatomic) unsigned long long valueLabel;
@property (nonatomic) unsigned long long dirtyIndex;
@property (nonatomic) long long itemCount;
@property (nonatomic) float minimumValue;
@property (nonatomic) float maximumValue;

@end

#endif
