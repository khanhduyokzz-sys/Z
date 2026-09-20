#ifndef ESP_FRAME_BUILDER_H
#define ESP_FRAME_BUILDER_H

#import <Foundation/Foundation.h>
#import "../ESP/ESPDrawData.h"

/// Feeds the packet-based ESPDrawOverlay. Each tick this builder collects a
/// snapshot from the game, calibrates a camera projection, and fills an
/// ESPDrawPacket ready for the SpringBoard-hosted overlay to render.
@interface ESPFrameBuilder : NSObject

/// Builds one draw packet for the given canvas dimensions. Returns NO when
/// the snapshot or camera projection isn't ready yet — callers should treat a
/// NO result as "keep last packet" instead of clearing the overlay.
- (BOOL)buildDrawPacket:(ESPDrawPacket *)packet
             screenWidth:(float)screenWidth
            screenHeight:(float)screenHeight;

/// Drops any transient state (projection lock, coalesced pose smoothing).
- (void)reset;

@end

#endif /* ESP_FRAME_BUILDER_H */
