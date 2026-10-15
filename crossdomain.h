// Cross-domain (virtio-gpu capset 5) context: proxies a guest Wayland connection
// (sommelier --virtgpu-channel) to a Wayland compositor on the Mac.
#import <Foundation/Foundation.h>
#include <sys/uio.h>

#define CAPSET_CROSS_DOMAIN 5

@class VZGuestMemoryMapping;

// The subset of a device resource the cross-domain context needs.
@interface GPUResource : NSObject
@property uint32_t rid;
@property BOOL virgl;              // owned by virglrenderer (blob / 3D)
@property BOOL xdomain;            // host memory owned by a cross-domain context
@property uint64_t size;
@property int64_t shmOffset;       // -1 when not mapped into the host-visible region
@property uint64_t mappedSize;
@property BOOL unmapPending;       // UNMAP_BLOB sent to VZ, completion not yet seen
@property BOOL unrefPending;       // guest unref'd it meanwhile; free after the unmap lands
@property NSMutableArray<VZGuestMemoryMapping *> *backing;  // keeps iov memory alive
@property struct iovec *iov;       // guest memory backing (guest blobs)
@property int iovCount;
@property void *hostPtr;           // xdomain: host mapping exposed to the guest
@property uint64_t hostLen;
@property int hostFd;              // xdomain: fd handed to the compositor (-1 if none)
@end

@protocol CrossDomainHost <NSObject>
- (GPUResource *)resourceForId:(uint32_t)rid;
// Signals the fence that the context consumed for a channel event.
- (void)crossDomainFenceDone:(uint32_t)ctxId ring:(uint8_t)ring fence:(uint64_t)fenceId;
@end

@interface CrossDomainContext : NSObject
+ (NSData *)capabilities;  // capset 5 payload
- (instancetype)initWithHost:(id<CrossDomainHost>)host ctx:(uint32_t)ctxId queue:(dispatch_queue_t)queue;
// Processes a SUBMIT_3D payload. Returns NO on a protocol error.
- (BOOL)submit:(const uint8_t *)cmds length:(size_t)len;
// HOST3D blob creation against an item (image requirements or a received fd).
- (GPUResource *)createBlob:(uint32_t)rid blobId:(uint64_t)blobId size:(uint64_t)size;
// The guest armed a fence on the channel ring: deliver the next event against it.
- (void)armChannelFence:(uint64_t)fenceId;
- (void)close;
@end

void GPUResourceFreeHost(GPUResource *r);
