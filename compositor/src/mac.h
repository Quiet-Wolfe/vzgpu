// macOS side of vzcomp: AppKit windows, Core Animation layers backed by IOSurfaces,
// display-link frame ticks, and input translated to Linux evdev codes.
// Called only from the main thread.
#pragma once
#include <stddef.h>
#include <stdint.h>

enum vz_event_type {
    VZ_EV_POINTER_MOTION = 1,  // window, x, y (content points, top-left origin)
    VZ_EV_POINTER_BUTTON,      // window, x, y, code (BTN_*), state
    VZ_EV_POINTER_SCROLL,      // window, dx, dy (points; +dy = scroll down), discrete, precise
    VZ_EV_POINTER_LEAVE,       // window
    VZ_EV_KEY,                 // window, code (KEY_*), state
    VZ_EV_FOCUS,               // window, state (1 = became key)
    VZ_EV_CLOSE,               // window (close button / Cmd-W)
    VZ_EV_RESIZE,              // window, width, height (content points)
    VZ_EV_FULLSCREEN,          // window, state, width, height
    VZ_EV_FRAME,               // window, time_ms (display link tick)
    VZ_EV_QUIT,                // Cmd-Q / Dock quit: close every toplevel
};

struct vz_event {
    uint32_t type;
    uint64_t window;
    double x, y;
    double dx, dy;
    double width, height;
    uint32_t code;
    uint32_t state;
    uint32_t time_ms;
    uint32_t precise;
    int32_t discrete_x, discrete_y;
};

typedef void (*vz_event_cb)(void *ctx, const struct vz_event *ev);
typedef void (*vz_fd_cb)(void *ctx);

void vz_init(vz_event_cb cb, void *ctx);
void vz_watch_fd(int fd, vz_fd_cb cb, void *ctx);
void vz_rearm_fd(void);
void vz_run(void);
void vz_terminate(void);
uint32_t vz_now_ms(void);

// Main screen: size in points, backing scale, refresh rate (Hz).
void vz_main_screen(double *width, double *height, double *scale, double *refresh_hz);

// Dock presence: regular (Dock icon, menu bar) once a window maps; name shown in the menu.
void vz_app_become_regular(const char *name);
// Icon: PNG/ICNS/SVG bytes, or NULL to draw a placeholder from `label`.
void vz_app_set_icon(const void *data, size_t len, const char *label);

// Windows. `decorated` = native title bar (server-side decorations).
uint64_t vz_window_new(int decorated, double width, double height);
uint64_t vz_popup_new(uint64_t parent, double x, double y, double width, double height);
void vz_popup_move(uint64_t popup, double x, double y, double width, double height);
void vz_window_set_title(uint64_t window, const char *title);
void vz_window_set_content_size(uint64_t window, double width, double height);
void vz_window_set_min_size(uint64_t window, double width, double height);
void vz_window_show(uint64_t window);
void vz_window_set_fullscreen(uint64_t window, int fullscreen);
void vz_window_set_maximized(uint64_t window, int maximized);
void vz_window_minimize(uint64_t window);
void vz_window_begin_move(uint64_t window);
void vz_window_begin_resize(uint64_t window, uint32_t edges);  // xdg_toplevel resize_edge
void vz_window_destroy(uint64_t window);
// Offset of the surface origin inside the window (negative of the xdg window geometry origin).
void vz_window_set_surface_origin(uint64_t window, double x, double y);

// Layers: one per wl_surface, flat inside the window, ordered by z.
uint64_t vz_layer_new(uint64_t window);
void vz_layer_set_frame(uint64_t layer, double x, double y, double width, double height, int z);
// Copies pixels (BGRA/BGRX little-endian, i.e. wl_shm ARGB8888/XRGB8888) into an
// immutable IOSurface and shows it. `scale` = buffer scale.
void vz_layer_set_pixels(uint64_t layer, const void *pixels, uint32_t width, uint32_t height,
                         uint32_t stride, int opaque, double scale);
void vz_layer_clear(uint64_t layer);
void vz_layer_destroy(uint64_t layer);

// Cursor: a CSS/xcursor name ("default", "text", "pointer", ...), or hidden.
void vz_cursor_set_named(const char *name);
void vz_cursor_set_image(const void *pixels, uint32_t width, uint32_t height, uint32_t stride,
                         double scale, double hot_x, double hot_y);
void vz_cursor_hide(void);
