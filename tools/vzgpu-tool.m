// vzgpu-tool — the bits of `vzgpu install` macOS has no command for.
//   vzgpu-tool unxz <in.xz> <out>      decompress .xz (Apple Compression framework, LZMA)
//   vzgpu-tool icns <icon.svg|png> <out.icns>   app icon for a launcher bundle, on Apple's grid
//   vzgpu-tool rootpart <disk.img>     print "<PARTUUID> <index>" of the root partition: the
//                                      largest partition that is not EFI/BIOS-boot/swap
// Build: xcrun clang -O2 -fobjc-arc -framework Foundation -framework AppKit -framework ImageIO -lcompression -o vzgpu-tool vzgpu-tool.m
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <compression.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static int unxz(const char *in, const char *out) {
    int fi = open(in, O_RDONLY), fo = open(out, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fi < 0 || fo < 0) {
        perror("open");
        return 1;
    }
    struct stat st;
    fstat(fi, &st);
    compression_stream s;
    if (compression_stream_init(&s, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) != COMPRESSION_STATUS_OK)
        return 1;
    enum { IN = 1 << 20, OUT = 8 << 20 };
    uint8_t *ib = malloc(IN), *ob = malloc(OUT);
    s.src_size = 0;
    off_t done = 0, last = -1;
    int eof = 0;
    for (;;) {
        if (s.src_size == 0 && !eof) {
            ssize_t n = read(fi, ib, IN);
            if (n < 0) { perror("read"); return 1; }
            eof = n == 0;
            s.src_ptr = ib;
            s.src_size = n;
            done += n;
        }
        s.dst_ptr = ob;
        s.dst_size = OUT;
        compression_status r = compression_stream_process(&s, eof ? COMPRESSION_STREAM_FINALIZE : 0);
        if (r == COMPRESSION_STATUS_ERROR) {
            fprintf(stderr, "unxz: corrupt input\n");
            return 1;
        }
        size_t n = OUT - s.dst_size;
        // Keep the output sparse: disk images are mostly zeros.
        size_t off = 0;
        while (off < n) {
            size_t blk = MIN((size_t)65536, n - off);
            BOOL zero = YES;
            for (size_t i = 0; i < blk && zero; i += 8)
                zero = *(uint64_t *)(ob + off + i) == 0;
            if (zero) lseek(fo, blk, SEEK_CUR);
            else if (write(fo, ob + off, blk) != (ssize_t)blk) { perror("write"); return 1; }
            off += blk;
        }
        int pct = st.st_size ? (int)(done * 100 / st.st_size) : 0;
        if (pct != last && isatty(2)) { fprintf(stderr, "\runpacking %d%%", pct); last = pct; }
        if (r == COMPRESSION_STATUS_END) break;
    }
    ftruncate(fo, lseek(fo, 0, SEEK_CUR));  // a trailing hole still counts toward the size
    if (isatty(2)) fprintf(stderr, "\n");
    compression_stream_destroy(&s);
    return close(fo) ? 1 : 0;
}

static int rootpart(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    uint8_t hdr[512];
    if (pread(fd, hdr, 512, 512) != 512 || memcmp(hdr, "EFI PART", 8)) {
        // MBR: the kernel's PARTUUID is "<disk signature>-<partition number, 2 hex digits>".
        uint8_t mbr[512];
        if (pread(fd, mbr, 512, 0) != 512 || mbr[510] != 0x55 || mbr[511] != 0xAA) {
            fprintf(stderr, "rootpart: no partition table\n");
            return 1;
        }
        uint32_t sig = *(uint32_t *)(mbr + 440), best = 0;
        int bestIdx = -1;
        for (int i = 0; i < 4; i++) {
            const uint8_t *p = mbr + 446 + 16 * i;
            uint8_t type = p[4];
            uint32_t len = *(uint32_t *)(p + 12);
            if (type == 0 || type == 0xEF || type == 0x82 || type == 0x05 || type == 0x0F) continue;
            if (len > best) { best = len; bestIdx = i + 1; }
        }
        if (bestIdx < 0) { fprintf(stderr, "rootpart: none\n"); return 1; }
        printf("%08x-%02x %d\n", sig, bestIdx, bestIdx);
        return 0;
    }
    uint64_t lba = *(uint64_t *)(hdr + 72);
    uint32_t count = *(uint32_t *)(hdr + 80), size = *(uint32_t *)(hdr + 84);
    // Partition type GUIDs (on-disk mixed-endian byte order) to skip.
    static const uint8_t esp[16] = {0x28,0x73,0x2a,0xc1,0x1f,0xf8,0xd2,0x11,0xba,0x4b,0x00,0xa0,0xc9,0x3e,0xc9,0x3b};
    static const uint8_t bios[16] = {0x48,0x61,0x68,0x21,0x49,0x64,0x6f,0x6e,0x74,0x4e,0x65,0x65,0x64,0x45,0x46,0x49};
    static const uint8_t swap[16] = {0x6d,0xfd,0x57,0x06,0xab,0xa4,0xc4,0x43,0x84,0xe5,0x09,0x33,0xc8,0x4b,0x4f,0x4f};
    uint64_t best = 0;
    int bestIdx = -1;
    uint8_t bestGuid[16];
    uint8_t *e = malloc(size);
    for (uint32_t i = 0; i < count; i++) {
        if (pread(fd, e, size, lba * 512 + (off_t)i * size) != size) break;
        static const uint8_t none[16];
        if (!memcmp(e, none, 16) || !memcmp(e, esp, 16) || !memcmp(e, bios, 16) || !memcmp(e, swap, 16))
            continue;
        uint64_t len = *(uint64_t *)(e + 40) - *(uint64_t *)(e + 32) + 1;
        if (len > best) { best = len; bestIdx = (int)i + 1; memcpy(bestGuid, e + 16, 16); }
    }
    if (bestIdx < 0) { fprintf(stderr, "rootpart: none\n"); return 1; }
    const uint8_t *g = bestGuid;
    printf("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x %d\n",
           g[3], g[2], g[1], g[0], g[5], g[4], g[7], g[6], g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15],
           bestIdx);
    return 0;
}

static int icns(const char *in, const char *out) {
    NSImage *src = [[NSImage alloc] initWithContentsOfFile:@(in)];
    if (!src.isValid) { fprintf(stderr, "icns: can't read %s\n", in); return 1; }
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:@(out)], (__bridge CFStringRef)UTTypeICNS.identifier, 6, NULL);
    for (int px = 16; px <= 1024; px *= 2) {
        if (px == 32 || px == 64) continue;  // ICNS sizes: 16 32(@2x of 16) 128 256 512 1024
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
            bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        // Linux icons fill their canvas; macOS icons use the inner 824 of 1024 (as vzcomp's Dock icon).
        CGFloat m = px * 100.0 / 1024;
        [src drawInRect:NSMakeRect(m, m, px - 2 * m, px - 2 * m) fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver fraction:1];
        [NSGraphicsContext restoreGraphicsState];
        CGImageDestinationAddImage(dst, rep.CGImage, NULL);
    }
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok ? 0 : 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 4 && !strcmp(argv[1], "unxz")) return unxz(argv[2], argv[3]);
        if (argc == 3 && !strcmp(argv[1], "rootpart")) return rootpart(argv[2]);
        if (argc == 4 && !strcmp(argv[1], "icns")) return icns(argv[2], argv[3]);
        fprintf(stderr, "usage: vzgpu-tool unxz <in.xz> <out> | rootpart <disk.img> | icns <icon> <out.icns>\n");
        return 2;
    }
}
