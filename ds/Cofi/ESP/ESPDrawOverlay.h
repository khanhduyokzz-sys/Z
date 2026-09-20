#ifndef ESPDrawOverlay_h
#define ESPDrawOverlay_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "ESPDrawData.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef NS_ENUM(NSInteger, ESPDrawOverlayState) {
    ESPDrawOverlayStateIdle = 0,
    ESPDrawOverlayStateInitializing,
    ESPDrawOverlayStateRunning,
    ESPDrawOverlayStateStopping,
};

ESPDrawOverlayState esp_draw_overlay_state(void);
int esp_draw_overlay_initialize_in_session(void);
void esp_draw_overlay_stop_in_session(void);
void esp_draw_overlay_update_packet(const ESPDrawPacket *packet);
/** No-op; retained for ABI. Drawing is driven by esp_draw_overlay_update_packet. */
void esp_draw_overlay_tick(void);
void esp_draw_overlay_get_screen_size(float *widthOut, float *heightOut);

#ifdef __cplusplus
}
#endif

#endif /* ESPDrawOverlay_h */
