//! One Wayland client, presented as one macOS app.
//!
//! Every xdg_toplevel becomes an NSWindow (native title bar when the client accepts
//! server-side decorations), every xdg_popup a borderless child window, and every
//! wl_surface a Core Animation layer. Shared-memory buffers are copied into IOSurfaces
//! on commit and released straight away, so the client can never overwrite a frame that
//! is on screen. Frame callbacks fire on the window's display link, i.e. at the
//! display's refresh rate.

use std::collections::{HashMap, VecDeque};
use std::cell::{Cell, RefCell};
use std::ffi::{c_void, CString};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::net::UnixStream;
use std::sync::Arc;

use smithay::input::keyboard::{FilterResult, Keycode, XkbConfig};
use smithay::input::pointer::{
    AxisFrame, ButtonEvent, CursorImageAttributes, CursorImageStatus, MotionEvent,
};
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::output::{Mode as OutputMode, Output, PhysicalProperties, Scale, Subpixel};
use smithay::reexports::wayland_protocols::xdg::decoration::zv1::server::zxdg_toplevel_decoration_v1::Mode as DecorationMode;
use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel;
use smithay::reexports::wayland_server::backend::{ClientData, ClientId, DisconnectReason, ObjectId};
use smithay::reexports::wayland_server::protocol::wl_callback::WlCallback;
use smithay::utils::Transform;
use smithay::backend::input::{Axis, AxisSource};
use smithay::reexports::wayland_server::protocol::wl_seat::WlSeat;
use smithay::reexports::wayland_server::protocol::wl_shm::Format;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::protocol::{wl_buffer, wl_output};
use smithay::reexports::wayland_server::{Client, Display, DisplayHandle, Resource};
use smithay::utils::{Rectangle, Serial, SERIAL_COUNTER};
use smithay::backend::input::{ButtonState, KeyState};
use smithay::backend::input::InputTime;
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{
    get_parent, send_surface_state, with_states, with_surface_tree_downward, BufferAssignment,
    CompositorClientState, CompositorHandler, CompositorState, SubsurfaceCachedState,
    SurfaceAttributes, TraversalAction,
};
use smithay::wayland::cursor_shape::CursorShapeManagerState;
use smithay::wayland::output::{OutputHandler, OutputManagerState};
use smithay::wayland::selection::data_device::{DataDeviceHandler, DataDeviceState, WaylandDndGrabHandler};
use smithay::input::dnd::{DndGrabHandler, GrabType, Source};
use smithay::wayland::selection::SelectionHandler;
use smithay::wayland::shell::xdg::decoration::{XdgDecorationHandler, XdgDecorationState};
use smithay::wayland::shell::xdg::{
    PopupSurface, PositionerState, SurfaceCachedState, ToplevelSurface, XdgShellHandler,
    XdgShellState, XdgToplevelSurfaceData,
};
use smithay::wayland::shm::{with_buffer_contents, ShmHandler, ShmState};

use crate::mac;

extern "C" {
    fn sys_dcache_flush(start: *mut c_void, len: usize);
}

#[derive(Clone)]
enum Role {
    Toplevel(ToplevelSurface),
    Popup(PopupSurface),
}

struct Win {
    role: Role,
    root: WlSurface,
    handle: u64,          // vz window, 0 until the first buffer maps it
    parent: Option<u64>,  // popups: the window they hang off
    origin: (i32, i32),   // xdg window geometry origin inside the root surface
    shown: bool,
    want_fullscreen: bool,
    resize_serial: Option<Serial>, // newest host size, until a root commit acknowledges it
}

struct SurfaceInfo {
    layer: u64,
    window: u64,
    size: (f64, f64),  // logical size of the current buffer
}

#[allow(dead_code)]  // the *_state fields keep their globals alive
pub struct App {
    dh: DisplayHandle,
    compositor_state: CompositorState,
    xdg_shell_state: XdgShellState,
    shm_state: ShmState,
    output_manager_state: OutputManagerState,
    seat_state: SeatState<App>,
    data_device_state: DataDeviceState,
    decoration_state: XdgDecorationState,
    cursor_shape_state: CursorShapeManagerState,
    seat: Seat<App>,
    output: Output,
    scale: f64,
    screen: (f64, f64),

    wins: HashMap<ObjectId, Win>,        // root surface -> window
    by_handle: HashMap<u64, ObjectId>,   // vz window -> root surface
    surfaces: HashMap<ObjectId, SurfaceInfo>,
    frames: Vec<(u64, WlCallback)>,      // (top-level vz window, callback)
    grab_popups: Vec<ObjectId>,          // popups holding a grab, innermost last
    focused: Option<u64>,
    cursor_surface: Option<WlSurface>,
    regular: bool,
}

#[derive(Default)]
pub struct ClientState {
    compositor: CompositorClientState,
}

impl ClientData for ClientState {
    fn initialized(&self, _: ClientId) {}
    fn disconnected(&self, _: ClientId, reason: DisconnectReason) {
        log!("client disconnected: {reason:?}");
        CLIENT_DISCONNECTED.with(|flag| flag.set(true));
    }
}

fn root_of(surface: &WlSurface) -> WlSurface {
    let mut root = surface.clone();
    while let Some(parent) = get_parent(&root) {
        root = parent;
    }
    root
}

fn cstr(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

impl App {
    fn new(dh: &DisplayHandle) -> Self {
        let (mut w, mut h, mut scale, mut hz) = (0.0, 0.0, 2.0, 60.0);
        unsafe { mac::vz_main_screen(&mut w, &mut h, &mut scale, &mut hz) };

        let mut seat_state = SeatState::new();
        let mut seat = seat_state.new_wl_seat(dh, "seat0");
        seat.add_keyboard(XkbConfig::default(), 400, 30).expect("xkb keymap");
        seat.add_pointer();

        let output = Output::new(
            "VZ-1".into(),
            PhysicalProperties {
                size: (0, 0).into(),
                subpixel: Subpixel::Unknown,
                make: "Apple".into(),
                model: "Display".into(),
                serial_number: String::new(),
            },
        );
        let mode = OutputMode {
            size: ((w * scale) as i32, (h * scale) as i32).into(),
            refresh: (hz * 1000.0) as i32,
        };
        output.change_current_state(
            Some(mode),
            Some(Transform::Normal),
            Some(Scale::Integer(scale.round() as i32)),
            Some((0, 0).into()),
        );
        output.set_preferred(mode);
        output.create_global::<App>(dh);
        log!("output {w}x{h} pt @{scale}x {hz} Hz");

        App {
            dh: dh.clone(),
            compositor_state: CompositorState::new::<App>(dh),
            xdg_shell_state: XdgShellState::new::<App>(dh),
            shm_state: ShmState::new::<App>(dh, vec![]),
            output_manager_state: OutputManagerState::new_with_xdg_output::<App>(dh),
            seat_state,
            data_device_state: DataDeviceState::new::<App>(dh),
            decoration_state: XdgDecorationState::new::<App>(dh),
            cursor_shape_state: CursorShapeManagerState::new::<App>(dh),
            seat,
            output,
            scale,
            screen: (w, h),
            wins: HashMap::new(),
            by_handle: HashMap::new(),
            surfaces: HashMap::new(),
            frames: Vec::new(),
            grab_popups: Vec::new(),
            focused: None,
            cursor_surface: None,
            regular: false,
        }
    }

    /// The toplevel window a window belongs to (itself, or a popup's ancestor).
    fn top_handle(&self, mut handle: u64) -> u64 {
        while let Some(win) = self.by_handle.get(&handle).and_then(|id| self.wins.get(id)) {
            match win.parent {
                Some(p) => handle = p,
                None => break,
            }
        }
        handle
    }

    // -- commits -----------------------------------------------------------------

    fn on_commit(&mut self, surface: &WlSurface) {
        if self.cursor_surface.as_ref() == Some(surface) {
            self.commit_cursor(surface);
            return;
        }
        let root = root_of(surface);
        let root_id = root.id();

        // xdg surfaces need a configure in response to their initial commit.
        if let Some(win) = self.wins.get(&root_id) {
            match &win.role {
                Role::Toplevel(t) if !t.is_initial_configure_sent() => {
                    t.with_pending_state(|s| {
                        s.bounds = Some((self.screen.0 as i32, self.screen.1 as i32).into());
                    });
                    t.send_configure();
                    return;
                }
                Role::Popup(p) if !p.is_initial_configure_sent() => {
                    let _ = p.send_configure();
                    return;
                }
                _ => {}
            }
        }

        let mut handle = self.wins.get(&root_id).map(|w| w.handle).unwrap_or(0);
        let (buffer, scale, callbacks) = with_states(surface, |states| {
            let mut guard = states.cached_state.get::<SurfaceAttributes>();
            let attrs = guard.current();
            (attrs.buffer.take(), attrs.buffer_scale.max(1), std::mem::take(&mut attrs.frame_callbacks))
        });

        match buffer {
            Some(BufferAssignment::NewBuffer(buffer)) => {
                if handle == 0 { handle = self.map_window(&root_id); }
                if handle != 0 {
                    self.upload(surface, handle, &buffer, scale);
                }
                buffer.release();
            }
            Some(BufferAssignment::Removed) => {
                if let Some(info) = self.surfaces.get(&surface.id()) {
                    unsafe { mac::vz_layer_clear(info.layer) };
                }
            }
            None => {}
        }

        let top = if handle != 0 { self.top_handle(handle) } else { 0 };
        for cb in callbacks {
            if top == 0 {
                cb.done(unsafe { mac::vz_now_ms() });
            } else {
                self.frames.push((top, cb));
            }
        }

        if self.wins.contains_key(&root_id) {
            self.layout(&root, surface == &root);
        }
    }

    fn upload(&mut self, surface: &WlSurface, handle: u64, buffer: &wl_buffer::WlBuffer, scale: i32) {
        let id = surface.id();
        let layer = match self.surfaces.get(&id) {
            Some(info) if info.window == handle => info.layer,
            _ => {
                let layer = unsafe { mac::vz_layer_new(handle) };
                self.output.enter(surface);
                with_states(surface, |states| {
                    send_surface_state(surface, states, self.scale.round() as i32, Transform::Normal)
                });
                self.surfaces.insert(id.clone(), SurfaceInfo { layer, window: handle, size: (0.0, 0.0) });
                layer
            }
        };
        let res = with_buffer_contents(buffer, |ptr, len, data| {
            let opaque = match data.format {
                Format::Argb8888 => false,
                Format::Xrgb8888 => true,
                other => {
                    log!("unsupported shm format {other:?}");
                    return None;
                }
            };
            let need = data.offset as usize + data.stride as usize * data.height as usize;
            if need > len {
                return None;
            }
            if std::env::var_os("VZCOMP_FLUSH").is_some() {
                // Experiment: drop stale cache lines for memory the guest wrote via the VM.
                unsafe { sys_dcache_flush(ptr.add(data.offset as usize) as *mut c_void, data.stride as usize * data.height as usize) };
            }
            unsafe {
                mac::vz_layer_set_pixels(
                    layer,
                    ptr.add(data.offset as usize) as *const c_void,
                    data.width as u32,
                    data.height as u32,
                    data.stride as u32,
                    opaque as i32,
                    scale as f64,
                );
            }
            if let Some(dir) = std::env::var_os("VZCOMP_DUMP") {
                // Dump the first 4 frames after every buffer size change.
                use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
                static DUMPED: AtomicU32 = AtomicU32::new(0);
                static LAST: AtomicU64 = AtomicU64::new(0);
                static LEFT: AtomicU32 = AtomicU32::new(0);
                let n = DUMPED.fetch_add(1, Ordering::Relaxed);
                let key = ((data.width as u64) << 32) | data.height as u64;
                if LAST.swap(key, Ordering::Relaxed) != key {
                    LEFT.store(4, Ordering::Relaxed);
                }
                if LEFT.load(Ordering::Relaxed) > 0 {
                    LEFT.fetch_sub(1, Ordering::Relaxed);
                    let bytes = unsafe { std::slice::from_raw_parts(ptr.add(data.offset as usize), (data.stride * data.height) as usize) };
                    let path = std::path::Path::new(&dir).join(format!("vzcomp-{}-{n}-{}x{}-s{}.raw", std::process::id(), data.width, data.height, data.stride));
                    let _ = std::fs::write(&path, bytes);
                }
            }
            if std::env::var_os("VZCOMP_DEBUG").is_some() {
                log!("upload {:?} {}x{} stride {} offset {} fmt {:?} scale {} pool {}", surface.id(), data.width, data.height, data.stride, data.offset, data.format, scale, len);
            }
            Some((data.width as f64 / scale as f64, data.height as f64 / scale as f64))
        });
        match res {
            Ok(Some(size)) => {
                if let Some(info) = self.surfaces.get_mut(&id) {
                    info.size = size;
                }
            }
            Ok(None) => {}
            Err(e) => log!("buffer not shm ({e:?}); only wl_shm is supported so far"),
        }
    }

    fn commit_cursor(&mut self, surface: &WlSurface) {
        let (buffer, scale, callbacks, hotspot) = with_states(surface, |states| {
            let mut guard = states.cached_state.get::<SurfaceAttributes>();
            let attrs = guard.current();
            let hot = states
                .data_map
                .get::<std::sync::Mutex<CursorImageAttributes>>()
                .map(|a| a.lock().unwrap().hotspot)
                .unwrap_or_default();
            (attrs.buffer.take(), attrs.buffer_scale.max(1), std::mem::take(&mut attrs.frame_callbacks), hot)
        });
        if let Some(BufferAssignment::NewBuffer(buffer)) = buffer {
            let _ = with_buffer_contents(&buffer, |ptr, _len, data| unsafe {
                if std::env::var_os("VZCOMP_DEBUG").is_some() {
                    log!("cursor {}x{} scale {} hotspot {:?}", data.width, data.height, scale, hotspot);
                }
                // Clients behind sommelier send 1x cursors (32 px at scale 1) even on a 2x
                // display, which macOS would show at twice the native cursor size. Show
                // cursor pixels at the display's scale; the hotspot scales with them.
                let shown = (scale as f64).max(self.scale);
                let k = scale as f64 / shown;
                mac::vz_cursor_set_image(
                    ptr.add(data.offset as usize) as *const c_void,
                    data.width as u32,
                    data.height as u32,
                    data.stride as u32,
                    shown,
                    hotspot.x as f64 * k,
                    hotspot.y as f64 * k,
                );
            });
            buffer.release();
        }
        for cb in callbacks {
            cb.done(unsafe { mac::vz_now_ms() });
        }
    }

    /// Creates the macOS window for an xdg surface on its first buffer.
    fn map_window(&mut self, root_id: &ObjectId) -> u64 {
        let Some(role) = self.wins.get(root_id).map(|w| w.role.clone()) else { return 0 };
        let handle = match &role {
            Role::Toplevel(t) => {
                let decorated = t.with_pending_state(|s| s.decoration_mode) == Some(DecorationMode::ServerSide);
                let (title, app_id) = with_states(t.wl_surface(), |states| {
                    let data = states.data_map.get::<XdgToplevelSurfaceData>().unwrap().lock().unwrap();
                    (data.title.clone(), data.app_id.clone())
                });
                // Become a regular app *before* the first window exists: windows created
                // by an accessory app float into whatever Space is active, including
                // another app's fullscreen Space.
                self.become_regular(app_id.as_deref(), title.as_deref());
                let h = unsafe { mac::vz_window_new(decorated as i32, 0.0, 0.0) };
                if let Some(title) = &title {
                    unsafe { mac::vz_window_set_title(h, cstr(title).as_ptr()) };
                }
                log!("map toplevel window {h} decorated={decorated} title={title:?} app_id={app_id:?}");
                h
            }
            Role::Popup(p) => {
                let parent = p.get_parent_surface().map(|s| root_of(&s).id());
                let parent_handle = parent.and_then(|id| self.wins.get(&id)).map(|w| w.handle).unwrap_or(0);
                if parent_handle == 0 {
                    return 0;
                }
                let geo = p.with_pending_state(|s| s.geometry);
                let h = unsafe {
                    mac::vz_popup_new(parent_handle, geo.loc.x as f64, geo.loc.y as f64, geo.size.w as f64, geo.size.h as f64)
                };
                self.wins.get_mut(root_id).unwrap().parent = Some(parent_handle);
                h
            }
        };
        let win = self.wins.get_mut(root_id).unwrap();
        win.handle = handle;
        self.by_handle.insert(handle, root_id.clone());
        handle
    }

    fn become_regular(&mut self, app_id: Option<&str>, title: Option<&str>) {
        if self.regular {
            return;
        }
        self.regular = true;
        let id = app_id.map(desktop_id);
        let exported = id.and_then(find_exported_app);
        let name = exported.as_ref().and_then(|e| e.name.clone()).unwrap_or_else(|| app_name(id, title));
        let icon = exported.as_ref().and_then(|e| e.icon.clone()).unwrap_or_default();
        log!("app {id:?} -> name {name:?}, icon {} bytes", icon.len());
        if let Some(id) = id {
            crate::handoff::register_running(&crate::default_socket(), id);
        }
        if let Some(want) = crate::handoff::expected_app() {
            // A launcher bundle: name and icon are the bundle's own.
            if id != Some(want) {
                log!("launcher for {want} got {id:?} (another app connected first)");
            }
            unsafe { mac::vz_app_become_regular(cstr(&name).as_ptr()) };
            return;
        }
        let n = cstr(&name);
        unsafe {
            mac::vz_app_become_regular(n.as_ptr());
            mac::vz_app_set_icon(icon.as_ptr() as *const _, icon.len(), n.as_ptr());
        }
    }

    /// Positions every surface layer of a window and sizes the window to the xdg geometry.
    fn layout(&mut self, root: &WlSurface, root_commit: bool) {
        let root_id = root.id();
        let Some(win) = self.wins.get(&root_id) else { return };
        let handle = win.handle;
        if handle == 0 {
            return;
        }
        let mut z = 0;
        let surfaces = &self.surfaces;
        with_surface_tree_downward(
            root,
            (0, 0),
            |_, states, &(x, y)| {
                let loc = if states.role == Some("subsurface") {
                    states.cached_state.get::<SubsurfaceCachedState>().current().location
                } else {
                    (0, 0).into()
                };
                TraversalAction::DoChildren((x + loc.x, y + loc.y))
            },
            |surface, states, &(x, y)| {
                let loc = if states.role == Some("subsurface") {
                    states.cached_state.get::<SubsurfaceCachedState>().current().location
                } else {
                    (0, 0).into()
                };
                if let Some(info) = surfaces.get(&surface.id()) {
                    unsafe {
                        mac::vz_layer_set_frame(
                            info.layer,
                            (x + loc.x) as f64,
                            (y + loc.y) as f64,
                            info.size.0,
                            info.size.1,
                            z,
                        )
                    };
                    z += 1;
                }
            },
            |_, _, _| true,
        );

        let root_size = self.surfaces.get(&root_id).map(|i| i.size).unwrap_or((0.0, 0.0));
        let (geometry, min_size) = with_states(root, |states| {
            let mut cached = states.cached_state.get::<SurfaceCachedState>();
            let c = cached.current();
            (c.geometry, c.min_size)
        });
        let geo = geometry.unwrap_or_else(|| {
            Rectangle::new((0, 0).into(), (root_size.0 as i32, root_size.1 as i32).into())
        });
        if std::env::var_os("VZCOMP_DEBUG").is_some() {
            log!("layout {:?} geometry {:?} root {:?} min {:?}", root_id, geometry, root_size, min_size);
        }
        let win = self.wins.get_mut(&root_id).unwrap();
        win.origin = (geo.loc.x, geo.loc.y);
        unsafe { mac::vz_window_set_surface_origin(handle, -geo.loc.x as f64, -geo.loc.y as f64) };
        match &win.role {
            Role::Toplevel(t) => unsafe {
                // Only a root commit responding to the latest host configure may
                // change the native size. Subsurface commits and older responses
                // must not undo a newer resize or replace its pending size.
                let committed = t.with_cached_state(|s| s.last_acked.as_ref().map(|c| c.serial));
                if !root_commit || !resize_caught_up(win.resize_serial, committed) {
                    return;
                }
                win.resize_serial = None;
                // The client may size itself (e.g. GTK growing for a new mode). Adopt its
                // size so later configures (focus changes) don't push a stale size back
                // and start a resize ping-pong. Fullscreen/maximized sizes stay ours.
                t.with_pending_state(|s| {
                    let ours = s.states.contains(xdg_toplevel::State::Fullscreen)
                        || s.states.contains(xdg_toplevel::State::Maximized);
                    if !ours && s.size.is_some() && geo.size.w > 0 && geo.size.h > 0 {
                        s.size = Some(geo.size);
                    }
                });
                if min_size.w > 0 || min_size.h > 0 {
                    mac::vz_window_set_min_size(handle, min_size.w as f64, min_size.h as f64);
                }
                mac::vz_window_set_content_size(handle, geo.size.w as f64, geo.size.h as f64);
            },
            Role::Popup(p) => {
                let pos = p.with_pending_state(|s| s.geometry);
                unsafe {
                    mac::vz_popup_move(handle, pos.loc.x as f64, pos.loc.y as f64, geo.size.w as f64, geo.size.h as f64)
                };
            }
        }
        if !win.shown && root_size.0 > 0.0 {
            win.shown = true;
            unsafe { mac::vz_window_show(handle) };
            if win.want_fullscreen {
                unsafe { mac::vz_window_set_fullscreen(handle, 1) };
            }
        }
    }

    fn destroy_window(&mut self, root_id: &ObjectId) {
        if let Some(win) = self.wins.remove(root_id) {
            if win.handle != 0 {
                self.by_handle.remove(&win.handle);
                self.frames.retain(|(h, _)| *h != win.handle);
                let layers: Vec<ObjectId> = self
                    .surfaces
                    .iter()
                    .filter(|(_, i)| i.window == win.handle)
                    .map(|(id, _)| id.clone())
                    .collect();
                for id in layers {
                    if let Some(info) = self.surfaces.remove(&id) {
                        unsafe { mac::vz_layer_destroy(info.layer) };
                    }
                }
                unsafe { mac::vz_window_destroy(win.handle) };
                if self.focused == Some(win.handle) {
                    self.focused = None;
                }
            }
        }
        self.grab_popups.retain(|id| id != root_id);
    }

    // -- input -------------------------------------------------------------------

    fn surface_at(&self, handle: u64, x: f64, y: f64) -> Option<(WlSurface, (f64, f64))> {
        let id = self.by_handle.get(&handle)?;
        let win = self.wins.get(id)?;
        Some((win.root.clone(), (x + win.origin.0 as f64, y + win.origin.1 as f64)))
    }

    fn pointer_to(&mut self, handle: u64, x: f64, y: f64, time: InputTime) {
        let pointer = self.seat.get_pointer().unwrap();
        let focus = self.surface_at(handle, x, y);
        let location = focus.as_ref().map(|(_, l)| *l).unwrap_or((x, y));
        let event = MotionEvent { location: location.into(), serial: SERIAL_COUNTER.next_serial(), time };
        pointer.motion(self, focus.map(|(s, _)| (s, (0.0, 0.0).into())), &event);
    }

    /// Keyboard focus goes to the innermost grabbing popup, else to the toplevel.
    fn focus_window(&mut self, handle: Option<u64>) {
        let keyboard = self.seat.get_keyboard().unwrap();
        let target = match handle {
            None => None,
            Some(h) => {
                let grab = self.grab_popups.last().and_then(|id| self.wins.get(id)).map(|w| w.root.clone());
                grab.or_else(|| self.by_handle.get(&h).and_then(|id| self.wins.get(id)).map(|w| w.root.clone()))
            }
        };
        let old = self.focused;
        self.focused = handle;
        for (h, active) in [(old, false), (handle, true)] {
            let Some(h) = h else { continue };
            if let Some(Role::Toplevel(t)) = self.by_handle.get(&h).and_then(|id| self.wins.get(id)).map(|w| w.role.clone()) {
                t.with_pending_state(|s| {
                    if active {
                        s.states.set(xdg_toplevel::State::Activated);
                    } else {
                        s.states.unset(xdg_toplevel::State::Activated);
                    }
                });
                if t.is_initial_configure_sent() {
                    t.send_pending_configure();
                }
            }
        }
        keyboard.set_focus(self, target, SERIAL_COUNTER.next_serial());
    }

    fn dismiss_popups(&mut self) {
        for id in std::mem::take(&mut self.grab_popups).into_iter().rev() {
            if let Some(Role::Popup(p)) = self.wins.get(&id).map(|w| w.role.clone()) {
                p.send_popup_done();
            }
        }
    }

    fn toplevel_of(&self, handle: u64) -> Option<ToplevelSurface> {
        match self.by_handle.get(&handle).and_then(|id| self.wins.get(id)).map(|w| &w.role) {
            Some(Role::Toplevel(t)) => Some(t.clone()),
            _ => None,
        }
    }

    fn configure_size(&mut self, handle: u64, w: f64, h: f64, fullscreen: Option<bool>) {
        if let Some(on) = fullscreen {
            log!("window {handle} {} native fullscreen at {w}x{h}", if on { "entered" } else { "left" });
        }
        if let Some(t) = self.toplevel_of(handle) {
            t.with_pending_state(|s| {
                s.size = Some((w.round() as i32, h.round() as i32).into());
                match fullscreen {
                    Some(true) => {
                        s.states.set(xdg_toplevel::State::Fullscreen);
                    }
                    Some(false) => {
                        s.states.unset(xdg_toplevel::State::Fullscreen);
                    }
                    None => {}
                }
            });
            if t.is_initial_configure_sent() {
                if let Some(serial) = t.send_pending_configure() {
                    if let Some(win) = self.wins.get_mut(&t.wl_surface().id()) {
                        win.resize_serial = Some(serial);
                    }
                }
            }
        }
    }

    pub fn handle_event(&mut self, ev: &mac::VzEvent) {
        let time = InputTime::from_millis(ev.time_ms);
        match ev.kind {
            mac::EV_POINTER_MOTION => {
                self.pointer_to(ev.window, ev.x, ev.y, time);
                self.seat.get_pointer().unwrap().frame(self);
            }
            mac::EV_POINTER_BUTTON => {
                let is_popup = self
                    .by_handle
                    .get(&ev.window)
                    .and_then(|id| self.wins.get(id))
                    .is_some_and(|w| matches!(w.role, Role::Popup(_)));
                if ev.state == 1 && !is_popup && !self.grab_popups.is_empty() {
                    // A click outside the open menus closes them (and is not delivered).
                    self.dismiss_popups();
                    return;
                }
                self.pointer_to(ev.window, ev.x, ev.y, time);
                let pointer = self.seat.get_pointer().unwrap();
                pointer.button(
                    self,
                    &ButtonEvent {
                        serial: SERIAL_COUNTER.next_serial(),
                        time,
                        button: ev.code,
                        state: if ev.state == 1 { ButtonState::Pressed } else { ButtonState::Released },
                    },
                );
                pointer.frame(self);
            }
            mac::EV_POINTER_SCROLL => {
                self.pointer_to(ev.window, ev.x, ev.y, time);
                let mut frame = AxisFrame::new(time).source(if ev.precise != 0 { AxisSource::Finger } else { AxisSource::Wheel });
                if ev.dx != 0.0 {
                    frame = frame.value(Axis::Horizontal, ev.dx);
                    if ev.discrete_x != 0 {
                        frame = frame.v120(Axis::Horizontal, ev.discrete_x * 120);
                    }
                }
                if ev.dy != 0.0 {
                    frame = frame.value(Axis::Vertical, ev.dy);
                    if ev.discrete_y != 0 {
                        frame = frame.v120(Axis::Vertical, ev.discrete_y * 120);
                    }
                }
                let pointer = self.seat.get_pointer().unwrap();
                pointer.axis(self, frame);
                pointer.frame(self);
            }
            mac::EV_POINTER_LEAVE => {
                let pointer = self.seat.get_pointer().unwrap();
                let event = MotionEvent { location: (0.0, 0.0).into(), serial: SERIAL_COUNTER.next_serial(), time };
                pointer.motion(self, None, &event);
                pointer.frame(self);
            }
            mac::EV_KEY => {
                let keyboard = self.seat.get_keyboard().unwrap();
                let state = if ev.state == 1 { KeyState::Pressed } else { KeyState::Released };
                if std::env::var_os("VZCOMP_DEBUG").is_some() {
                    log!("key {} {:?} focus={:?}", ev.code, state, self.focused);
                }
                keyboard.input::<(), _>(self, Keycode::new(ev.code + 8), state, SERIAL_COUNTER.next_serial(), time, |_, _, _| {
                    FilterResult::Forward
                });
            }
            mac::EV_FOCUS => {
                if ev.state == 1 {
                    self.focus_window(Some(ev.window));
                } else if self.focused == Some(ev.window) {
                    self.focus_window(None);
                }
            }
            mac::EV_CLOSE => {
                if let Some(t) = self.toplevel_of(ev.window) {
                    t.send_close();
                }
            }
            mac::EV_RESIZE => self.configure_size(ev.window, ev.width, ev.height, None),
            mac::EV_FULLSCREEN => self.configure_size(ev.window, ev.width, ev.height, Some(ev.state == 1)),
            mac::EV_FRAME => {
                let (due, rest): (Vec<_>, Vec<_>) = std::mem::take(&mut self.frames).into_iter().partition(|(h, _)| *h == ev.window);
                self.frames = rest;
                for (_, cb) in due {
                    cb.done(ev.time_ms);
                }
            }
            mac::EV_QUIT => {
                for win in self.wins.values() {
                    if let Role::Toplevel(t) = &win.role {
                        t.send_close();
                    }
                }
            }
            _ => {}
        }
    }
}

// Serial comparisons use Wayland's wrapping order, including across u32::MAX.
fn resize_caught_up(requested: Option<Serial>, committed: Option<Serial>) -> bool {
    requested.map_or(true, |want| committed.is_some_and(|got| got >= want))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nested_native_callback_is_deferred() {
        DISPATCHING.with(|active| active.set(true));
        let event: mac::VzEvent = unsafe { std::mem::zeroed() };
        dispatch(PendingEvent::Native(event));
        EVENTS.with(|events| {
            assert!(matches!(events.borrow_mut().pop_front(), Some(PendingEvent::Native(_))));
            assert!(events.borrow().is_empty());
        });
        DISPATCHING.with(|active| active.set(false));
    }

    #[test]
    fn resize_waits_for_latest_committed_configure() {
        assert!(resize_caught_up(None, None));
        assert!(!resize_caught_up(Some(20.into()), None));
        assert!(!resize_caught_up(Some(20.into()), Some(19.into())));
        assert!(resize_caught_up(Some(20.into()), Some(20.into())));
        assert!(resize_caught_up(Some(20.into()), Some(21.into())));
        assert!(!resize_caught_up(Some(1.into()), Some(u32::MAX.into())));
        assert!(resize_caught_up(Some(u32::MAX.into()), Some(1.into())));
    }
}

/// sommelier namespaces Wayland app_ids ("org.chromium.guest_os.termina.wayland.org.gnome.Calculator");
/// the guest's desktop id is what follows.
/// X11 windows (sommelier -X) without a forced --application-id arrive as
/// "org.chromium.<vm>.wmclass.<WM_CLASS>"; the WM_CLASS is what matches a .desktop file.
fn desktop_id(app_id: &str) -> &str {
    if let Some(id) = app_id.strip_prefix("org.chromium.guest_os.termina.wayland.") {
        return id;
    }
    if let Some(rest) = app_id.strip_prefix("org.chromium.") {
        if let Some((_, class)) = rest.split_once(".wmclass.") {
            return class;
        }
    }
    app_id
}

struct ExportedApp {
    name: Option<String>,
    icon: Option<Vec<u8>>,
}

/// Name and icon the guest published with vz-export-apps into the VMM's "vzgpu" share
/// (~/Library/Application Support/vzgpu/share/apps/<desktop-id>/{name,icon.svg|icon.png}).
fn find_exported_app(id: &str) -> Option<ExportedApp> {
    let home = std::env::var_os("HOME")?;
    let apps = std::path::Path::new(&home).join("Library/Application Support/vzgpu/share/apps");
    let dir = if apps.join(id).is_dir() {
        apps.join(id)
    } else {
        // app_ids don't always match the .desktop name: try case-insensitive, then the last
        // dotted component (app_id "gnome-calculator" vs org.gnome.Calculator.desktop).
        let lower = id.to_lowercase();
        let last = |s: &str| s.rsplit('.').next().unwrap_or(s).to_lowercase();
        let entries: Vec<String> = std::fs::read_dir(&apps).ok()?
            .filter_map(|e| e.ok()?.file_name().into_string().ok()).collect();
        let hit = entries.iter().find(|e| e.to_lowercase() == lower)
            .or_else(|| entries.iter().find(|e| last(e) == last(&lower)))?;
        apps.join(hit)
    };
    let name = std::fs::read_to_string(dir.join("name")).ok()
        .map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
    let icon = std::fs::read(dir.join("icon.svg")).or_else(|_| std::fs::read(dir.join("icon.png"))).ok();
    Some(ExportedApp { name, icon })
}

/// "org.gnome.Calculator" -> "Calculator"; falls back to the title.
fn app_name(app_id: Option<&str>, title: Option<&str>) -> String {
    if let Some(id) = app_id.filter(|s| !s.is_empty()) {
        let last = id.rsplit('.').next().unwrap_or(id);
        let mut c = last.chars();
        return match c.next() {
            Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
            None => id.to_string(),
        };
    }
    title.filter(|s| !s.is_empty()).unwrap_or("Linux App").to_string()
}

// -- Smithay handlers ----------------------------------------------------------------

impl CompositorHandler for App {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor_state
    }
    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        &client.get_data::<ClientState>().unwrap().compositor
    }
    fn commit(&mut self, surface: &WlSurface) {
        self.on_commit(surface);
    }
}

impl BufferHandler for App {
    fn buffer_destroyed(&mut self, _buffer: &wl_buffer::WlBuffer) {}
}

impl ShmHandler for App {
    fn shm_state(&self) -> &ShmState {
        &self.shm_state
    }
}

impl XdgShellHandler for App {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell_state
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let root = surface.wl_surface().clone();
        self.wins.insert(
            root.id(),
            Win { role: Role::Toplevel(surface), root, handle: 0, parent: None, origin: (0, 0), shown: false, want_fullscreen: false, resize_serial: None },
        );
    }

    fn new_popup(&mut self, surface: PopupSurface, positioner: PositionerState) {
        surface.with_pending_state(|s| {
            s.geometry = positioner.get_geometry();
            s.positioner = positioner;
        });
        let root = surface.wl_surface().clone();
        self.wins.insert(
            root.id(),
            Win { role: Role::Popup(surface), root, handle: 0, parent: None, origin: (0, 0), shown: false, want_fullscreen: false, resize_serial: None },
        );
    }

    fn reposition_request(&mut self, surface: PopupSurface, positioner: PositionerState, token: u32) {
        surface.with_pending_state(|s| {
            s.geometry = positioner.get_geometry();
            s.positioner = positioner;
        });
        surface.send_repositioned(token);
        let _ = surface.send_configure();
    }

    fn grab(&mut self, surface: PopupSurface, _seat: WlSeat, _serial: Serial) {
        self.grab_popups.push(surface.wl_surface().id());
        let keyboard = self.seat.get_keyboard().unwrap();
        keyboard.set_focus(self, Some(surface.wl_surface().clone()), SERIAL_COUNTER.next_serial());
    }

    fn move_request(&mut self, surface: ToplevelSurface, _seat: WlSeat, _serial: Serial) {
        if let Some(h) = self.wins.get(&surface.wl_surface().id()).map(|w| w.handle) {
            unsafe { mac::vz_window_begin_move(h) };
        }
    }

    fn resize_request(&mut self, surface: ToplevelSurface, _seat: WlSeat, _serial: Serial, edges: xdg_toplevel::ResizeEdge) {
        if let Some(h) = self.wins.get(&surface.wl_surface().id()).map(|w| w.handle) {
            unsafe { mac::vz_window_begin_resize(h, u32::from(edges)) };
        }
    }

    fn fullscreen_request(&mut self, surface: ToplevelSurface, _output: Option<wl_output::WlOutput>) {
        log!("client: set_fullscreen");
        if let Some(win) = self.wins.get_mut(&surface.wl_surface().id()) {
            win.want_fullscreen = true;
            if win.handle != 0 && win.shown {
                unsafe { mac::vz_window_set_fullscreen(win.handle, 1) };
            } else {
                // Not mapped yet: configure it fullscreen-sized now; the window enters a
                // fullscreen Space as soon as it maps.
                surface.with_pending_state(|s| {
                    s.states.set(xdg_toplevel::State::Fullscreen);
                    s.size = Some((self.screen.0 as i32, self.screen.1 as i32).into());
                });
                if surface.is_initial_configure_sent() {
                    surface.send_pending_configure();
                }
            }
        }
    }

    fn unfullscreen_request(&mut self, surface: ToplevelSurface) {
        log!("client: unset_fullscreen");
        if let Some(win) = self.wins.get_mut(&surface.wl_surface().id()) {
            win.want_fullscreen = false;
            if win.handle != 0 {
                unsafe { mac::vz_window_set_fullscreen(win.handle, 0) };
            }
        }
    }

    fn maximize_request(&mut self, surface: ToplevelSurface) {
        if let Some(h) = self.wins.get(&surface.wl_surface().id()).map(|w| w.handle).filter(|h| *h != 0) {
            surface.with_pending_state(|s| {
                s.states.set(xdg_toplevel::State::Maximized);
            });
            unsafe { mac::vz_window_set_maximized(h, 1) };
            surface.send_pending_configure();
        }
    }

    fn unmaximize_request(&mut self, surface: ToplevelSurface) {
        if let Some(h) = self.wins.get(&surface.wl_surface().id()).map(|w| w.handle).filter(|h| *h != 0) {
            surface.with_pending_state(|s| {
                s.states.unset(xdg_toplevel::State::Maximized);
            });
            unsafe { mac::vz_window_set_maximized(h, 0) };
            surface.send_pending_configure();
        }
    }

    fn minimize_request(&mut self, surface: ToplevelSurface) {
        if let Some(h) = self.wins.get(&surface.wl_surface().id()).map(|w| w.handle).filter(|h| *h != 0) {
            unsafe { mac::vz_window_minimize(h) };
        }
    }

    fn title_changed(&mut self, surface: ToplevelSurface) {
        let title = with_states(surface.wl_surface(), |states| {
            states.data_map.get::<XdgToplevelSurfaceData>().unwrap().lock().unwrap().title.clone()
        });
        if let (Some(h), Some(title)) = (self.wins.get(&surface.wl_surface().id()).map(|w| w.handle).filter(|h| *h != 0), title) {
            unsafe { mac::vz_window_set_title(h, cstr(&title).as_ptr()) };
        }
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        self.destroy_window(&surface.wl_surface().id());
    }

    fn popup_destroyed(&mut self, surface: PopupSurface) {
        let id = surface.wl_surface().id();
        let had_grab = self.grab_popups.contains(&id);
        self.destroy_window(&id);
        if had_grab {
            let f = self.focused;
            self.focus_window(f);
        }
    }
}

impl XdgDecorationHandler for App {
    fn new_decoration(&mut self, toplevel: ToplevelSurface) {
        toplevel.with_pending_state(|s| s.decoration_mode = Some(DecorationMode::ServerSide));
        if toplevel.is_initial_configure_sent() {
            toplevel.send_pending_configure();
        }
    }
    fn request_mode(&mut self, toplevel: ToplevelSurface, mode: DecorationMode) {
        toplevel.with_pending_state(|s| s.decoration_mode = Some(mode));
        if toplevel.is_initial_configure_sent() {
            toplevel.send_pending_configure();
        }
    }
    fn unset_mode(&mut self, toplevel: ToplevelSurface) {
        toplevel.with_pending_state(|s| s.decoration_mode = Some(DecorationMode::ServerSide));
        if toplevel.is_initial_configure_sent() {
            toplevel.send_pending_configure();
        }
    }
}

impl SeatHandler for App {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<App> {
        &mut self.seat_state
    }

    fn cursor_image(&mut self, _seat: &Seat<Self>, image: CursorImageStatus) {
        match image {
            CursorImageStatus::Hidden => {
                self.cursor_surface = None;
                unsafe { mac::vz_cursor_hide() };
            }
            CursorImageStatus::Named(icon) => {
                self.cursor_surface = None;
                unsafe { mac::vz_cursor_set_named(cstr(icon.name()).as_ptr()) };
            }
            CursorImageStatus::Surface(surface) => {
                self.cursor_surface = Some(surface.clone());
                self.commit_cursor(&surface);
            }
        }
    }

    fn focus_changed(&mut self, seat: &Seat<Self>, focused: Option<&WlSurface>) {
        let client = focused.and_then(|s| self.dh.get_client(s.id()).ok());
        smithay::wayland::selection::data_device::set_data_device_focus(&self.dh, seat, client);
    }
}

impl SelectionHandler for App {
    type SelectionUserData = ();
}

impl DataDeviceHandler for App {
    fn data_device_state(&mut self) -> &mut DataDeviceState {
        &mut self.data_device_state
    }
}

impl DndGrabHandler for App {}
impl WaylandDndGrabHandler for App {
    fn dnd_requested<S: Source>(&mut self, source: S, _icon: Option<WlSurface>, _seat: Seat<Self>, _serial: Serial, _type: GrabType) {
        source.cancel();  // drag and drop between Linux and macOS is not wired up yet
    }
}

impl OutputHandler for App {}
impl smithay::wayland::pointer_constraints::PointerConstraintsHandler for App {}
impl smithay::input::tablet::TabletSeatHandler for App {
    type ToolFocus = WlSurface;
}

smithay::delegate_dispatch2!(App);

// -- runtime ----------------------------------------------------------------------

pub struct Runtime {
    display: Display<App>,
    pub app: App,
}

pub static mut RUNTIME: *mut Runtime = std::ptr::null_mut();

fn runtime() -> &'static mut Runtime {
    unsafe { &mut *RUNTIME }
}

// AppKit can synchronously call delegates while Rust is laying out a window,
// and can run a nested event loop during a native drag. Defer those callbacks
// until the active operation returns instead of aliasing &mut Runtime/App.
enum PendingEvent {
    Native(mac::VzEvent),
    Readable,
}

thread_local! {
    static DISPATCHING: Cell<bool> = const { Cell::new(false) };
    static EVENTS: RefCell<VecDeque<PendingEvent>> = const { RefCell::new(VecDeque::new()) };
    static CLIENT_DISCONNECTED: Cell<bool> = const { Cell::new(false) };
}

fn dispatch(event: PendingEvent) {
    EVENTS.with(|events| events.borrow_mut().push_back(event));
    if DISPATCHING.with(|active| active.replace(true)) {
        return;
    }
    loop {
        let Some(event) = EVENTS.with(|events| events.borrow_mut().pop_front()) else { break };
        let rt = runtime();
        match event {
            PendingEvent::Native(ev) => rt.app.handle_event(&ev),
            PendingEvent::Readable => {
                if let Err(e) = rt.display.dispatch_clients(&mut rt.app) {
                    log!("dispatch: {e}");
                }
                unsafe { mac::vz_rearm_fd() };
            }
        }
        rt.flush();
    }
    DISPATCHING.with(|active| active.set(false));
}

extern "C" fn on_event(_ctx: *mut c_void, ev: *const mac::VzEvent) {
    dispatch(PendingEvent::Native(unsafe { *ev }));
}

extern "C" fn on_wayland_readable(_ctx: *mut c_void) {
    dispatch(PendingEvent::Readable);
}

impl Runtime {
    fn flush(&mut self) {
        let _ = self.display.flush_clients();
        if CLIENT_DISCONNECTED.with(|flag| flag.get()) {
            if crate::handoff::expected_app().is_some() && !self.app.regular {
                crate::handoff::reclaim();
            }
            log!("client gone; exiting");
            unsafe { mac::vz_terminate() };
        }
    }
}

/// Serves a single already-connected Wayland client on `fd` until it disconnects.
pub fn run_client(fd: i32) -> ! {
    unsafe { mac::vz_init(on_event, std::ptr::null_mut()) };
    let display: Display<App> = Display::new().expect("wayland display");
    let dh = display.handle();
    let app = App::new(&dh);
    let rt = Box::new(Runtime { display, app });
    unsafe { RUNTIME = Box::into_raw(rt) };
    let rt = runtime();

    let stream = unsafe { UnixStream::from_raw_fd(fd) };
    rt.display.handle().insert_client(stream, Arc::new(ClientState::default())).expect("insert client");
    let poll_fd = rt.display.backend().poll_fd().as_raw_fd();
    unsafe {
        mac::vz_watch_fd(poll_fd, on_wayland_readable, std::ptr::null_mut());
        mac::vz_run();
    }
    std::process::exit(0);
}
