#include <dlfcn.h>
// macOS side of vzcomp. See mac.h.
//
// Each Wayland surface is a CALayer whose contents is an IOSurface. On every commit
// the pixels are copied into a new, immutable IOSurface. Core Animation retains it
// through presentation; neither pending nor displayed frames are ever overwritten.
// The Wayland buffer can then be released immediately.

#import <AppKit/AppKit.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach_time.h>

#include "mac.h"

static vz_event_cb g_cb;
static void *g_ctx;
static uint64_t g_next_handle = 1;
static NSMutableDictionary<NSNumber *, id> *g_objects;  // handle -> VZWindowCtl / VZLayer
static NSCursor *g_cursor;
static BOOL g_cursor_hidden;

static void emit(struct vz_event ev) {
    if (g_cb)
        g_cb(g_ctx, &ev);
}

uint32_t vz_now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom)
        mach_timebase_info(&tb);
    return (uint32_t)(mach_absolute_time() * tb.numer / tb.denom / 1000000);
}

static uint64_t put(id obj) {
    uint64_t h = g_next_handle++;
    g_objects[@(h)] = obj;
    return h;
}

#pragma mark keycodes

// macOS virtual keycode -> Linux evdev keycode (input-event-codes.h).
static uint32_t evdev_from_mac(unsigned short k) {
    static const uint16_t table[128] = {
        [0x00] = 30,  [0x01] = 31,  [0x02] = 32,  [0x03] = 33,  [0x04] = 35,  [0x05] = 34,
        [0x06] = 44,  [0x07] = 45,  [0x08] = 46,  [0x09] = 47,  [0x0A] = 86,  [0x0B] = 48,
        [0x0C] = 16,  [0x0D] = 17,  [0x0E] = 18,  [0x0F] = 19,  [0x10] = 21,  [0x11] = 20,
        [0x12] = 2,   [0x13] = 3,   [0x14] = 4,   [0x15] = 5,   [0x16] = 7,   [0x17] = 6,
        [0x18] = 13,  [0x19] = 10,  [0x1A] = 8,   [0x1B] = 12,  [0x1C] = 9,   [0x1D] = 11,
        [0x1E] = 27,  [0x1F] = 24,  [0x20] = 22,  [0x21] = 26,  [0x22] = 23,  [0x23] = 25,
        [0x24] = 28,  [0x25] = 38,  [0x26] = 36,  [0x27] = 40,  [0x28] = 37,  [0x29] = 39,
        [0x2A] = 43,  [0x2B] = 51,  [0x2C] = 53,  [0x2D] = 49,  [0x2E] = 50,  [0x2F] = 52,
        [0x30] = 15,  [0x31] = 57,  [0x32] = 41,  [0x33] = 14,  [0x35] = 1,   [0x36] = 126,
        [0x37] = 125, [0x38] = 42,  [0x39] = 58,  [0x3A] = 56,  [0x3B] = 29,  [0x3C] = 54,
        [0x3D] = 100, [0x3E] = 97,  [0x40] = 187, [0x41] = 83,  [0x43] = 55,  [0x45] = 78,
        [0x47] = 69,  [0x4B] = 98,  [0x4C] = 96,  [0x4E] = 74,  [0x4F] = 188, [0x50] = 189,
        [0x51] = 117, [0x52] = 82,  [0x53] = 79,  [0x54] = 80,  [0x55] = 81,  [0x56] = 75,
        [0x57] = 76,  [0x58] = 77,  [0x59] = 71,  [0x5A] = 190, [0x5B] = 72,  [0x5C] = 73,
        [0x5D] = 124, [0x5E] = 89,  [0x5F] = 121, [0x60] = 63,  [0x61] = 64,  [0x62] = 65,
        [0x63] = 61,  [0x64] = 66,  [0x65] = 87,  [0x66] = 94,  [0x67] = 88,  [0x68] = 92,
        [0x69] = 183, [0x6A] = 186, [0x6B] = 70,  [0x6D] = 68,  [0x6E] = 127, [0x6F] = 87,
        [0x71] = 119, [0x72] = 110, [0x73] = 102, [0x74] = 104, [0x75] = 111, [0x76] = 62,
        [0x77] = 107, [0x78] = 60,  [0x79] = 109, [0x7A] = 59,  [0x7B] = 105, [0x7C] = 106,
        [0x7D] = 108, [0x7E] = 103,
    };
    return k < 128 ? table[k] : 0;
}

#pragma mark layers

@interface VZLayer : NSObject
@property(strong) CALayer *layer;
@property uint64_t window;
@property(strong) id pendingContents;
@property CGRect pendingFrame;
@property CGFloat pendingScale;
@property BOOL pendingOpaque;
@property int pendingZ;
@property BOOL pixelsDirty, frameDirty;
@end
@implementation VZLayer
@end

static IOSurfaceRef make_surface(uint32_t w, uint32_t h) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth : @(w),
        (id)kIOSurfaceHeight : @(h),
        (id)kIOSurfaceBytesPerElement : @4,
        (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA'),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)props);
}

#pragma mark views and windows

@class VZWindowCtl;

@interface VZView : NSView
@property(weak) VZWindowCtl *ctl;
@property(strong) CALayer *surfaces;  // container for surface layers, offset by the surface origin
@property(strong) CADisplayLink *link;
@property uint32_t resizeEdges;
@property NSRect resizeStartFrame;
@property NSPoint resizeStartMouse;
@property(strong) NSEvent *lastMouseDown;
@end

@interface VZWindow : NSWindow
@property BOOL isPopup;
@end
@implementation VZWindow
- (BOOL)canBecomeKeyWindow {
    return !self.isPopup;
}
- (BOOL)canBecomeMainWindow {
    return !self.isPopup;
}
@end

@interface VZWindowCtl : NSObject <NSWindowDelegate>
@property uint64_t handle;
@property(strong) VZWindow *window;
@property(strong) VZView *view;
@property BOOL programmaticResize;
@property BOOL fullscreen;
@property CGPoint pendingOrigin;
@property NSSize pendingSize;
@property BOOL originDirty, sizeDirty;
@property NSRect restoreFrame;  // borderless maximize: frame to restore
@end

static void present_window(uint64_t window);

// Modifier state as the client last saw it. Reconciled against every key event's own
// flags: synthetic keystrokes and app switches don't always produce flagsChanged, which
// would otherwise leave Ctrl/Alt missing or stuck.
static NSEventModifierFlags g_sent_mods;
static void sync_mods(uint64_t window, NSEventModifierFlags want) {
    static const struct { NSEventModifierFlags flag; uint32_t code; } mods[] = {
        {NSEventModifierFlagShift, 42}, {NSEventModifierFlagControl, 29},
        {NSEventModifierFlagOption, 56}, {NSEventModifierFlagCommand, 125},
    };
    for (size_t i = 0; i < sizeof mods / sizeof *mods; i++) {
        BOOL have = (g_sent_mods & mods[i].flag) != 0, need = (want & mods[i].flag) != 0;
        if (have == need)
            continue;
        struct vz_event ev = {.type = VZ_EV_KEY, .window = window, .code = mods[i].code, .state = need,
                              .time_ms = vz_now_ms()};
        emit(ev);
        g_sent_mods ^= mods[i].flag;
    }
}
void vz_release_modifiers(uint64_t window) {
    sync_mods(window, 0);
}
@implementation VZView
- (BOOL)isFlipped {
    return YES;
}
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
    return YES;
}
- (BOOL)wantsUpdateLayer {
    return YES;
}
- (void)updateTrackingAreas {
    for (NSTrackingArea *a in self.trackingAreas)
        [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc]
                              initWithRect:self.bounds
                                   options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                           NSTrackingActiveAlways | NSTrackingCursorUpdate |
                                           NSTrackingInVisibleRect
                                     owner:self
                                  userInfo:nil]];
    [super updateTrackingAreas];
}
- (void)cursorUpdate:(NSEvent *)e {
    [g_cursor ?: NSCursor.arrowCursor set];
}
- (void)tick:(CADisplayLink *)link {
    present_window(self.ctl.handle);
    struct vz_event ev = {.type = VZ_EV_FRAME, .window = self.ctl.handle, .time_ms = vz_now_ms()};
    emit(ev);
}
- (struct vz_event)pointerEvent:(uint32_t)type at:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    struct vz_event ev = {.type = type, .window = self.ctl.handle, .x = p.x, .y = p.y, .time_ms = vz_now_ms()};
    return ev;
}
- (void)motion:(NSEvent *)e {
    if (self.resizeEdges) {
        [self continueResize];
        return;
    }
    emit([self pointerEvent:VZ_EV_POINTER_MOTION at:e]);
    if (g_cursor && !g_cursor_hidden)
        [g_cursor set];
}
- (void)mouseMoved:(NSEvent *)e {
    [self motion:e];
}
- (void)mouseDragged:(NSEvent *)e {
    [self motion:e];
}
- (void)rightMouseDragged:(NSEvent *)e {
    [self motion:e];
}
- (void)otherMouseDragged:(NSEvent *)e {
    [self motion:e];
}
- (void)mouseEntered:(NSEvent *)e {
    [self motion:e];
}
- (void)mouseExited:(NSEvent *)e {
    struct vz_event ev = {.type = VZ_EV_POINTER_LEAVE, .window = self.ctl.handle, .time_ms = vz_now_ms()};
    emit(ev);
    [NSCursor.arrowCursor set];
}
- (void)button:(NSEvent *)e code:(uint32_t)code state:(uint32_t)state {
    struct vz_event ev = [self pointerEvent:VZ_EV_POINTER_BUTTON at:e];
    ev.code = code;
    ev.state = state;
    emit(ev);
}
- (void)mouseDown:(NSEvent *)e {
    self.lastMouseDown = e;
    [self button:e code:0x110 state:1];
}
- (void)mouseUp:(NSEvent *)e {
    if (self.resizeEdges) {
        self.resizeEdges = 0;
        return;
    }
    [self button:e code:0x110 state:0];
}
- (void)rightMouseDown:(NSEvent *)e {
    [self button:e code:0x111 state:1];
}
- (void)rightMouseUp:(NSEvent *)e {
    [self button:e code:0x111 state:0];
}
- (void)otherMouseDown:(NSEvent *)e {
    [self button:e code:(e.buttonNumber == 2 ? 0x112 : 0x113 + (uint32_t)e.buttonNumber - 3) state:1];
}
- (void)otherMouseUp:(NSEvent *)e {
    [self button:e code:(e.buttonNumber == 2 ? 0x112 : 0x113 + (uint32_t)e.buttonNumber - 3) state:0];
}
- (void)scrollWheel:(NSEvent *)e {
    struct vz_event ev = [self pointerEvent:VZ_EV_POINTER_SCROLL at:e];
    if (e.hasPreciseScrollingDeltas) {
        ev.precise = 1;
        ev.dx = -e.scrollingDeltaX;
        ev.dy = -e.scrollingDeltaY;
    } else {
        ev.discrete_x = (int32_t)-lround(e.deltaX);
        ev.discrete_y = (int32_t)-lround(e.deltaY);
        ev.dx = -e.deltaX * 15;
        ev.dy = -e.deltaY * 15;
    }
    if (ev.dx != 0 || ev.dy != 0)
        emit(ev);
}
- (void)key:(NSEvent *)e state:(uint32_t)state {
    sync_mods(self.ctl.handle, e.modifierFlags);
    uint32_t code = evdev_from_mac(e.keyCode);
    if (!code)
        return;
    struct vz_event ev = {.type = VZ_EV_KEY, .window = self.ctl.handle, .code = code, .state = state,
                          .time_ms = vz_now_ms()};
    emit(ev);
}
- (void)keyDown:(NSEvent *)e {
    if (!e.isARepeat)  // clients repeat keys themselves (wl_keyboard.repeat_info)
        [self key:e state:1];
}
- (void)keyUp:(NSEvent *)e {
    [self key:e state:0];
}
- (void)flagsChanged:(NSEvent *)e {
    NSEventModifierFlags f = e.modifierFlags;
    NSEventModifierFlags mask = 0;
    if (e.keyCode != 0x39) {  // everything but caps lock
        sync_mods(self.ctl.handle, f);
        return;
    }
    switch (e.keyCode) {
    case 0x38: case 0x3C: mask = NSEventModifierFlagShift; break;
    case 0x3B: case 0x3E: mask = NSEventModifierFlagControl; break;
    case 0x3A: case 0x3D: mask = NSEventModifierFlagOption; break;
    case 0x37: case 0x36: mask = NSEventModifierFlagCommand; break;
    case 0x39:  // caps lock: a tap per toggle
        [self key:e state:1];
        [self key:e state:0];
        return;
    default: return;
    }
    [self key:e state:(f & mask) ? 1 : 0];
}
// xdg_toplevel resize edges: top 1, bottom 2, left 4, right 8 (combinations for corners).
- (void)continueResize {
    NSPoint m = NSEvent.mouseLocation;
    NSRect f = self.resizeStartFrame;
    CGFloat dx = m.x - self.resizeStartMouse.x, dy = m.y - self.resizeStartMouse.y;
    uint32_t e = self.resizeEdges;
    if (e & 8) f.size.width += dx;
    if (e & 4) f.origin.x += dx, f.size.width -= dx;
    if (e & 2) f.origin.y += dy, f.size.height -= dy;  // screen y grows up
    if (e & 1) f.size.height += dy;
    NSSize min = self.window.minSize;
    if (f.size.width < min.width) {
        if (e & 4) f.origin.x -= min.width - f.size.width;
        f.size.width = min.width;
    }
    if (f.size.height < min.height) {
        if (e & 2) f.origin.y -= min.height - f.size.height;
        f.size.height = min.height;
    }
    [self.window setFrame:f display:YES];
}
@end

@implementation VZWindowCtl
- (BOOL)windowShouldClose:(NSWindow *)w {
    struct vz_event ev = {.type = VZ_EV_CLOSE, .window = self.handle};
    emit(ev);
    return NO;  // the client decides; its toplevel goes away when it destroys it
}
- (void)windowDidResize:(NSNotification *)n {
    self.view.link.paused = NO;
    if (self.programmaticResize)
        return;
    self.sizeDirty = NO; // a newer native resize supersedes a staged client size
    NSSize s = self.view.bounds.size;
    struct vz_event ev = {.type = VZ_EV_RESIZE, .window = self.handle, .width = s.width, .height = s.height};
    emit(ev);
}
- (void)windowDidBecomeKey:(NSNotification *)n {
    struct vz_event ev = {.type = VZ_EV_FOCUS, .window = self.handle, .state = 1};
    emit(ev);
}
- (void)windowDidResignKey:(NSNotification *)n {
    vz_release_modifiers(self.handle);
    struct vz_event ev = {.type = VZ_EV_FOCUS, .window = self.handle, .state = 0};
    emit(ev);
}
- (void)fullscreenChanged:(BOOL)on {
    self.fullscreen = on;
    if (!(self.window.styleMask & NSWindowStyleMaskTitled))
        self.view.layer.cornerRadius = on ? 0 : 12;
    NSSize s = self.view.bounds.size;
    struct vz_event ev = {.type = VZ_EV_FULLSCREEN, .window = self.handle, .state = on, .width = s.width,
                          .height = s.height};
    emit(ev);
}
- (void)windowDidEnterFullScreen:(NSNotification *)n {
    [self fullscreenChanged:YES];
}
- (void)windowDidExitFullScreen:(NSNotification *)n {
    [self fullscreenChanged:NO];
}
@end

static VZWindowCtl *ctl_for(uint64_t h) {
    id o = g_objects[@(h)];
    return [o isKindOfClass:[VZWindowCtl class]] ? o : nil;
}

static VZWindowCtl *make_window(BOOL decorated, BOOL popup, NSRect content) {
    NSWindowStyleMask style = popup ? NSWindowStyleMaskBorderless
                              : decorated
                                  ? (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                     NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                  : (NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable |
                                     NSWindowStyleMaskMiniaturizable);
    VZWindow *w = [[VZWindow alloc] initWithContentRect:content
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.isPopup = popup;
    w.releasedWhenClosed = NO;
    w.opaque = NO;
    w.backgroundColor = decorated ? NSColor.windowBackgroundColor : NSColor.clearColor;
    w.hasShadow = YES;
    w.acceptsMouseMovedEvents = YES;
    w.collectionBehavior = popup ? NSWindowCollectionBehaviorTransient
                                 : NSWindowCollectionBehaviorFullScreenPrimary;
    if (popup)
        w.level = NSPopUpMenuWindowLevel;

    VZView *v = [[VZView alloc] initWithFrame:NSMakeRect(0, 0, content.size.width, content.size.height)];
    v.wantsLayer = YES;
    v.layer = [CALayer layer];
    v.layer.masksToBounds = YES;
    v.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
    if (!decorated && !popup) {
        // Client-drawn decorations (GTK/libadwaita): round the window like the client
        // does, so the macOS shadow follows the client's corners.
        v.layer.cornerRadius = 12;
        v.layer.cornerCurve = kCACornerCurveContinuous;
    }
    v.surfaces = [CALayer layer];
    v.surfaces.anchorPoint = CGPointZero;
    v.surfaces.geometryFlipped = NO;
    [v.layer addSublayer:v.surfaces];
    w.contentView = v;

    VZWindowCtl *c = [VZWindowCtl new];
    c.window = w;
    c.view = v;
    v.ctl = c;
    w.delegate = c;
    c.handle = put(c);

    if (!popup) {
        v.link = [v displayLinkWithTarget:v selector:@selector(tick:)];
        [v.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return c;
}

uint64_t vz_window_new(int decorated, double width, double height) {
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    if (width <= 0 || height <= 0)
        width = 800, height = 600;
    NSRect r = NSMakeRect(NSMidX(screen) - width / 2, NSMidY(screen) - height / 2, width, height);
    return make_window(decorated, NO, r).handle;
}

static NSRect popup_rect(VZWindowCtl *parent, double x, double y, double width, double height) {
    NSRect content = [parent.window contentRectForFrameRect:parent.window.frame];
    // x, y are relative to the parent's content top-left (flipped); screen y grows up.
    return NSMakeRect(content.origin.x + x, NSMaxY(content) - y - height, MAX(width, 1), MAX(height, 1));
}

uint64_t vz_popup_new(uint64_t parent, double x, double y, double width, double height) {
    VZWindowCtl *p = ctl_for(parent);
    if (!p)
        return 0;
    VZWindowCtl *c = make_window(NO, YES, popup_rect(p, x, y, width, height));
    c.window.hasShadow = YES;
    [p.window addChildWindow:c.window ordered:NSWindowAbove];
    return c.handle;
}

void vz_popup_move(uint64_t popup, double x, double y, double width, double height) {
    VZWindowCtl *c = ctl_for(popup);
    VZWindowCtl *p = (VZWindowCtl *)c.window.parentWindow.delegate;
    if (!c || !p)
        return;
    [c.window setFrame:[c.window frameRectForContentRect:popup_rect(p, x, y, width, height)] display:YES];
}

void vz_window_set_title(uint64_t window, const char *title) {
    ctl_for(window).window.title = @(title ?: "");
}

static void apply_content_size(uint64_t window, double width, double height) {
    VZWindowCtl *c = ctl_for(window);
    if (!c || c.fullscreen || c.view.inLiveResize || c.view.resizeEdges || width <= 0 || height <= 0)
        return;
    NSSize cur = c.view.bounds.size;
    if (fabs(cur.width - width) < 0.5 && fabs(cur.height - height) < 0.5)
        return;
    c.programmaticResize = YES;
    NSRect f = c.window.frame;
    NSRect content = [c.window contentRectForFrameRect:f];
    // Keep the top-left corner fixed.
    CGFloat top = NSMaxY(content);
    content.size = NSMakeSize(width, height);
    content.origin.y = top - height;
    [c.window setFrame:[c.window frameRectForContentRect:content] display:YES];
    c.programmaticResize = NO;
}

void vz_window_set_content_size(uint64_t window, double width, double height) {
    VZWindowCtl *c = ctl_for(window);
    c.pendingSize = NSMakeSize(width, height);
    c.sizeDirty = YES;
}

void vz_window_set_min_size(uint64_t window, double width, double height) {
    VZWindowCtl *c = ctl_for(window);
    c.window.contentMinSize = NSMakeSize(MAX(width, 1), MAX(height, 1));
}

void vz_window_show(uint64_t window) {
    VZWindowCtl *c = ctl_for(window);
    if (!c || c.window.visible)
        return;
    present_window(window); // initial map has no running display link yet
    if (c.window.isPopup) {
        [c.window orderFront:nil];
    } else {
        [c.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

void vz_window_set_fullscreen(uint64_t window, int fullscreen) {
    VZWindowCtl *c = ctl_for(window);
    BOOL on = (c.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
    if (c && on != (fullscreen != 0))
        [c.window toggleFullScreen:nil];
}

void vz_window_set_maximized(uint64_t window, int maximized) {
    VZWindowCtl *c = ctl_for(window);
    if (!c || c.fullscreen)
        return;
    if (c.window.styleMask & NSWindowStyleMaskTitled) {
        if (c.window.zoomed != (maximized != 0))
            [c.window zoom:nil];
        return;
    }
    // Borderless (client-drawn decorations): zoom to the visible screen area ourselves,
    // with the usual window-resize animation, and remember where to go back to.
    c.view.layer.cornerRadius = maximized ? 0 : 12;
    if (maximized && NSIsEmptyRect(c.restoreFrame)) {
        c.restoreFrame = c.window.frame;
        [c.window setFrame:c.window.screen.visibleFrame display:YES animate:YES];
    } else if (!maximized && !NSIsEmptyRect(c.restoreFrame)) {
        NSRect r = c.restoreFrame;
        c.restoreFrame = NSZeroRect;
        [c.window setFrame:r display:YES animate:YES];
    }
}

void vz_window_minimize(uint64_t window) {
    [ctl_for(window).window miniaturize:nil];
}

void vz_window_begin_move(uint64_t window) {
    VZWindowCtl *c = ctl_for(window);
    if (c.view.lastMouseDown && (NSEvent.pressedMouseButtons & 1))
        [c.window performWindowDragWithEvent:c.view.lastMouseDown];
}

void vz_window_begin_resize(uint64_t window, uint32_t edges) {
    VZWindowCtl *c = ctl_for(window);
    if (!c || !(NSEvent.pressedMouseButtons & 1) || !edges)
        return;
    c.view.resizeEdges = edges;
    c.view.resizeStartFrame = c.window.frame;
    c.view.resizeStartMouse = NSEvent.mouseLocation;
}

void vz_window_destroy(uint64_t window) {
    VZWindowCtl *c = ctl_for(window);
    if (!c)
        return;
    [c.view.link invalidate];
    [c.window.parentWindow removeChildWindow:c.window];
    c.window.delegate = nil;
    [c.window orderOut:nil];
    [c.window close];
    [g_objects removeObjectForKey:@(window)];
}

void vz_window_set_surface_origin(uint64_t window, double x, double y) {
    VZWindowCtl *c = ctl_for(window);
    c.pendingOrigin = CGPointMake(x, y);
    c.originDirty = YES;
}

#pragma mark layer API

uint64_t vz_layer_new(uint64_t window) {
    VZWindowCtl *c = ctl_for(window);
    if (!c)
        return 0;
    VZLayer *l = [VZLayer new];
    l.window = window;
    l.layer = [CALayer layer];
    l.layer.anchorPoint = CGPointZero;
    l.layer.contentsGravity = kCAGravityTopLeft;
    l.layer.actions = @{@"contents" : [NSNull null], @"position" : [NSNull null], @"bounds" : [NSNull null]};
    [c.view.surfaces addSublayer:l.layer];
    return put(l);
}

static VZLayer *layer_for(uint64_t h) {
    id o = g_objects[@(h)];
    return [o isKindOfClass:[VZLayer class]] ? o : nil;
}

void vz_layer_set_frame(uint64_t layer, double x, double y, double width, double height, int z) {
    VZLayer *l = layer_for(layer);
    l.pendingFrame = CGRectMake(x, y, width, height);
    l.pendingZ = z;
    l.frameDirty = YES;
}

void vz_layer_set_pixels(uint64_t layer, const void *pixels, uint32_t width, uint32_t height, uint32_t stride,
                         int opaque, double scale) {
    VZLayer *l = layer_for(layer);
    if (!l || !width || !height)
        return;
    // IsInUse only reports consumers that have acquired the surface. It may still
    // be false for contents queued in a Core Animation transaction. Reusing that
    // storage during a burst of commits corrupts earlier, still-pending frames.
    IOSurfaceRef target = make_surface(width, height);
    if (!target)
        return;
    IOSurfaceLock(target, 0, NULL);
    uint8_t *dst = IOSurfaceGetBaseAddress(target);
    size_t dstride = IOSurfaceGetBytesPerRow(target);
    const uint8_t *src = pixels;
    for (uint32_t y = 0; y < height; y++) {
        memcpy(dst + y * dstride, src + (size_t)y * stride, (size_t)width * 4);
        if (opaque) {  // XRGB: the X byte is undefined; make it opaque for Core Animation
            uint8_t *row = dst + y * dstride;
            for (uint32_t x = 0; x < width; x++)
                row[x * 4 + 3] = 0xFF;
        }
    }
    IOSurfaceUnlock(target, 0, NULL);
    if (getenv("VZCOMP_SNAPSHOT") && !opaque && width > 700 && height > 700) {
        size_t transparent = 0, samples = 0;
        for (uint32_t y = 60; y + 60 < height; y += 16)
            for (uint32_t x = 60; x + 60 < width; x += 16) {
                samples++;
                transparent += src[(size_t)y * stride + x * 4 + 3] < 128;
            }
        static unsigned captured;
        if (samples && transparent * 2 > samples && captured < 8) {
            NSString *file = [NSString stringWithFormat:@"%s/bad-%u-%ux%u-s%zu.raw",
                getenv("VZCOMP_SNAPSHOT"), captured++, width, height, dstride];
            [NSFileManager.defaultManager createDirectoryAtPath:@(getenv("VZCOMP_SNAPSHOT"))
                withIntermediateDirectories:YES attributes:nil error:nil];
            [[NSData dataWithBytes:dst length:dstride * height] writeToFile:file atomically:YES];
            NSLog(@"transparent source frame %zu/%zu samples -> %@", transparent, samples, file);
        }
    }
    l.pendingContents = (__bridge_transfer id)target;
    l.pendingScale = scale;
    l.pendingOpaque = opaque != 0;
    l.pixelsDirty = YES;
}

void vz_layer_clear(uint64_t layer) {
    VZLayer *l = layer_for(layer);
    l.pendingContents = nil;
    l.pixelsDirty = YES;
}

void vz_layer_destroy(uint64_t layer) {
    VZLayer *l = layer_for(layer);
    [l.layer removeFromSuperlayer];
    [g_objects removeObjectForKey:@(layer)];
}

// Publish the newest complete buffer + geometry together, once per display tick.
// Wayland commits only stage state; intermediate resize responses never reach CA.
static BOOL belongs_to_window(uint64_t candidate, uint64_t window) {
    if (!window || candidate == window)
        return YES;
    NSWindow *ancestor = ctl_for(candidate).window.parentWindow;
    NSWindow *root = ctl_for(window).window;
    while (ancestor) {
        if (ancestor == root)
            return YES;
        ancestor = ancestor.parentWindow;
    }
    return NO;
}

static void present_window(uint64_t window) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    NSArray *objects = g_objects.allValues;
    for (id obj in objects) {
        if (![obj isKindOfClass:VZWindowCtl.class])
            continue;
        VZWindowCtl *c = obj;
        if (!belongs_to_window(c.handle, window))
            continue;
        if (c.sizeDirty) {
            c.sizeDirty = NO;
            apply_content_size(c.handle, c.pendingSize.width, c.pendingSize.height);
        }
        if (c.originDirty) {
            c.view.surfaces.position = c.pendingOrigin;
            c.originDirty = NO;
        }
    }
    for (id obj in objects) {
        if (![obj isKindOfClass:VZLayer.class])
            continue;
        VZLayer *l = obj;
        if (!belongs_to_window(l.window, window))
            continue;
        if (l.pixelsDirty) {
            l.layer.contents = l.pendingContents;
            l.layer.contentsScale = l.pendingScale;
            l.layer.opaque = l.pendingOpaque;
            l.pendingContents = nil;
            l.pixelsDirty = NO;
        }
        if (l.frameDirty) {
            l.layer.frame = l.pendingFrame;
            l.layer.zPosition = l.pendingZ;
            l.frameDirty = NO;
        }
    }
    [CATransaction commit];
    [CATransaction flush];
}

#pragma mark cursor

void vz_cursor_set_named(const char *cname) {
    NSString *n = @(cname ?: "default");
    NSCursor *c = NSCursor.arrowCursor;
    if ([n isEqual:@"text"] || [n isEqual:@"vertical-text"])
        c = NSCursor.IBeamCursor;
    else if ([n isEqual:@"pointer"])
        c = NSCursor.pointingHandCursor;
    else if ([n isEqual:@"grab"])
        c = NSCursor.openHandCursor;
    else if ([n isEqual:@"grabbing"] || [n isEqual:@"move"] || [n isEqual:@"all-scroll"])
        c = NSCursor.closedHandCursor;
    else if ([n isEqual:@"crosshair"] || [n isEqual:@"cell"])
        c = NSCursor.crosshairCursor;
    else if ([n isEqual:@"not-allowed"] || [n isEqual:@"no-drop"])
        c = NSCursor.operationNotAllowedCursor;
    else if ([n isEqual:@"copy"])
        c = NSCursor.dragCopyCursor;
    else if ([n isEqual:@"alias"])
        c = NSCursor.dragLinkCursor;
    else if ([n hasSuffix:@"ew-resize"] || [n isEqual:@"col-resize"] || [n isEqual:@"e-resize"] ||
             [n isEqual:@"w-resize"])
        c = NSCursor.resizeLeftRightCursor;
    else if ([n hasSuffix:@"ns-resize"] || [n isEqual:@"row-resize"] || [n isEqual:@"n-resize"] ||
             [n isEqual:@"s-resize"])
        c = NSCursor.resizeUpDownCursor;
    if (g_cursor_hidden) {
        [NSCursor unhide];
        g_cursor_hidden = NO;
    }
    g_cursor = c;
    [c set];
}

void vz_cursor_set_image(const void *pixels, uint32_t width, uint32_t height, uint32_t stride, double scale,
                         double hot_x, double hot_y) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                    pixelsWide:width
                                                                    pixelsHigh:height
                                                                 bitsPerSample:8
                                                               samplesPerPixel:4
                                                                      hasAlpha:YES
                                                                      isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace
                                                                  bitmapFormat:NSBitmapFormatThirtyTwoBitLittleEndian
                                                                   bytesPerRow:width * 4
                                                                  bitsPerPixel:32];
    for (uint32_t y = 0; y < height; y++)
        memcpy(rep.bitmapData + y * rep.bytesPerRow, (const uint8_t *)pixels + (size_t)y * stride, width * 4);
    rep.size = NSMakeSize(width / scale, height / scale);
    NSImage *img = [[NSImage alloc] initWithSize:rep.size];
    [img addRepresentation:rep];
    if (g_cursor_hidden) {
        [NSCursor unhide];
        g_cursor_hidden = NO;
    }
    g_cursor = [[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint(hot_x, hot_y)];
    [g_cursor set];
}

void vz_cursor_hide(void) {
    if (!g_cursor_hidden) {
        [NSCursor hide];
        g_cursor_hidden = YES;
    }
}

#pragma mark app

@interface VZAppDelegate : NSObject <NSApplicationDelegate>
@end
@implementation VZAppDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    struct vz_event ev = {.type = VZ_EV_QUIT};
    emit(ev);
    return NSTerminateCancel;  // we exit when the client goes away
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    for (NSWindow *w in app.windows)
        if (w.miniaturized)
            [w deminiaturize:nil];
    return YES;
}
@end

static VZAppDelegate *g_delegate;

static void build_menu(NSString *name) {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [bar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:name];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", name] action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", name]
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSMenuItem *winItem = [NSMenuItem new];
    [bar addItem:winItem];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [winMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [winMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [winMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    NSMenuItem *fs = [winMenu addItemWithTitle:@"Enter Full Screen"
                                        action:@selector(toggleFullScreen:)
                                 keyEquivalent:@"f"];
    fs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    winItem.submenu = winMenu;
    NSApp.windowsMenu = winMenu;
    NSApp.mainMenu = bar;
}

// Capture the currently submitted buffers on demand, without per-frame disk I/O.
// VZCOMP_SNAPSHOT=/path, then SIGUSR1: raw BGRA + layer/window geometry.
static dispatch_source_t g_snapshot_source, g_resize_source;
static void snapshot_layers(NSString *directory) {
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *metadata = [NSMutableArray array];
    for (NSNumber *handle in g_objects) {
        id obj = g_objects[handle];
        if (![obj isKindOfClass:VZLayer.class])
            continue;
        CALayer *layer = ((VZLayer *)obj).layer;
        IOSurfaceRef surface = (__bridge IOSurfaceRef)layer.contents;
        if (!surface)
            continue;
        size_t width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface);
        size_t stride = IOSurfaceGetBytesPerRow(surface);
        NSString *file = [NSString stringWithFormat:@"layer-%@-%zux%zu-s%zu.raw", handle, width, height, stride];
        IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
        NSData *data = [NSData dataWithBytes:IOSurfaceGetBaseAddress(surface) length:stride * height];
        [data writeToFile:[directory stringByAppendingPathComponent:file] atomically:YES];
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        [metadata addObject:@{@"file":file, @"frame":NSStringFromRect(layer.frame),
            @"bounds":NSStringFromRect(layer.bounds), @"scale":@(layer.contentsScale),
            @"parentFrame":NSStringFromRect(layer.superlayer.frame),
            @"contentsRect":NSStringFromRect(layer.contentsRect)}];
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[directory stringByAppendingPathComponent:@"layers.json"] atomically:YES];
}

void vz_init(vz_event_cb cb, void *ctx) {
    g_cb = cb;
    g_ctx = ctx;
    g_objects = [NSMutableDictionary dictionary];
    const char *snapshot = getenv("VZCOMP_SNAPSHOT");
    if (snapshot) {
        NSString *directory = @(snapshot);
        signal(SIGUSR1, SIG_IGN);
        g_snapshot_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(g_snapshot_source, ^{ snapshot_layers(directory); });
        dispatch_resume(g_snapshot_source);
        // Diagnostic native-resize workload, through the same delegate path as a drag.
        signal(SIGUSR2, SIG_IGN);
        g_resize_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(g_resize_source, ^{
            for (id obj in g_objects.allValues) {
                if (![obj isKindOfClass:VZWindowCtl.class] || ((VZWindowCtl *)obj).window.isPopup)
                    continue;
                VZWindowCtl *ctl = obj;
                __block unsigned tick = 0;
                ctl.view.resizeEdges = 8;
                NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) {
                    if (tick < 180) {
                        NSRect frame = ctl.window.frame;
                        frame.size.width = tick % 2 ? 369 + tick % 23 : 1450 - tick % 31;
                        [ctl.window setFrame:frame display:YES];
                    } else if (tick == 180) {
                        ctl.view.resizeEdges = 0;
                    } else if (tick == 240) {
                        [timer invalidate];
                        snapshot_layers(directory);
                    }
                    tick++;
                }];
                [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
            }
        });
        dispatch_resume(g_resize_source);
    }
    [NSApplication sharedApplication];
    g_delegate = [VZAppDelegate new];
    NSApp.delegate = g_delegate;
    // No Dock icon until the client maps a window (some connections never do).
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
}

// Every app process runs from the same bundle, so AppKit would title the menu bar, Dock
// tooltip and Cmd-Tab with the bundle's name. LaunchServices' per-process display name
// overrides that (private; resolved at runtime so a missing symbol only loses the name).
static void set_ls_display_name(NSString *name) {
    typedef CFTypeRef (*GetASN)(void);
    typedef OSStatus (*SetItem)(int, CFTypeRef, CFStringRef, CFStringRef, CFDictionaryRef *);
    void *ls = dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    GetASN get_asn = ls ? (GetASN)dlsym(ls, "_LSGetCurrentApplicationASN") : NULL;
    SetItem set_item = ls ? (SetItem)dlsym(ls, "_LSSetApplicationInformationItem") : NULL;
    CFStringRef *key = ls ? (CFStringRef *)dlsym(ls, "_kLSDisplayNameKey") : NULL;
    if (!get_asn || !set_item || !key) {
        fprintf(stderr, "[vzcomp] LaunchServices display-name API not found\n");
        return;
    }
    CFTypeRef asn = get_asn();
    OSStatus st = asn ? set_item(-2, asn, *key, (__bridge CFStringRef)name, NULL) : -1;
    if (st)
        fprintf(stderr, "[vzcomp] set display name: %d\n", (int)st);
}

void vz_app_become_regular(const char *name) {
    NSString *n = @(name ?: "Linux App");
    set_ls_display_name(n);
    build_menu(n);
    if (NSApp.activationPolicy != NSApplicationActivationPolicyRegular) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];
    }
}

static NSImage *placeholder_icon(NSString *label) {
    NSString *letter = label.length ? [[label substringToIndex:1] uppercaseString] : @"?";
    NSUInteger hash = label.hash;
    CGFloat hue = (hash % 360) / 360.0;
    return [NSImage imageWithSize:NSMakeSize(512, 512)
                          flipped:NO
                   drawingHandler:^BOOL(NSRect r) {
                       NSRect body = NSInsetRect(r, 50, 50);
                       NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:body xRadius:90 yRadius:90];
                       NSGradient *g = [[NSGradient alloc]
                           initWithStartingColor:[NSColor colorWithHue:hue saturation:0.55 brightness:0.95 alpha:1]
                                     endingColor:[NSColor colorWithHue:hue saturation:0.75 brightness:0.65 alpha:1]];
                       [g drawInBezierPath:p angle:-90];
                       NSDictionary *attrs = @{
                           NSFontAttributeName : [NSFont systemFontOfSize:240 weight:NSFontWeightSemibold],
                           NSForegroundColorAttributeName : NSColor.whiteColor,
                       };
                       NSSize s = [letter sizeWithAttributes:attrs];
                       [letter drawAtPoint:NSMakePoint(NSMidX(body) - s.width / 2, NSMidY(body) - s.height / 2)
                            withAttributes:attrs];
                       return YES;
                   }];
}

void vz_app_set_icon(const void *data, size_t len, const char *label) {
    NSImage *img = nil;
    if (data && len) {
        NSImage *src = [[NSImage alloc] initWithData:[NSData dataWithBytes:data length:len]];
        if (src.isValid && src.size.width > 0 && src.size.height > 0) {
            // Linux icons fill their canvas; macOS app icons sit in the inner 824 of a 1024
            // grid. Without the margin, a Linux app looks oversized next to native ones.
            img = [NSImage imageWithSize:NSMakeSize(1024, 1024)
                                 flipped:NO
                          drawingHandler:^BOOL(NSRect r) {
                              [src drawInRect:NSInsetRect(r, 100, 100)
                                     fromRect:NSZeroRect
                                    operation:NSCompositingOperationSourceOver
                                     fraction:1];
                              return YES;
                          }];
        }
    }
    fprintf(stderr, "[vzcomp] icon: %zu bytes -> %s\n", len, img ? "decoded" : "placeholder");
    if (!img)
        img = placeholder_icon(@(label ?: ""));
    NSApp.applicationIconImage = img;
    // The Dock creates the tile asynchronously after the activation-policy change and
    // takes the bundle's icon then, so set it again once the tile exists.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSApp.applicationIconImage = img;
    });
}

void vz_main_screen(double *width, double *height, double *scale, double *refresh_hz) {
    NSScreen *s = NSScreen.mainScreen;
    *width = s.frame.size.width;
    *height = s.frame.size.height;
    *scale = s.backingScaleFactor;
    NSInteger fps = s.maximumFramesPerSecond;
    *refresh_hz = fps > 0 ? fps : 60;
}

#pragma mark run loop

struct fd_watch {
    vz_fd_cb cb;
    void *ctx;
};

static CFFileDescriptorRef g_wayland_fd;

void vz_rearm_fd(void) {
    CFFileDescriptorEnableCallBacks(g_wayland_fd, kCFFileDescriptorReadCallBack);
}

static void fd_callout(CFFileDescriptorRef f, CFOptionFlags flags, void *info) {
    (void)f;
    (void)flags;
    struct fd_watch *w = info;
    w->cb(w->ctx);
    // Rust rearms after dispatch, which may be deferred during a nested AppKit loop.
}

void vz_watch_fd(int fd, vz_fd_cb cb, void *ctx) {
    struct fd_watch *w = malloc(sizeof *w);
    w->cb = cb;
    w->ctx = ctx;
    CFFileDescriptorContext c = {.info = w};
    CFFileDescriptorRef f = CFFileDescriptorCreate(NULL, fd, false, fd_callout, &c);
    g_wayland_fd = f;
    CFFileDescriptorEnableCallBacks(f, kCFFileDescriptorReadCallBack);
    CFRunLoopSourceRef src = CFFileDescriptorCreateRunLoopSource(NULL, f, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
}

void vz_run(void) {
    [NSApp run];
}

void vz_terminate(void) {
    exit(0);
}
