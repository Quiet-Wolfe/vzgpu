// macOS side of vzcomp. See mac.h.
//
// Each Wayland surface is a CALayer whose contents is an IOSurface. On every commit
// the pixels are copied into an IOSurface from a small per-layer pool that WindowServer
// is not currently using (IOSurfaceIsInUse), so a frame on screen is never written to.
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
@property(strong) NSMutableArray *pool;  // IOSurfaceRef (bridged)
@property IOSurfaceRef current;
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
@end

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
    NSSize s = self.view.bounds.size;
    struct vz_event ev = {.type = VZ_EV_RESIZE, .window = self.handle, .width = s.width, .height = s.height};
    emit(ev);
}
- (void)windowDidBecomeKey:(NSNotification *)n {
    struct vz_event ev = {.type = VZ_EV_FOCUS, .window = self.handle, .state = 1};
    emit(ev);
}
- (void)windowDidResignKey:(NSNotification *)n {
    struct vz_event ev = {.type = VZ_EV_FOCUS, .window = self.handle, .state = 0};
    emit(ev);
}
- (void)fullscreenChanged:(BOOL)on {
    self.fullscreen = on;
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

void vz_window_set_content_size(uint64_t window, double width, double height) {
    VZWindowCtl *c = ctl_for(window);
    if (!c || c.fullscreen || width <= 0 || height <= 0)
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

void vz_window_set_min_size(uint64_t window, double width, double height) {
    VZWindowCtl *c = ctl_for(window);
    c.window.contentMinSize = NSMakeSize(MAX(width, 1), MAX(height, 1));
}

void vz_window_show(uint64_t window) {
    VZWindowCtl *c = ctl_for(window);
    if (!c || c.window.visible)
        return;
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
    if (c && c.window.zoomed != (maximized != 0))
        [c.window zoom:nil];
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
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    c.view.surfaces.position = CGPointMake(x, y);
    [CATransaction commit];
}

#pragma mark layer API

uint64_t vz_layer_new(uint64_t window) {
    VZWindowCtl *c = ctl_for(window);
    if (!c)
        return 0;
    VZLayer *l = [VZLayer new];
    l.layer = [CALayer layer];
    l.layer.anchorPoint = CGPointZero;
    l.layer.contentsGravity = kCAGravityTopLeft;
    l.layer.actions = @{@"contents" : [NSNull null], @"position" : [NSNull null], @"bounds" : [NSNull null]};
    l.pool = [NSMutableArray array];
    [c.view.surfaces addSublayer:l.layer];
    return put(l);
}

static VZLayer *layer_for(uint64_t h) {
    id o = g_objects[@(h)];
    return [o isKindOfClass:[VZLayer class]] ? o : nil;
}

void vz_layer_set_frame(uint64_t layer, double x, double y, double width, double height, int z) {
    VZLayer *l = layer_for(layer);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.layer.frame = CGRectMake(x, y, width, height);
    l.layer.zPosition = z;
    [CATransaction commit];
}

void vz_layer_set_pixels(uint64_t layer, const void *pixels, uint32_t width, uint32_t height, uint32_t stride,
                         int opaque, double scale) {
    VZLayer *l = layer_for(layer);
    if (!l || !width || !height)
        return;
    IOSurfaceRef target = NULL;
    for (id o in l.pool) {
        IOSurfaceRef s = (__bridge IOSurfaceRef)o;
        if (s == l.current || IOSurfaceIsInUse(s))
            continue;
        if (IOSurfaceGetWidth(s) != width || IOSurfaceGetHeight(s) != height)
            continue;
        target = s;
        break;
    }
    if (!target) {
        // Drop free surfaces of the wrong size, then grow the pool.
        NSMutableArray *keep = [NSMutableArray array];
        for (id o in l.pool) {
            IOSurfaceRef s = (__bridge IOSurfaceRef)o;
            if (s == l.current || IOSurfaceIsInUse(s))
                [keep addObject:o];
        }
        l.pool = keep;
        target = make_surface(width, height);
        if (!target)
            return;
        [l.pool addObject:(__bridge_transfer id)target];
    }
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
    l.current = target;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.layer.contents = (__bridge id)target;
    l.layer.contentsScale = scale;
    l.layer.opaque = opaque != 0;
    [CATransaction commit];
}

void vz_layer_clear(uint64_t layer) {
    VZLayer *l = layer_for(layer);
    l.layer.contents = nil;
    l.current = NULL;
}

void vz_layer_destroy(uint64_t layer) {
    VZLayer *l = layer_for(layer);
    [l.layer removeFromSuperlayer];
    [g_objects removeObjectForKey:@(layer)];
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

void vz_init(vz_event_cb cb, void *ctx) {
    g_cb = cb;
    g_ctx = ctx;
    g_objects = [NSMutableDictionary dictionary];
    [NSApplication sharedApplication];
    g_delegate = [VZAppDelegate new];
    NSApp.delegate = g_delegate;
    // No Dock icon until the client maps a window (some connections never do).
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
}

void vz_app_become_regular(const char *name) {
    NSString *n = @(name ?: "Linux App");
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
    if (data && len)
        img = [[NSImage alloc] initWithData:[NSData dataWithBytes:data length:len]];
    if (!img)
        img = placeholder_icon(@(label ?: ""));
    NSApp.applicationIconImage = img;
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

static void fd_callout(CFFileDescriptorRef f, CFOptionFlags flags, void *info) {
    (void)flags;
    struct fd_watch *w = info;
    w->cb(w->ctx);
    CFFileDescriptorEnableCallBacks(f, kCFFileDescriptorReadCallBack);
}

void vz_watch_fd(int fd, vz_fd_cb cb, void *ctx) {
    struct fd_watch *w = malloc(sizeof *w);
    w->cb = cb;
    w->ctx = ctx;
    CFFileDescriptorContext c = {.info = w};
    CFFileDescriptorRef f = CFFileDescriptorCreate(NULL, fd, false, fd_callout, &c);
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
