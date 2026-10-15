// Cross-domain context, ported from rutabaga_gfx cross_domain (libkrun
// src/rutabaga_gfx/src/cross_domain/{mod.rs,cross_domain_protocol.rs,sys/unix.rs}),
// whose macOS backend is a stub. Wire format matches sommelier's
// virtualization/virtgpu_cross_domain_protocol.h.
//
// Rings: the guest attaches two guest-memory blobs. Replies to queries go into the
// query ring (fence on ring 0 retires immediately). Channel events (data + fds from
// the compositor, pipe reads) go into the channel ring one at a time, each against a
// fence the guest arms on ring 1 with CROSS_DOMAIN_CMD_POLL.
//
// Buffers: GET_IMAGE_REQUIREMENTS hands out an item; a HOST3D blob created from it is
// backed by POSIX shared memory that is both mapped into the guest (via the device's
// host-visible region) and passed to the compositor as an fd, so frames are shared,
// not copied, on the host.

#import "crossdomain.h"
#include <errno.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

void vlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
extern BOOL gTrace;

enum {
    XCMD_INIT = 1, XCMD_GET_IMAGE_REQUIREMENTS, XCMD_POLL, XCMD_SEND, XCMD_RECEIVE, XCMD_READ,
    XCMD_WRITE,
};
#define X_CHANNEL_TYPE_WAYLAND 1
#define X_MAX_IDENTIFIERS 28
#define X_ID_TYPE_VIRTGPU_BLOB 1
#define X_ID_TYPE_READ_PIPE 3
#define X_ID_TYPE_WRITE_PIPE 4
#define X_PIPE_READ_START 0x80000000u
#define X_BUFFER_SIZE 4096
#define HOST_PAGE 16384ull

struct xhdr {
    uint8_t cmd, ring_idx;
    uint16_t cmd_size;
    uint32_t pad;
};
struct xinit {  // V0 (sommelier); V1 appends protocol_version
    struct xhdr hdr;
    uint32_t query_ring_id, channel_ring_id, channel_type;
};
struct xget_reqs {
    struct xhdr hdr;
    uint32_t width, height, drm_format, flags;
};
struct ximage_reqs {
    uint32_t strides[4], offsets[4];
    uint64_t modifier, size;
    uint32_t blob_id, map_info;
    int32_t memory_idx, physical_device_idx;
};
struct xsendrecv {
    struct xhdr hdr;
    uint32_t num_identifiers, opaque_data_size;
    uint32_t identifiers[X_MAX_IDENTIFIERS], identifier_types[X_MAX_IDENTIFIERS],
        identifier_sizes[X_MAX_IDENTIFIERS];
};
struct xreadwrite {
    struct xhdr hdr;
    uint32_t identifier, hang_up, opaque_data_size, pad;
};
_Static_assert(sizeof(struct ximage_reqs) == 64, "image reqs");
_Static_assert(sizeof(struct xsendrecv) == 352, "sendrecv");
_Static_assert(sizeof(struct xreadwrite) == 24, "readwrite");

@implementation GPUResource
- (instancetype)init {
    if ((self = [super init]))
        _hostFd = -1, _shmOffset = -1;
    return self;
}
- (void)dealloc {
    free(_iov);
    GPUResourceFreeHost(self);
}
@end

void GPUResourceFreeHost(GPUResource *r) {
    if (r.hostPtr)
        munmap(r.hostPtr, r.hostLen);
    if (r.hostFd >= 0)
        close(r.hostFd);
    r.hostPtr = NULL;
    r.hostFd = -1;
}

static uint64_t roundHost(uint64_t v) { return (v + HOST_PAGE - 1) & ~(HOST_PAGE - 1); }

// Anonymous POSIX shared memory: an fd any Wayland compositor can mmap.
static int makeShm(uint64_t size) {
    for (int attempt = 0; attempt < 8; attempt++) {
        char name[32];
        snprintf(name, sizeof name, "/vzgpu.%d.%08x", getpid(), arc4random());
        int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
        if (fd < 0) {
            if (errno == EEXIST)
                continue;
            return -1;
        }
        shm_unlink(name);
        if (ftruncate(fd, (off_t)size) < 0) {
            close(fd);
            return -1;
        }
        return fd;
    }
    return -1;
}

static uint32_t bytesPerPixel(uint32_t fourcc) {
    switch (fourcc) {
    case 0x20203852: /* R8: sommelier's byte pools (width = bytes, height = 1) */
        return 1;
    case 0x38385247: /* GR88 */
    case 0x36314752: /* RG16 */
    case 0x36314742: /* BG16 */
        return 2;
    default:  // AR24/XR24/AB24/XB24 and friends
        return 4;
    }
}

#pragma mark items

@interface XItem : NSObject
@property struct ximage_reqs reqs;  // kind == reqs
@property int fd;                   // kind == shm / write pipe / read pipe
@property uint64_t size;
@property int kind;
@end
enum { XITEM_REQS = 1, XITEM_SHM, XITEM_WRITE_PIPE, XITEM_READ_PIPE };
@implementation XItem
- (instancetype)init {
    if ((self = [super init]))
        _fd = -1;
    return self;
}
- (void)dealloc {
    if (_fd >= 0)
        close(_fd);
}
@end

@implementation CrossDomainContext {
    __weak id<CrossDomainHost> _host;
    uint32_t _ctx;
    dispatch_queue_t _queue;
    uint32_t _queryRing, _channelRing;
    int _sock;
    NSMutableDictionary<NSNumber *, XItem *> *_items;
    uint32_t _descriptorId, _readPipeId;
    NSMutableDictionary<NSNumber *, dispatch_source_t> *_sources;  // key 0 = socket, else read pipe id
    BOOL _armed, _suspended;
    uint64_t _armedFence;
    BOOL _closed;
}

+ (NSData *)capabilities {
    uint32_t caps[4] = {1 /* version */, 1u << X_CHANNEL_TYPE_WAYLAND, 0 /* dmabuf */, 0 /* ext gpu mem */};
    return [NSData dataWithBytes:caps length:sizeof caps];
}

- (instancetype)initWithHost:(id<CrossDomainHost>)host ctx:(uint32_t)ctxId queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _host = host;
        _ctx = ctxId;
        _queue = queue;
        _sock = -1;
        _items = [NSMutableDictionary new];
        _sources = [NSMutableDictionary new];
        _suspended = YES;
    }
    return self;
}

- (uint32_t)addItem:(XItem *)item {
    uint32_t id;
    if (item.kind == XITEM_READ_PIPE) {
        _readPipeId++;
        id = MAX(_readPipeId, X_PIPE_READ_START);
        _readPipeId = id;
    } else {
        id = ++_descriptorId;
    }
    _items[@(id)] = item;
    return id;
}

#pragma mark rings

- (BOOL)writeRing:(uint32_t)rid bytes:(const void *)a length:(size_t)alen extra:(const void *)b length:(size_t)blen {
    GPUResource *r = [_host resourceForId:rid];
    if (!r || !r.iovCount) {
        vlog("xdomain ctx=%u: ring %u has no guest backing", _ctx, rid);
        return NO;
    }
    const uint8_t *src[2] = {a, b};
    size_t srclen[2] = {alen, blen};
    int seg = 0;
    size_t segOff = 0;
    for (int s = 0; s < 2; s++) {
        size_t done = 0;
        while (done < srclen[s]) {
            if (seg >= r.iovCount)
                return NO;
            size_t room = r.iov[seg].iov_len - segOff;
            size_t n = MIN(room, srclen[s] - done);
            memcpy((uint8_t *)r.iov[seg].iov_base + segOff, src[s] + done, n);
            done += n;
            segOff += n;
            if (segOff == r.iov[seg].iov_len)
                seg++, segOff = 0;
        }
    }
    return YES;
}

#pragma mark commands

- (BOOL)submit:(const uint8_t *)cmds length:(size_t)len {
    while (len >= sizeof(struct xhdr)) {
        struct xhdr h;
        memcpy(&h, cmds, sizeof h);
        if (h.cmd_size < sizeof h || h.cmd_size > len) {
            vlog("xdomain ctx=%u: bad cmd_size %u (cmd %u, %zu left)", _ctx, h.cmd_size, h.cmd, len);
            return NO;
        }
        if (gTrace)
            vlog("xdomain ctx=%u: cmd %u size %u", _ctx, h.cmd, h.cmd_size);
        BOOL ok = YES;
        switch (h.cmd) {
        case XCMD_INIT: ok = [self initChannel:cmds length:h.cmd_size]; break;
        case XCMD_GET_IMAGE_REQUIREMENTS: ok = [self imageRequirements:cmds length:h.cmd_size]; break;
        case XCMD_SEND: ok = [self send:cmds length:h.cmd_size]; break;
        case XCMD_POLL: break;  // the fence armed with it does the work
        case XCMD_WRITE: ok = [self writePipe:cmds length:h.cmd_size]; break;
        default:
            vlog("xdomain ctx=%u: unsupported cmd %u", _ctx, h.cmd);
            ok = NO;
        }
        if (!ok)
            return NO;
        cmds += h.cmd_size;
        len -= h.cmd_size;
    }
    return YES;
}

static NSString *waylandSocketPath(void) {
    const char *env = getenv("VZGPU_WAYLAND_SOCKET");
    if (env)
        return @(env);
    // vzcomp's default: the per-user temp dir, as confstr reports it (not $TMPDIR, which
    // shells and sandboxes override); compositor/src/main.rs uses the same.
    char dir[PATH_MAX];
    if (confstr(_CS_DARWIN_USER_TEMP_DIR, dir, sizeof dir) == 0)
        return [NSTemporaryDirectory() stringByAppendingPathComponent:@"vzcomp/wayland-0"];
    return [@(dir) stringByAppendingPathComponent:@"vzcomp/wayland-0"];
}

- (BOOL)initChannel:(const uint8_t *)p length:(size_t)len {
    if (len < sizeof(struct xinit))
        return NO;
    struct xinit in;
    memcpy(&in, p, sizeof in);
    _queryRing = in.query_ring_id;
    _channelRing = in.channel_ring_id;
    vlog("xdomain ctx=%u: INIT query_ring=%u channel_ring=%u channel=%u", _ctx, _queryRing, _channelRing,
         in.channel_type);
    if (in.channel_type == 0)
        return YES;
    if (in.channel_type != X_CHANNEL_TYPE_WAYLAND)
        return NO;

    NSString *path = waylandSocketPath();
    struct sockaddr_un sa = {.sun_family = AF_UNIX};
    if (path.length >= sizeof sa.sun_path)
        return NO;
    strlcpy(sa.sun_path, path.fileSystemRepresentation, sizeof sa.sun_path);
    _sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_sock < 0 || connect(_sock, (struct sockaddr *)&sa, sizeof sa) < 0) {
        vlog("xdomain ctx=%u: connect %s: %s", _ctx, path.UTF8String, strerror(errno));
        if (_sock >= 0)
            close(_sock);
        _sock = -1;
        return NO;
    }
    fcntl(_sock, F_SETFD, FD_CLOEXEC);
    vlog("xdomain ctx=%u: connected to %s", _ctx, path.UTF8String);
    [self watchFd:_sock key:0];
    return YES;
}

- (BOOL)imageRequirements:(const uint8_t *)p length:(size_t)len {
    if (len < sizeof(struct xget_reqs))
        return NO;
    struct xget_reqs q;
    memcpy(&q, p, sizeof q);
    struct ximage_reqs r = {0};
    r.strides[0] = (q.width * bytesPerPixel(q.drm_format) + 63) & ~63u;
    r.size = roundHost((uint64_t)r.strides[0] * q.height);
    r.map_info = 1;  // cached
    r.memory_idx = r.physical_device_idx = -1;
    XItem *item = [XItem new];
    item.kind = XITEM_REQS;
    item.size = r.size;
    r.blob_id = [self addItem:item];
    item.reqs = r;
    if (gTrace)
        vlog("xdomain ctx=%u: image %ux%u fourcc=%.4s -> stride %u size 0x%llx blob_id %u", _ctx, q.width, q.height,
             (const char *)&q.drm_format, r.strides[0], r.size, r.blob_id);
    return [self writeRing:_queryRing bytes:&r length:sizeof r extra:NULL length:0];
}

- (GPUResource *)createBlob:(uint32_t)rid blobId:(uint64_t)blobId size:(uint64_t)size {
    XItem *item = _items[@((uint32_t)blobId)];
    if (!item) {
        vlog("xdomain ctx=%u: CREATE_BLOB rid=%u: no item %llu", _ctx, rid, blobId);
        return nil;
    }
    GPUResource *res = [GPUResource new];
    res.rid = rid;
    res.xdomain = YES;
    res.size = size;
    uint64_t len = roundHost(size);
    if (item.kind == XITEM_REQS) {
        // Reusable: each blob created from it gets its own shared memory.
        if (size > item.size) {
            vlog("xdomain ctx=%u: blob size 0x%llx > requirements 0x%llx", _ctx, size, item.size);
            return nil;
        }
        int fd = makeShm(len);
        void *ptr = fd < 0 ? MAP_FAILED : mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (ptr == MAP_FAILED) {
            vlog("xdomain ctx=%u: shm 0x%llx: %s", _ctx, len, strerror(errno));
            if (fd >= 0)
                close(fd);
            return nil;
        }
        res.hostFd = fd;
        res.hostPtr = ptr;
        res.hostLen = len;
    } else if (item.kind == XITEM_SHM) {
        // One-shot: a buffer the compositor sent (e.g. a keymap). Read-only fds get a
        // private writable mapping so the guest mapping stays valid.
        void *ptr = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, item.fd, 0);
        if (ptr == MAP_FAILED)
            ptr = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE, item.fd, 0);
        if (ptr == MAP_FAILED) {
            vlog("xdomain ctx=%u: mmap received fd: %s", _ctx, strerror(errno));
            return nil;
        }
        res.hostFd = item.fd;
        item.fd = -1;
        res.hostPtr = ptr;
        res.hostLen = len;
        [_items removeObjectForKey:@((uint32_t)blobId)];
    } else {
        vlog("xdomain ctx=%u: blob from item kind %d", _ctx, item.kind);
        return nil;
    }
    return res;
}

- (BOOL)send:(const uint8_t *)p length:(size_t)len {
    if (len < sizeof(struct xsendrecv))
        return NO;
    struct xsendrecv s;
    memcpy(&s, p, sizeof s);
    if (s.num_identifiers > X_MAX_IDENTIFIERS || sizeof s + s.opaque_data_size > len || _sock < 0)
        return NO;
    int fds[X_MAX_IDENTIFIERS];
    int closeAfter[X_MAX_IDENTIFIERS];
    int nclose = 0;
    for (uint32_t i = 0; i < s.num_identifiers; i++) {
        switch (s.identifier_types[i]) {
        case X_ID_TYPE_VIRTGPU_BLOB: {
            GPUResource *r = [_host resourceForId:s.identifiers[i]];
            if (!r || r.hostFd < 0) {
                vlog("xdomain ctx=%u: SEND blob %u has no host fd", _ctx, s.identifiers[i]);
                return NO;
            }
            fds[i] = r.hostFd;
            break;
        }
        case X_ID_TYPE_READ_PIPE: {
            // The guest will read what the compositor writes into this pipe.
            int pp[2];
            if (pipe(pp) < 0)
                return NO;
            XItem *item = [XItem new];
            item.kind = XITEM_READ_PIPE;
            item.fd = pp[0];
            uint32_t id = [self addItem:item];
            if (id != s.identifiers[i])
                vlog("xdomain ctx=%u: read pipe id %u != guest guess %u", _ctx, id, s.identifiers[i]);
            fds[i] = pp[1];
            closeAfter[nclose++] = pp[1];
            [self watchFd:pp[0] key:id];
            break;
        }
        default:
            vlog("xdomain ctx=%u: SEND identifier type %u unsupported", _ctx, s.identifier_types[i]);
            return NO;
        }
    }
    struct iovec iov = {(void *)(p + sizeof s), s.opaque_data_size};
    union {
        struct cmsghdr h;
        char buf[CMSG_SPACE(sizeof(int) * X_MAX_IDENTIFIERS)];
    } cm;
    struct msghdr mh = {.msg_iov = &iov, .msg_iovlen = 1};
    if (s.num_identifiers) {
        mh.msg_control = cm.buf;
        mh.msg_controllen = CMSG_SPACE(sizeof(int) * s.num_identifiers);
        struct cmsghdr *c = CMSG_FIRSTHDR(&mh);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int) * s.num_identifiers);
        memcpy(CMSG_DATA(c), fds, sizeof(int) * s.num_identifiers);
    }
    ssize_t n = sendmsg(_sock, &mh, 0);
    for (int i = 0; i < nclose; i++)
        close(closeAfter[i]);
    if (n < 0) {
        vlog("xdomain ctx=%u: sendmsg: %s", _ctx, strerror(errno));
        return NO;
    }
    return YES;
}

- (BOOL)writePipe:(const uint8_t *)p length:(size_t)len {
    if (len < sizeof(struct xreadwrite))
        return NO;
    struct xreadwrite w;
    memcpy(&w, p, sizeof w);
    XItem *item = _items[@(w.identifier)];
    if (!item || item.kind != XITEM_WRITE_PIPE || sizeof w + w.opaque_data_size > len)
        return NO;
    if (w.opaque_data_size && write(item.fd, p + sizeof w, w.opaque_data_size) < 0)
        vlog("xdomain ctx=%u: pipe write: %s", _ctx, strerror(errno));
    if (w.hang_up)
        [_items removeObjectForKey:@(w.identifier)];
    return YES;
}

#pragma mark channel events

- (void)watchFd:(int)fd key:(uint32_t)key {
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    __weak CrossDomainContext *weak = self;
    dispatch_source_set_event_handler(src, ^{ [weak eventOn:key]; });
    _sources[@(key)] = src;
    // Sources run only while a channel fence is armed; one event per fence.
    if (!_suspended)
        dispatch_resume(src);
    else
        dispatch_activate(src), dispatch_suspend(src);
}

- (void)setSourcesRunning:(BOOL)run {
    if (run == !_suspended)
        return;
    _suspended = !run;
    for (dispatch_source_t s in _sources.allValues) {
        if (run)
            dispatch_resume(s);
        else
            dispatch_suspend(s);
    }
}

- (void)armChannelFence:(uint64_t)fenceId {
    _armed = YES;
    _armedFence = fenceId;
    [self setSourcesRunning:YES];
}

- (void)deliver {
    _armed = NO;
    [self setSourcesRunning:NO];
    [_host crossDomainFenceDone:_ctx ring:1 fence:_armedFence];
}

- (void)eventOn:(uint32_t)key {
    if (!_armed || _closed)
        return;
    if (key == 0)
        [self receiveFromCompositor];
    else
        [self readPipe:key];
}

- (void)receiveFromCompositor {
    uint8_t data[X_BUFFER_SIZE - sizeof(struct xsendrecv)];
    struct iovec iov = {data, sizeof data};
    union {
        struct cmsghdr h;
        char buf[CMSG_SPACE(sizeof(int) * X_MAX_IDENTIFIERS)];
    } cm;
    struct msghdr mh = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = cm.buf, .msg_controllen = sizeof cm.buf};
    ssize_t n = recvmsg(_sock, &mh, 0);
    if (n <= 0) {
        vlog("xdomain ctx=%u: compositor connection %s", _ctx, n == 0 ? "closed" : strerror(errno));
        dispatch_source_t s = _sources[@0];
        if (_suspended)
            dispatch_resume(s);
        dispatch_source_cancel(s);
        [_sources removeObjectForKey:@0];
        return;  // fence stays armed; the guest sees no further events
    }
    struct xsendrecv r = {0};
    r.hdr.cmd = XCMD_RECEIVE;
    r.opaque_data_size = (uint32_t)n;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c; c = CMSG_NXTHDR(&mh, c)) {
        if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
            continue;
        int nfd = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
        int *fds = (int *)CMSG_DATA(c);
        for (int i = 0; i < nfd; i++) {
            int fd = fds[i];
            fcntl(fd, F_SETFD, FD_CLOEXEC);
            if (r.num_identifiers >= X_MAX_IDENTIFIERS) {
                close(fd);
                continue;
            }
            uint32_t k = r.num_identifiers;
            off_t end = lseek(fd, 0, SEEK_END);
            XItem *item = [XItem new];
            item.fd = fd;
            if (end >= 0) {
                item.kind = XITEM_SHM;
                item.size = (uint64_t)end;
                r.identifier_types[k] = X_ID_TYPE_VIRTGPU_BLOB;
                r.identifier_sizes[k] = (uint32_t)end;
            } else if ((fcntl(fd, F_GETFL) & O_ACCMODE) == O_WRONLY) {
                item.kind = XITEM_WRITE_PIPE;
                r.identifier_types[k] = X_ID_TYPE_WRITE_PIPE;
            } else {
                vlog("xdomain ctx=%u: dropping unsupported fd from compositor", _ctx);
                continue;  // item dealloc closes it
            }
            r.identifiers[k] = [self addItem:item];
            r.num_identifiers++;
        }
    }
    if (gTrace)
        vlog("xdomain ctx=%u: RECEIVE %zd bytes, %u fds", _ctx, n, r.num_identifiers);
    if (![self writeRing:_channelRing bytes:&r length:sizeof r extra:data length:(size_t)n])
        return;
    [self deliver];
}

- (void)readPipe:(uint32_t)key {
    XItem *item = _items[@(key)];
    if (!item)
        return;
    uint8_t data[X_BUFFER_SIZE - sizeof(struct xreadwrite)];
    ssize_t n = read(item.fd, data, sizeof data);
    struct xreadwrite r = {.hdr.cmd = XCMD_READ, .identifier = key};
    if (n <= 0) {
        r.hang_up = 1;
        n = 0;
        dispatch_source_t s = _sources[@(key)];
        if (_suspended)
            dispatch_resume(s);
        dispatch_source_cancel(s);
        [_sources removeObjectForKey:@(key)];
        [_items removeObjectForKey:@(key)];
    }
    r.opaque_data_size = (uint32_t)n;
    if ([self writeRing:_channelRing bytes:&r length:sizeof r extra:data length:(size_t)n])
        [self deliver];
}

- (void)close {
    _closed = YES;
    for (dispatch_source_t s in _sources.allValues) {
        if (_suspended)
            dispatch_resume(s);
        dispatch_source_cancel(s);
    }
    [_sources removeAllObjects];
    if (_sock >= 0)
        close(_sock);
    _sock = -1;
    [_items removeAllObjects];
}

@end
