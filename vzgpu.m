// vzgpu: a Venus-capable virtio-gpu for Linux guests under Virtualization.framework,
// built on the macOS 27 VZCustomVirtioDevice API. virglrenderer (Venus, no virgl)
// runs in this process; host-visible blobs are mapped into the guest through the
// device's shared memory region (virtio-gpu SHM id 1).
//
// Device logic follows libkrun src/devices/src/virtio/gpu/{worker,virtio_gpu}.rs
// and rutabaga_gfx virgl_renderer.rs. Wire layouts: include/uapi/linux/virtio_gpu.h.
//
// usage: vzgpu <vmdir>   (vmdir holds Image, initramfs.img, disk.img; guest console
// goes to <vmdir>/run/console.log, input is read from <vmdir>/run/in.fifo)
// env:   VZGPU_CMDLINE  kernel command line override
//        VZGPU_TRACE=1  log every control-queue command

#import <Foundation/Foundation.h>
#import <Virtualization/Virtualization.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <virglrenderer.h>

static BOOL gTrace;

static void vlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void vlog(const char *fmt, ...) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    fprintf(stderr, "[vmm %03ld.%03ld] %s\n", ts.tv_sec % 1000, ts.tv_nsec / 1000000, buf);
}

#pragma mark - virtio-gpu wire format

enum {
    VIRTIO_GPU_F_VIRGL = 0,
    VIRTIO_GPU_F_RESOURCE_BLOB = 3,
    VIRTIO_GPU_F_CONTEXT_INIT = 4,
    VIRTIO_GPU_F_BLOB_ALIGNMENT = 5,
};
enum {
    CMD_GET_DISPLAY_INFO = 0x0100, CMD_RESOURCE_CREATE_2D, CMD_RESOURCE_UNREF, CMD_SET_SCANOUT,
    CMD_RESOURCE_FLUSH, CMD_TRANSFER_TO_HOST_2D, CMD_RESOURCE_ATTACH_BACKING,
    CMD_RESOURCE_DETACH_BACKING, CMD_GET_CAPSET_INFO, CMD_GET_CAPSET, CMD_GET_EDID,
    CMD_RESOURCE_ASSIGN_UUID, CMD_RESOURCE_CREATE_BLOB, CMD_SET_SCANOUT_BLOB,
    CMD_CTX_CREATE = 0x0200, CMD_CTX_DESTROY, CMD_CTX_ATTACH_RESOURCE, CMD_CTX_DETACH_RESOURCE,
    CMD_RESOURCE_CREATE_3D, CMD_TRANSFER_TO_HOST_3D, CMD_TRANSFER_FROM_HOST_3D, CMD_SUBMIT_3D,
    CMD_RESOURCE_MAP_BLOB, CMD_RESOURCE_UNMAP_BLOB,
    RESP_OK_NODATA = 0x1100, RESP_OK_DISPLAY_INFO, RESP_OK_CAPSET_INFO, RESP_OK_CAPSET,
    RESP_OK_EDID, RESP_OK_RESOURCE_UUID, RESP_OK_MAP_INFO,
    RESP_ERR_UNSPEC = 0x1200, RESP_ERR_OUT_OF_MEMORY, RESP_ERR_INVALID_SCANOUT_ID,
    RESP_ERR_INVALID_RESOURCE_ID, RESP_ERR_INVALID_CONTEXT_ID, RESP_ERR_INVALID_PARAMETER,
};
#define FLAG_FENCE (1u << 0)
#define FLAG_INFO_RING_IDX (1u << 1)
#define BLOB_MEM_HOST3D 2
#define CAPSET_VENUS 4
#define SHM_ID_HOST_VISIBLE 1
#define BLOB_ALIGN 16384ull
#define SHM_SIZE (8ull << 30)

struct ctrl_hdr {
    uint32_t type, flags;
    uint64_t fence_id;
    uint32_t ctx_id;
    uint8_t ring_idx, pad[3];
};
_Static_assert(sizeof(struct ctrl_hdr) == 24, "ctrl_hdr");
struct virgl_box {  /* opaque in virglrenderer.h; layout matches virtio_gpu_box */
    uint32_t x, y, z, w, h, d;
};
struct mem_entry {
    uint64_t addr;
    uint32_t length, padding;
};

static const char *cmdName(uint32_t t) {
    switch (t) {
    case CMD_GET_DISPLAY_INFO: return "GET_DISPLAY_INFO";
    case CMD_RESOURCE_CREATE_2D: return "RESOURCE_CREATE_2D";
    case CMD_RESOURCE_UNREF: return "RESOURCE_UNREF";
    case CMD_SET_SCANOUT: return "SET_SCANOUT";
    case CMD_RESOURCE_FLUSH: return "RESOURCE_FLUSH";
    case CMD_TRANSFER_TO_HOST_2D: return "TRANSFER_TO_HOST_2D";
    case CMD_RESOURCE_ATTACH_BACKING: return "RESOURCE_ATTACH_BACKING";
    case CMD_RESOURCE_DETACH_BACKING: return "RESOURCE_DETACH_BACKING";
    case CMD_GET_CAPSET_INFO: return "GET_CAPSET_INFO";
    case CMD_GET_CAPSET: return "GET_CAPSET";
    case CMD_GET_EDID: return "GET_EDID";
    case CMD_RESOURCE_ASSIGN_UUID: return "RESOURCE_ASSIGN_UUID";
    case CMD_RESOURCE_CREATE_BLOB: return "RESOURCE_CREATE_BLOB";
    case CMD_SET_SCANOUT_BLOB: return "SET_SCANOUT_BLOB";
    case CMD_CTX_CREATE: return "CTX_CREATE";
    case CMD_CTX_DESTROY: return "CTX_DESTROY";
    case CMD_CTX_ATTACH_RESOURCE: return "CTX_ATTACH_RESOURCE";
    case CMD_CTX_DETACH_RESOURCE: return "CTX_DETACH_RESOURCE";
    case CMD_RESOURCE_CREATE_3D: return "RESOURCE_CREATE_3D";
    case CMD_TRANSFER_TO_HOST_3D: return "TRANSFER_TO_HOST_3D";
    case CMD_TRANSFER_FROM_HOST_3D: return "TRANSFER_FROM_HOST_3D";
    case CMD_SUBMIT_3D: return "SUBMIT_3D";
    case CMD_RESOURCE_MAP_BLOB: return "RESOURCE_MAP_BLOB";
    case CMD_RESOURCE_UNMAP_BLOB: return "RESOURCE_UNMAP_BLOB";
    default: return "?";
    }
}

#pragma mark - resources and fences

@interface GPUResource : NSObject
@property uint32_t rid;
@property BOOL virgl;              // owned by virglrenderer (blob / 3D) vs. our 2D stub
@property uint64_t size;
@property int64_t shmOffset;       // -1 when not mapped
@property uint64_t mappedSize;
@property BOOL unmapPending;       // UNMAP_BLOB sent to VZ, completion not yet seen
@property BOOL unrefPending;       // guest unref'd it meanwhile; free after the unmap lands
@property NSMutableArray<VZGuestMemoryMapping *> *backing;  // keeps iov memory alive
@property struct iovec *iov;
@property int iovCount;
@end
@implementation GPUResource
- (void)dealloc { free(_iov); }
@end

@interface PendingFence : NSObject
@property VZVirtioQueueElement *element;
@property uint64_t ringKey;
@property uint64_t fenceId;
@end
@implementation PendingFence
@end

static uint64_t ringKey(uint32_t flags, uint32_t ctx, uint8_t ring) {
    // Global ring = 0; per-context rings are keyed by (ctx, ring_idx) + 1.
    return (flags & FLAG_INFO_RING_IDX) ? (((uint64_t)ctx << 8 | ring) + 1) : 0;
}

#pragma mark - device

@interface GPUDevice : NSObject <VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate>
@property (strong) VZCustomVirtioDevice *device;
@property (strong) dispatch_queue_t queue;
@end

@implementation GPUDevice {
    NSMutableDictionary<NSNumber *, GPUResource *> *_res;
    NSMutableArray<PendingFence *> *_pending;
    NSMutableDictionary<NSNumber *, NSNumber *> *_completed;
    BOOL _virglReady;
    uint32_t _capVersion, _capSize;
    NSMutableDictionary<NSNumber *, NSNumber *> *_counts;
}

static void cbWriteFence(void *cookie, uint32_t fence) {
    GPUDevice *d = (__bridge GPUDevice *)cookie;
    dispatch_async(d.queue, ^{ [d fenceDone:0 fence:fence]; });
}

static void cbWriteContextFence(void *cookie, uint32_t ctx, uint32_t ring, uint64_t fence) {
    GPUDevice *d = (__bridge GPUDevice *)cookie;
    uint64_t key = ringKey(FLAG_INFO_RING_IDX, ctx, (uint8_t)ring);
    dispatch_async(d.queue, ^{ [d fenceDone:key fence:fence]; });
}

static struct virgl_renderer_callbacks gCallbacks = {
    .version = 3,
    .write_fence = cbWriteFence,
    .write_context_fence = cbWriteContextFence,
};

- (instancetype)initWithQueue:(dispatch_queue_t)q {
    if ((self = [super init])) {
        _queue = q;
        _res = [NSMutableDictionary new];
        _pending = [NSMutableArray new];
        _completed = [NSMutableDictionary new];
        _counts = [NSMutableDictionary new];
    }
    return self;
}

- (void)initVirgl {
    int flags = VIRGL_RENDERER_VENUS | VIRGL_RENDERER_NO_VIRGL;
    int r = virgl_renderer_init((__bridge void *)self, flags, &gCallbacks);
    if (r) {
        vlog("virgl_renderer_init failed: %d", r);
        return;
    }
    virgl_renderer_get_cap_set(CAPSET_VENUS, &_capVersion, &_capSize);
    vlog("virglrenderer up: venus capset v%u, %u bytes", _capVersion, _capSize);
    // No virgl_renderer_poll(): this macOS build stubs venus_context_retire_fences and
    // delivers Venus fences through write_context_fence on its own threads.
    _virglReady = _capSize > 0;
}

static void freeVirgl(GPUResource *r) {
    virgl_renderer_resource_detach_iov((int)r.rid, NULL, NULL);
    virgl_renderer_resource_unref(r.rid);
}

#pragma mark VZ delegate callbacks

- (void)customVirtioConfiguration:(VZCustomVirtioDeviceConfiguration *)configuration
                  didCreateDevice:(VZCustomVirtioDevice *)device {
    vlog("custom device created; shm regions=%lu", (unsigned long)device.sharedMemoryRegions.count);
    for (VZVirtioSharedMemoryRegion *r in device.sharedMemoryRegions)
        vlog("  shm region id=%u size=0x%llx", r.regionID, r.size);
    self.device = device;
    device.delegate = self;
    [self initVirgl];
}

- (void)customVirtioDeviceDidAcceptDriverOk:(VZCustomVirtioDevice *)device {
    VZNegotiatedVirtioFeatureSet *f = device.negotiatedFeatures;
    vlog("DRIVER_OK; negotiated subset0=0x%08x subset1=0x%08x", f.subset0, f.subset1);
}
- (void)customVirtioDeviceWillReset:(VZCustomVirtioDevice *)device { vlog("device reset"); }
- (void)customVirtioDeviceWillStop:(VZCustomVirtioDevice *)device { vlog("device stop"); }

- (void)customVirtioDevice:(VZCustomVirtioDevice *)device didReceiveNotificationForQueue:(VZVirtioQueue *)queue {
    VZVirtioQueueElement *el;
    while ((el = [queue nextElement])) {
        if (queue.queueIndex == 1) {  // cursor queue: nothing to answer
            [el returnToQueue];
            continue;
        }
        [self handleControl:el];
    }
}

#pragma mark fences

- (void)fenceDone:(uint64_t)key fence:(uint64_t)fence {
    NSNumber *k = @(key);
    if (fence > _completed[k].unsignedLongLongValue)
        _completed[k] = @(fence);
    NSMutableIndexSet *done = [NSMutableIndexSet new];
    [_pending enumerateObjectsUsingBlock:^(PendingFence *p, NSUInteger i, BOOL *stop) {
        if (p.ringKey == key && p.fenceId <= fence) {
            [p.element returnToQueue];
            [done addIndex:i];
        }
    }];
    [_pending removeObjectsAtIndexes:done];
}

#pragma mark control queue

static void putHdr(NSMutableData *resp, uint32_t type) {
    struct ctrl_hdr h = {.type = type};
    [resp appendBytes:&h length:sizeof h];
}

- (void)handleControl:(VZVirtioQueueElement *)el {
    NSUInteger n = el.readBuffersAvailableByteCount;
    if (n < sizeof(struct ctrl_hdr)) {
        vlog("control: short request (%lu bytes)", (unsigned long)n);
        [el returnToQueue];
        return;
    }
    uint8_t *req = malloc(n);
    NSError *err = nil;
    if (![el readBytesIntoBuffer:req exactLength:n error:&err]) {
        vlog("control: read failed: %s", err.description.UTF8String);
        free(req);
        [el returnToQueue];
        return;
    }
    struct ctrl_hdr hdr;
    memcpy(&hdr, req, sizeof hdr);

    NSNumber *t = @(hdr.type);
    NSUInteger c = _counts[t].unsignedIntegerValue + 1;
    _counts[t] = @(c);
    BOOL chatty = hdr.type == CMD_SET_SCANOUT || hdr.type == CMD_RESOURCE_FLUSH || hdr.type == CMD_TRANSFER_TO_HOST_2D;
    if ((gTrace && !chatty) || c <= 2)
        vlog("q0: %s #%lu req=%luB resp=%luB flags=%u ctx=%u ring=%u fence=%llu", cmdName(hdr.type),
             (unsigned long)c, (unsigned long)n, (unsigned long)el.writeBuffersAvailableByteCount,
             hdr.flags, hdr.ctx_id, hdr.ring_idx, hdr.fence_id);

    NSMutableData *resp = [NSMutableData data];
    BOOL deferred = [self dispatchCommand:&hdr req:req len:n resp:resp element:el];
    free(req);
    if (!deferred)
        [self finish:el hdr:&hdr resp:resp];
}

// Writes the response (echoing fence info), then returns the element now or when
// its fence retires.
- (void)finish:(VZVirtioQueueElement *)el hdr:(const struct ctrl_hdr *)hdr resp:(NSMutableData *)resp {
    struct ctrl_hdr *rh = resp.mutableBytes;
    uint32_t rtype = rh->type;
    if (rtype >= RESP_ERR_UNSPEC)
        vlog("q0: %s -> error 0x%x", cmdName(hdr->type), rtype);

    BOOL hold = NO;
    if (hdr->flags & FLAG_FENCE) {
        rh->flags = hdr->flags;
        rh->fence_id = hdr->fence_id;
        rh->ctx_id = hdr->ctx_id;
        rh->ring_idx = hdr->ring_idx;
        int r;
        if (hdr->flags & FLAG_INFO_RING_IDX)
            r = virgl_renderer_context_create_fence(hdr->ctx_id, VIRGL_RENDERER_FENCE_FLAG_MERGEABLE,
                                                    hdr->ring_idx, hdr->fence_id);
        else
            r = virgl_renderer_create_fence((int)hdr->fence_id, hdr->ctx_id);
        if (r) {
            vlog("create_fence(ctx=%u ring=%u id=%llu) = %d", hdr->ctx_id, hdr->ring_idx, hdr->fence_id, r);
            rh->type = RESP_ERR_UNSPEC;
        } else {
            uint64_t key = ringKey(hdr->flags, hdr->ctx_id, hdr->ring_idx);
            if (hdr->fence_id > _completed[@(key)].unsignedLongLongValue) {
                PendingFence *p = [PendingFence new];
                p.element = el;
                p.ringKey = key;
                p.fenceId = hdr->fence_id;
                [_pending addObject:p];
                hold = YES;
            }
        }
    }
    NSUInteger len = MIN(resp.length, el.writeBuffersAvailableByteCount);
    NSError *err = nil;
    if (len && ![el writeBuffer:resp.mutableBytes exactLength:len error:&err])
        vlog("q0: response write failed: %s", err.description.UTF8String);
    if (!hold)
        [el returnToQueue];
}

- (BOOL)buildIov:(GPUResource *)r entries:(const struct mem_entry *)ents count:(uint32_t)nr {
    r.backing = [NSMutableArray arrayWithCapacity:nr];
    free(r.iov);
    r.iov = calloc(nr ? nr : 1, sizeof(struct iovec));
    r.iovCount = 0;
    for (uint32_t i = 0; i < nr; i++) {
        VZGuestMemoryMapping *m = [_device guestMemoryMappingAtPhysicalAddress:ents[i].addr length:ents[i].length];
        if (!m) {
            vlog("no guest mapping for gpa=0x%llx len=%u", ents[i].addr, ents[i].length);
            return NO;
        }
        [r.backing addObject:m];
        r.iov[i] = (struct iovec){m.mutableBytes, ents[i].length};
        r.iovCount = i + 1;
    }
    return YES;
}

#define NEED(sz)                                                    \
    do {                                                            \
        if (len < (sz)) {                                           \
            putHdr(resp, RESP_ERR_INVALID_PARAMETER);               \
            return NO;                                              \
        }                                                           \
    } while (0)
#define U32(off) (*(const uint32_t *)(req + (off)))
#define U64(off) (*(const uint64_t *)(req + (off)))

// Returns YES if the response will be produced asynchronously.
- (BOOL)dispatchCommand:(struct ctrl_hdr *)hdr req:(const uint8_t *)req len:(NSUInteger)len
                   resp:(NSMutableData *)resp element:(VZVirtioQueueElement *)el {
    switch (hdr->type) {
    case CMD_GET_DISPLAY_INFO: {
        putHdr(resp, RESP_OK_DISPLAY_INFO);
        uint32_t modes[16 * 6] = {0};
        modes[2] = 1280, modes[3] = 800, modes[4] = 1;  // rect{x,y,w,h}, enabled, flags
        [resp appendBytes:modes length:sizeof modes];
        return NO;
    }
    case CMD_GET_CAPSET_INFO: {
        NEED(32);
        if (U32(24) != 0 || !_virglReady) {
            putHdr(resp, RESP_ERR_INVALID_PARAMETER);
            return NO;
        }
        putHdr(resp, RESP_OK_CAPSET_INFO);
        uint32_t info[4] = {CAPSET_VENUS, _capVersion, _capSize, 0};
        [resp appendBytes:info length:sizeof info];
        return NO;
    }
    case CMD_GET_CAPSET: {
        NEED(32);
        if (U32(24) != CAPSET_VENUS || U32(28) > _capVersion) {
            putHdr(resp, RESP_ERR_INVALID_PARAMETER);
            return NO;
        }
        putHdr(resp, RESP_OK_CAPSET);
        NSMutableData *caps = [NSMutableData dataWithLength:_capSize];
        virgl_renderer_fill_caps(CAPSET_VENUS, U32(28), caps.mutableBytes);
        [resp appendData:caps];
        return NO;
    }
    case CMD_CTX_CREATE: {
        NEED(96);
        uint32_t nlen = MIN(U32(24), 64u), init = U32(28);
        const char *name = (const char *)req + 32;
        int r = init ? virgl_renderer_context_create_with_flags(hdr->ctx_id, init, nlen, name)
                     : virgl_renderer_context_create(hdr->ctx_id, nlen, name);
        vlog("CTX_CREATE ctx=%u init=0x%x name=%.*s -> %d", hdr->ctx_id, init, (int)nlen, name, r);
        putHdr(resp, r ? RESP_ERR_UNSPEC : RESP_OK_NODATA);
        return NO;
    }
    case CMD_CTX_DESTROY:
        virgl_renderer_context_destroy(hdr->ctx_id);
        putHdr(resp, RESP_OK_NODATA);
        return NO;
    case CMD_CTX_ATTACH_RESOURCE:
    case CMD_CTX_DETACH_RESOURCE: {
        NEED(32);
        GPUResource *r = _res[@(U32(24))];
        if (r.virgl) {
            if (hdr->type == CMD_CTX_ATTACH_RESOURCE)
                virgl_renderer_ctx_attach_resource((int)hdr->ctx_id, (int)r.rid);
            else
                virgl_renderer_ctx_detach_resource((int)hdr->ctx_id, (int)r.rid);
        }
        putHdr(resp, RESP_OK_NODATA);
        return NO;
    }
    case CMD_SUBMIT_3D: {
        NEED(32);
        uint32_t size = U32(24), nin = U32(28);  // newer kernels put num_in_fences in the padding word
        size_t off = 32 + (size_t)nin * 8;
        NEED(off + size);
        void *cmd = malloc(size ? size : 4);
        memcpy(cmd, req + off, size);
        int r = virgl_renderer_submit_cmd(cmd, (int)hdr->ctx_id, (int)(size / 4));
        free(cmd);
        if (r)
            vlog("SUBMIT_3D ctx=%u size=%u -> %d", hdr->ctx_id, size, r);
        putHdr(resp, r ? RESP_ERR_INVALID_PARAMETER : RESP_OK_NODATA);
        return NO;
    }
    case CMD_RESOURCE_CREATE_2D: {
        NEED(40);
        GPUResource *r = [GPUResource new];
        r.rid = U32(24);
        r.shmOffset = -1;
        _res[@(r.rid)] = r;
        putHdr(resp, RESP_OK_NODATA);
        return NO;
    }
    case CMD_RESOURCE_CREATE_3D:
        // NO_VIRGL: there is no virgl (GL) renderer behind 3D resources.
        putHdr(resp, RESP_ERR_UNSPEC);
        return NO;
    case CMD_RESOURCE_CREATE_BLOB: {
        NEED(56);
        uint32_t rid = U32(24), mem = U32(28), bflags = U32(32), nr = U32(36);
        uint64_t blobId = U64(40), size = U64(48);
        NEED(56 + (size_t)nr * sizeof(struct mem_entry));
        GPUResource *r = [GPUResource new];
        r.rid = rid;
        r.virgl = YES;
        r.size = size;
        r.shmOffset = -1;
        if (mem != BLOB_MEM_HOST3D &&
            ![self buildIov:r entries:(const struct mem_entry *)(req + 56) count:nr]) {
            putHdr(resp, RESP_ERR_UNSPEC);
            return NO;
        }
        struct virgl_renderer_resource_create_blob_args a = {
            .res_handle = rid, .ctx_id = hdr->ctx_id, .blob_mem = mem, .blob_flags = bflags,
            .blob_id = blobId, .size = size, .iovecs = r.iov, .num_iovs = (uint32_t)r.iovCount,
        };
        int rc = virgl_renderer_resource_create_blob(&a);
        if (gTrace || rc)
            vlog("CREATE_BLOB rid=%u mem=%u flags=0x%x id=%llu size=0x%llx nr=%u -> %d", rid, mem, bflags,
                 blobId, size, nr, rc);
        if (rc) {
            putHdr(resp, RESP_ERR_UNSPEC);
            return NO;
        }
        _res[@(rid)] = r;
        putHdr(resp, RESP_OK_NODATA);
        return NO;
    }
    case CMD_RESOURCE_ATTACH_BACKING: {
        NEED(32);
        GPUResource *r = _res[@(U32(24))];
        uint32_t nr = U32(28);
        NEED(32 + (size_t)nr * sizeof(struct mem_entry));
        if (!r) {
            putHdr(resp, RESP_ERR_INVALID_RESOURCE_ID);
            return NO;
        }
        BOOL ok = [self buildIov:r entries:(const struct mem_entry *)(req + 32) count:nr];
        if (ok && r.virgl)
            ok = virgl_renderer_resource_attach_iov((int)r.rid, r.iov, r.iovCount) == 0;
        putHdr(resp, ok ? RESP_OK_NODATA : RESP_ERR_UNSPEC);
        return NO;
    }
    case CMD_RESOURCE_DETACH_BACKING: {
        NEED(32);
        GPUResource *r = _res[@(U32(24))];
        if (r.virgl)
            virgl_renderer_resource_detach_iov((int)r.rid, NULL, NULL);
        r.backing = nil;
        r.iovCount = 0;
        putHdr(resp, RESP_OK_NODATA);
        return NO;
    }
    case CMD_TRANSFER_TO_HOST_3D:
    case CMD_TRANSFER_FROM_HOST_3D: {
        NEED(72);
        GPUResource *r = _res[@(U32(56))];
        if (!r.virgl) {
            putHdr(resp, RESP_ERR_INVALID_RESOURCE_ID);
            return NO;
        }
        struct virgl_box box;
        memcpy(&box, req + 24, sizeof box);
        int rc = hdr->type == CMD_TRANSFER_TO_HOST_3D
                     ? virgl_renderer_transfer_write_iov(r.rid, hdr->ctx_id, (int)U32(60), U32(64), U32(68), &box,
                                                         U64(48), NULL, 0)
                     : virgl_renderer_transfer_read_iov(r.rid, hdr->ctx_id, U32(60), U32(64), U32(68), &box,
                                                        U64(48), NULL, 0);
        putHdr(resp, rc ? RESP_ERR_UNSPEC : RESP_OK_NODATA);
        return NO;
    }
    case CMD_RESOURCE_MAP_BLOB:
        NEED(40);
        return [self mapBlob:U32(24) offset:U64(32) hdr:hdr resp:resp element:el];
    case CMD_RESOURCE_UNMAP_BLOB:
        NEED(32);
        return [self unmapBlob:U32(24) hdr:hdr resp:resp element:el];
    case CMD_RESOURCE_UNREF: {
        NEED(32);
        GPUResource *r = _res[@(U32(24))];
        if (!r) {
            putHdr(resp, RESP_ERR_INVALID_RESOURCE_ID);
            return NO;
        }
        [_res removeObjectForKey:@(r.rid)];
        if (r.unmapPending) {
            // The guest doesn't wait for UNMAP before UNREF; keep the host memory alive
            // until VZ has actually removed it from the guest.
            r.unrefPending = YES;
        } else {
            if (r.shmOffset >= 0)
                vlog("UNREF rid=%u while still mapped at 0x%llx (no unmap requested)", r.rid, r.shmOffset);
            if (r.virgl)
                freeVirgl(r);
        }
        putHdr(resp, RESP_OK_NODATA);
        return NO;
    }
    case CMD_SET_SCANOUT:
    case CMD_SET_SCANOUT_BLOB:
    case CMD_RESOURCE_FLUSH:
    case CMD_TRANSFER_TO_HOST_2D:
        // No display backend yet: accept and drop.
        putHdr(resp, RESP_OK_NODATA);
        return NO;
    default:
        putHdr(resp, RESP_ERR_UNSPEC);
        return NO;
    }
}

- (VZVirtioSharedMemoryRegion *)hostVisible {
    for (VZVirtioSharedMemoryRegion *r in _device.sharedMemoryRegions)
        if (r.regionID == SHM_ID_HOST_VISIBLE)
            return r;
    return nil;
}

- (BOOL)mapBlob:(uint32_t)rid offset:(uint64_t)offset hdr:(struct ctrl_hdr *)hdr
           resp:(NSMutableData *)resp element:(VZVirtioQueueElement *)el {
    GPUResource *r = _res[@(rid)];
    VZVirtioSharedMemoryRegion *shm = [self hostVisible];
    uint32_t mapInfo = 0;
    uint64_t ptr = 0;
    if (!r.virgl || !shm) {
        putHdr(resp, RESP_ERR_INVALID_RESOURCE_ID);
        return NO;
    }
    if (virgl_renderer_resource_get_map_info(rid, &mapInfo) || virgl_renderer_resource_get_map_ptr(rid, &ptr) || !ptr) {
        vlog("MAP_BLOB rid=%u: no map info/ptr", rid);
        putHdr(resp, RESP_ERR_UNSPEC);
        return NO;
    }
    uint64_t size = (r.size + BLOB_ALIGN - 1) & ~(BLOB_ALIGN - 1);
    if ((ptr | offset) & (BLOB_ALIGN - 1) || offset + size > shm.size) {
        vlog("MAP_BLOB rid=%u: misaligned or out of range ptr=0x%llx offset=0x%llx size=0x%llx", rid, ptr, offset, size);
        putHdr(resp, RESP_ERR_INVALID_PARAMETER);
        return NO;
    }
    if (gTrace)
        vlog("MAP_BLOB rid=%u ptr=0x%llx -> shm+0x%llx size=0x%llx info=0x%x", rid, ptr, offset, size, mapInfo);
    struct ctrl_hdr h = *hdr;
    [shm mapMemory:(void *)ptr atOffset:offset size:size completionHandler:^(NSError *error) {
        dispatch_async(self.queue, ^{
            NSMutableData *out = [NSMutableData data];
            if (error) {
                vlog("MAP_BLOB rid=%u mapMemory failed: %s", rid, error.description.UTF8String);
                putHdr(out, RESP_ERR_UNSPEC);
            } else {
                r.shmOffset = (int64_t)offset;
                r.mappedSize = size;
                putHdr(out, RESP_OK_MAP_INFO);
                uint32_t mi[2] = {mapInfo & VIRGL_RENDERER_MAP_CACHE_MASK, 0};
                [out appendBytes:mi length:sizeof mi];
            }
            struct ctrl_hdr hh = h;
            [self finish:el hdr:&hh resp:out];
        });
    }];
    return YES;
}

- (BOOL)unmapBlob:(uint32_t)rid hdr:(struct ctrl_hdr *)hdr resp:(NSMutableData *)resp
          element:(VZVirtioQueueElement *)el {
    GPUResource *r = _res[@(rid)];
    VZVirtioSharedMemoryRegion *shm = [self hostVisible];
    if (!r || r.shmOffset < 0 || r.unmapPending || !shm) {
        putHdr(resp, RESP_ERR_INVALID_PARAMETER);
        return NO;
    }
    struct ctrl_hdr h = *hdr;
    r.unmapPending = YES;
    [shm unmapMemoryAtOffset:(uint64_t)r.shmOffset size:r.mappedSize completionHandler:^(NSError *error) {
        dispatch_async(self.queue, ^{
            NSMutableData *out = [NSMutableData data];
            if (error)
                vlog("UNMAP_BLOB rid=%u failed: %s", rid, error.description.UTF8String);
            r.shmOffset = -1;
            r.unmapPending = NO;
            if (r.unrefPending)
                freeVirgl(r);
            putHdr(out, error ? RESP_ERR_UNSPEC : RESP_OK_NODATA);
            struct ctrl_hdr hh = h;
            [self finish:el hdr:&hh resp:out];
        });
    }];
    return YES;
}

@end

#pragma mark - VM

@interface VMDelegate : NSObject <VZVirtualMachineDelegate>
@end
@implementation VMDelegate
- (void)guestDidStopVirtualMachine:(VZVirtualMachine *)vm {
    vlog("guest stopped");
    exit(0);
}
- (void)virtualMachine:(VZVirtualMachine *)vm didStopWithError:(NSError *)error {
    vlog("VM stopped with error: %s", error.description.UTF8String);
    exit(1);
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: vzgpu <vmdir>\n");
            return 2;
        }
        setvbuf(stderr, NULL, _IOLBF, 0);
        gTrace = getenv("VZGPU_TRACE") != NULL;
        NSURL *dir = [NSURL fileURLWithPath:@(argv[1])];
        NSURL *run = [dir URLByAppendingPathComponent:@"run"];
        [[NSFileManager defaultManager] createDirectoryAtURL:run withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *cmdline = @"console=hvc0 root=UUID=96ff3c27-158a-4f65-a5a8-2c3344757f97 rootflags=subvol=root rw "
                             "systemd.unit=multi-user.target systemd.debug_shell=hvc0 "
                             "systemd.mask=serial-getty@hvc0.service systemd.firstboot=off";
        if (getenv("VZGPU_CMDLINE"))
            cmdline = @(getenv("VZGPU_CMDLINE"));
        // SSH: hand <vmdir>/ssh/id_ed25519.pub to systemd as the root authorized_keys
        // credential and pull in sshd, so the guest disk needs no edits.
        NSData *pub = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"ssh/id_ed25519.pub"]];
        if (pub)
            cmdline = [cmdline stringByAppendingFormat:@" systemd.set_credential_binary=ssh.authorized_keys.root:%@"
                                                        " systemd.wants=sshd.service",
                                                       [pub base64EncodedStringWithOptions:0]];

        VZLinuxBootLoader *boot = [[VZLinuxBootLoader alloc] initWithKernelURL:[dir URLByAppendingPathComponent:@"Image"]];
        boot.initialRamdiskURL = [dir URLByAppendingPathComponent:@"initramfs.img"];
        boot.commandLine = cmdline;

        VZVirtualMachineConfiguration *cfg = [VZVirtualMachineConfiguration new];
        cfg.bootLoader = boot;
        cfg.platform = [[VZGenericPlatformConfiguration alloc] init];
        cfg.CPUCount = 4;
        cfg.memorySize = 4ull << 30;

        NSError *err = nil;
        VZDiskImageStorageDeviceAttachment *disk =
            [[VZDiskImageStorageDeviceAttachment alloc] initWithURL:[dir URLByAppendingPathComponent:@"disk.img"]
                                                           readOnly:NO
                                                              error:&err];
        if (!disk) {
            vlog("disk: %s", err.description.UTF8String);
            return 1;
        }
        cfg.storageDevices = @[ [[VZVirtioBlockDeviceConfiguration alloc] initWithAttachment:disk] ];
        VZVirtioNetworkDeviceConfiguration *net = [[VZVirtioNetworkDeviceConfiguration alloc] init];
        net.attachment = [[VZNATNetworkDeviceAttachment alloc] init];
        net.MACAddress = [[VZMACAddress alloc] initWithString:@"02:76:7a:67:70:75"];  // tools/gssh finds the lease by this
        cfg.networkDevices = @[ net ];
        cfg.entropyDevices = @[ [[VZVirtioEntropyDeviceConfiguration alloc] init] ];

        // Console: input from a FIFO (opened O_RDWR so it never sees EOF), output to a log.
        NSString *fifo = [run URLByAppendingPathComponent:@"in.fifo"].path;
        unlink(fifo.fileSystemRepresentation);
        mkfifo(fifo.fileSystemRepresentation, 0600);
        int inFD = open(fifo.fileSystemRepresentation, O_RDWR);
        NSString *logPath = [run URLByAppendingPathComponent:@"console.log"].path;
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
        VZVirtioConsoleDeviceSerialPortConfiguration *serial = [[VZVirtioConsoleDeviceSerialPortConfiguration alloc] init];
        serial.attachment = [[VZFileHandleSerialPortAttachment alloc]
            initWithFileHandleForReading:[[NSFileHandle alloc] initWithFileDescriptor:inFD]
                    fileHandleForWriting:[NSFileHandle fileHandleForWritingAtPath:logPath]];
        cfg.serialPorts = @[ serial ];

        // virtio-gpu: control + cursor queues, display-controller class, Venus-only.
        dispatch_queue_t gq = dispatch_queue_create("vzgpu.device", DISPATCH_QUEUE_SERIAL);
        GPUDevice *gpu = [[GPUDevice alloc] initWithQueue:gq];
        VZCustomVirtioDeviceConfiguration *g = [VZCustomVirtioDeviceConfiguration new];
        g.deviceID = 16;
        g.PCIClassID = 0x03;
        g.PCISubclassID = 0x80;
        g.virtioQueueCount = 2;
        g.optionalFeatures.subset0 = 1u << VIRTIO_GPU_F_VIRGL | 1u << VIRTIO_GPU_F_RESOURCE_BLOB |
                                     1u << VIRTIO_GPU_F_CONTEXT_INIT | 1u << VIRTIO_GPU_F_BLOB_ALIGNMENT;
        uint32_t devcfg[5] = {0, 0, 1 /* scanouts */, 1 /* capsets */, (uint32_t)BLOB_ALIGN};
        g.deviceSpecificConfiguration =
            [[VZVirtioDeviceSpecificConfiguration alloc] initWithConfigurationData:[NSData dataWithBytes:devcfg length:sizeof devcfg]];
        g.sharedMemoryRegions = @[ [[VZVirtioSharedMemoryRegionConfiguration alloc] initWithRegionID:SHM_ID_HOST_VISIBLE size:SHM_SIZE] ];
        g.provider = [[VZCustomVirtioDeviceDelegateProvider alloc] initWithDeviceQueue:gq delegate:gpu];
        cfg.customVirtioDevices = @[ g ];

        if (![cfg validateWithError:&err]) {
            vlog("config validation failed: %s", err.description.UTF8String);
            return 1;
        }
        vlog("config valid; cmdline: %s", cmdline.UTF8String);

        VZVirtualMachine *vm = [[VZVirtualMachine alloc] initWithConfiguration:cfg];
        VMDelegate *vd = [VMDelegate new];
        vm.delegate = vd;
        [vm startWithCompletionHandler:^(NSError *e) {
            if (e) {
                vlog("start failed: %s", e.description.UTF8String);
                exit(1);
            }
            vlog("VM started");
        }];
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
