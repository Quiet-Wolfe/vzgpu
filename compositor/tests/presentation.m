// clang -fobjc-arc -framework AppKit -framework QuartzCore -framework IOSurface \
//   -framework Foundation -o /tmp/vzcomp-presentation tests/presentation.m
#import "../src/mac.m"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        g_objects = [NSMutableDictionary dictionary];
        VZLayer *layer = [VZLayer new];
        layer.layer = [CALayer layer];
        uint64_t handle = put(layer);
        vz_layer_set_pixels(handle, (uint32_t[]){0xff123456}, 1, 1, 4, 0, 1);
        vz_layer_set_frame(handle, 3, 4, 1, 1, 0);
        assert(layer.layer.contents == nil);
        assert(CGRectEqualToRect(layer.layer.frame, CGRectZero));
        present_window(0);
        assert(*(uint32_t *)IOSurfaceGetBaseAddress((__bridge IOSurfaceRef)layer.layer.contents) == 0xff123456);
        assert(CGRectEqualToRect(layer.layer.frame, CGRectMake(3, 4, 1, 1)));
        NSMutableArray *submitted = [NSMutableArray array];
        for (uint32_t n = 0; n < 120; n++) {
            uint32_t pixels[64];
            for (int i = 0; i < 64; i++) pixels[i] = 0xff000000 | n;
            // Multiple commits before Core Animation submits the implicit transaction.
            vz_layer_set_pixels(handle, pixels, 8, 8, 32, 0, 1);
            present_window(0);
            [submitted addObject:layer.layer.contents];
            for (uint32_t i = 0; i <= n; i++) {
                IOSurfaceRef surface = (__bridge IOSurfaceRef)submitted[i];
                assert(*(uint32_t *)IOSurfaceGetBaseAddress(surface) == (0xff000000 | i));
            }
        }
        puts("120 pending frames retain their original pixels");
        [submitted removeAllObjects];
        CFTimeInterval start = CACurrentMediaTime();
        for (uint32_t n = 0; n < 240; n++) {
            @autoreleasepool {
                uint32_t w = 1001 + n % 13, h = 769 + n % 11;
                size_t stride = ((size_t)w * 4 + 63) & ~63;
                uint32_t *pixels = calloc(h, stride);
                for (uint32_t y = 0; y < h; y++)
                    for (uint32_t x = 0; x < w; x++)
                        *(uint32_t *)((uint8_t *)pixels + y * stride + x * 4) = n;
                vz_layer_set_pixels(handle, pixels, w, h, (uint32_t)stride, 1, 2);
                free(pixels);
                present_window(0);
                IOSurfaceRef s = (__bridge IOSurfaceRef)layer.layer.contents;
                assert(IOSurfaceGetWidth(s) == w && IOSurfaceGetHeight(s) == h);
                const uint8_t *base = IOSurfaceGetBaseAddress(s);
                assert(*(uint32_t *)base == (0xff000000 | n));
                assert(*(uint32_t *)(base + (h - 1) * IOSurfaceGetBytesPerRow(s) + (w - 1) * 4)
                       == (0xff000000 | n));
                [CATransaction flush];
            }
        }
        printf("240 resized XRGB frames with padded strides: %.3f s\n", CACurrentMediaTime() - start);
        vz_layer_clear(handle);
        present_window(0);
        assert(layer.layer.contents == nil);

        vz_init(NULL, NULL);
        uint64_t window = vz_window_new(0, 500, 400);
        VZWindowCtl *ctl = ctl_for(window);
        ctl.view.resizeEdges = 8;
        vz_window_set_content_size(window, 300, 200);
        present_window(window);
        assert(ctl.view.bounds.size.width == 500);
        assert(ctl.view.bounds.size.height == 400);
        ctl.view.resizeEdges = 0;
        vz_window_set_content_size(window, 600, 450);
        present_window(window);
        assert(ctl.view.bounds.size.width == 600);
        assert(ctl.view.bounds.size.height == 450);
        vz_window_destroy(window);
        puts("native window ignores client sizes during interactive resize");
    }
}
