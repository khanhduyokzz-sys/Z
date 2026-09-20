#ifndef ESPMenuOverlay_h
#define ESPMenuOverlay_h

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, ESPMenuOverlayState) {
    ESPMenuOverlayStateIdle = 0,
    ESPMenuOverlayStateInitializing,
    ESPMenuOverlayStateRunning,
    ESPMenuOverlayStateStopping,
};

ESPMenuOverlayState esp_menu_overlay_state(void);
int esp_menu_overlay_initialize_in_session(void);
void esp_menu_overlay_stop_in_session(void);
void esp_menu_overlay_forget_remote_state(void);

void esp_menu_overlay_set_value_in_session(NSString *key, float value);
int esp_menu_overlay_poll_changes_in_session(void (^changeHandler)(NSString *key, float value));
void esp_menu_overlay_refresh_layout_in_session(void);

void esp_menu_apply_physical_visibility(BOOL visible);

#endif
