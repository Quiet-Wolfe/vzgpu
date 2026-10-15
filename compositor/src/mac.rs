//! FFI to src/mac.m (see mac.h).
#![allow(dead_code)]
use std::ffi::{c_char, c_void};

pub const EV_POINTER_MOTION: u32 = 1;
pub const EV_POINTER_BUTTON: u32 = 2;
pub const EV_POINTER_SCROLL: u32 = 3;
pub const EV_POINTER_LEAVE: u32 = 4;
pub const EV_KEY: u32 = 5;
pub const EV_FOCUS: u32 = 6;
pub const EV_CLOSE: u32 = 7;
pub const EV_RESIZE: u32 = 8;
pub const EV_FULLSCREEN: u32 = 9;
pub const EV_FRAME: u32 = 10;
pub const EV_QUIT: u32 = 11;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct VzEvent {
    pub kind: u32,
    pub window: u64,
    pub x: f64,
    pub y: f64,
    pub dx: f64,
    pub dy: f64,
    pub width: f64,
    pub height: f64,
    pub code: u32,
    pub state: u32,
    pub time_ms: u32,
    pub precise: u32,
    pub discrete_x: i32,
    pub discrete_y: i32,
}

pub type EventCb = extern "C" fn(*mut c_void, *const VzEvent);
pub type FdCb = extern "C" fn(*mut c_void);

extern "C" {
    pub fn vz_init(cb: EventCb, ctx: *mut c_void);
    pub fn vz_watch_fd(fd: i32, cb: FdCb, ctx: *mut c_void);
    pub fn vz_rearm_fd();
    pub fn vz_run();
    pub fn vz_terminate() -> !;
    pub fn vz_now_ms() -> u32;
    pub fn vz_main_screen(w: *mut f64, h: *mut f64, scale: *mut f64, hz: *mut f64);
    pub fn vz_app_become_regular(name: *const c_char);
    pub fn vz_app_set_icon(data: *const c_void, len: usize, label: *const c_char);
    pub fn vz_window_new(decorated: i32, w: f64, h: f64) -> u64;
    pub fn vz_popup_new(parent: u64, x: f64, y: f64, w: f64, h: f64) -> u64;
    pub fn vz_popup_move(popup: u64, x: f64, y: f64, w: f64, h: f64);
    pub fn vz_window_set_title(window: u64, title: *const c_char);
    pub fn vz_window_set_content_size(window: u64, w: f64, h: f64);
    pub fn vz_window_set_min_size(window: u64, w: f64, h: f64);
    pub fn vz_window_show(window: u64);
    pub fn vz_window_set_fullscreen(window: u64, on: i32);
    pub fn vz_window_set_maximized(window: u64, on: i32);
    pub fn vz_window_minimize(window: u64);
    pub fn vz_window_begin_move(window: u64);
    pub fn vz_window_begin_resize(window: u64, edges: u32);
    pub fn vz_window_destroy(window: u64);
    pub fn vz_window_set_surface_origin(window: u64, x: f64, y: f64);
    pub fn vz_layer_new(window: u64) -> u64;
    pub fn vz_layer_set_frame(layer: u64, x: f64, y: f64, w: f64, h: f64, z: i32);
    pub fn vz_layer_set_pixels(layer: u64, px: *const c_void, w: u32, h: u32, stride: u32, opaque: i32, scale: f64);
    pub fn vz_layer_clear(layer: u64);
    pub fn vz_layer_destroy(layer: u64);
    pub fn vz_cursor_set_named(name: *const c_char);
    pub fn vz_cursor_set_image(px: *const c_void, w: u32, h: u32, stride: u32, scale: f64, hx: f64, hy: f64);
    pub fn vz_cursor_hide();
}
