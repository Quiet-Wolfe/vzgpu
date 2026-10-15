# vzgpu

A virtio-gpu device for Linux guests under Virtualization.framework, built on the
macOS 27 `VZCustomVirtioDevice` API. Target: Venus (guest Mesa) → virglrenderer
in-process → host Vulkan ICD (KosmicKrisp / MoltenVK), plus cross-domain Wayland
passthrough so guest windows become native macOS windows.

## Status

**2026-10-15 — empty-device probe: PASS** (macOS 27.2 / Darwin 27.2.0, M5).
Evidence: `evidence/2026-10-15-empty-device/`.

- Ad-hoc signing with only `com.apple.security.virtualization` is enough for a VM
  with a custom virtio device (`config.validate()` and `start` succeed).
- Fedora 45 Beta (kernel 7.2.0-61.fc45) sees PCI `1af4:1050`, class `0x038000`,
  and `virtio_gpu` binds: `/dev/dri/card0` + `/dev/dri/renderD128`, connector
  `connected`, our 1280x800 mode listed first.
- Control-queue round trips work: `GET_DISPLAY_INFO` answered, the driver then
  issues `RESOURCE_CREATE_2D` / `RESOURCE_ATTACH_BACKING` and fbcon comes up.
- Negotiated features: subset0 `0x30000000` (INDIRECT_DESC, EVENT_IDX), subset1
  `0x5` (VERSION_1, RING_PACKED) — VZ offers packed rings by default.
- `maximumAllowedSharedMemoryRegionCount` = 1 (exactly what virtio-gpu's
  host-visible region needs). Not yet exercised.

## Next

1. Advertise `VIRTIO_GPU_F_VIRGL | RESOURCE_BLOB | CONTEXT_INIT` + host-visible
   SHM region; capset 4 (Venus) → link virglrenderer (Homebrew slp/krun build),
   port the device logic from libkrun `src/devices/src/virtio/gpu/virtio_gpu.rs`.
   Gate: guest `vulkaninfo` shows "Virtio-GPU Venus (Apple M5)".
2. Cross-domain capset (5) for Wayland passthrough → host compositor.

## Running

VM dir (not in git) `~/VMs/fedora45-vzgpu`: `Image` (zboot payload of the
Fedora vmlinuz, zstd-decompressed), `initramfs.img`, `disk.img` (APFS clone of
`~/Downloads/Fedora-Workstation-Disk-45_Beta-1.3.aarch64.raw`).

```
xcrun swiftc -O -o build/vzgpu main.swift
codesign -s - -f --entitlements vzgpu.entitlements build/vzgpu
build/vzgpu ~/VMs/fedora45-vzgpu 2> ~/VMs/fedora45-vzgpu/run/vmm.log
```

Guest console → `run/console.log`; type into the root debug shell (hvc0) with
`printf 'cmd\n' > run/in.fifo`. Default cmdline boots multi-user with
`systemd.debug_shell=hvc0` (root is locked on the Workstation image).
`var.mount` fails under this cmdline (root mounted `ro`) and the boot falls to
emergency mode; the debug shell still works. Not investigated.
