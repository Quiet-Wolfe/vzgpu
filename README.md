# vzgpu

A virtio-gpu device for Linux guests under Virtualization.framework, built on the
macOS 27 `VZCustomVirtioDevice` API. Target: Venus (guest Mesa) → virglrenderer
in-process → host Vulkan ICD (KosmicKrisp / MoltenVK), plus cross-domain Wayland
passthrough so guest windows become native macOS windows.

## Status

**2026-10-15 — Venus gate: PASS.** Guest `vulkaninfo` reports
`deviceName = Virtio-GPU Venus (Apple M5)`, `driverName = venus` (Mesa 26.2.4).
Evidence: `evidence/2026-10-15-venus-vulkaninfo/`.

What is verified (Fedora 45 Beta guest, kernel 7.2.0-61.fc45, macOS 27.2, M5):
- Device advertises VIRGL | RESOURCE_BLOB | CONTEXT_INIT | BLOB_ALIGNMENT, one
  capset (Venus, id 4, v0, 156 bytes), 8 GiB host-visible SHM region (id 1).
  Guest kernel: `+virgl +resource_blob +host_visible +context_init +blob_alignment`.
- Venus contexts (`CTX_CREATE init=0x4`), HOST3D blobs, `RESOURCE_MAP_BLOB` through
  `VZVirtioSharedMemoryRegion mapMemory:` (16 KiB-aligned), unmap, unref.
- Host ICD is swappable with `VK_DRIVER_FILES` on the VMM: with
  `libkosmickrisp_icd.json` the process loads `libvulkan_kosmickrisp.dylib` and the
  guest still sees the device. Guest `apiVersion` is 1.3.0 under both MoltenVK and
  KosmicKrisp, so the ceiling is not the ICD — likely the Venus host in Homebrew
  virglrenderer 0.10.4e (not yet confirmed).

**2026-10-15 — compute smoke test: PASS** (host ICD KosmicKrisp, Teleport off).
elfuse's `venus-vulkan-smoke.c` dispatches `venus-fill.comp` (`values[i] = i*3+7`, 64
lanes) into host-visible memory, `vkQueueWaitIdle`s, maps and checks every value:
`Venus Vulkan compute dispatch ok`, exit 0, 54 ms. During the run the guest sent 10
`SUBMIT_3D`, 3 of them with per-context fences (`FENCE|RING_IDX`, rings 0 and 1),
4 HOST3D blobs mapped/unmapped through the SHM region. Evidence:
`evidence/2026-10-15-venus-compute/`. Not distinguished: whether those fences were
held until `write_context_fence` or had already signalled at submit.

### Findings

- **Blob alignment needs Mesa ≥ 26.2.4.** VZ maps host memory at 16 KiB granularity,
  so the device sets `blob_alignment = 16384`. The kernel's `verify_blob()` then
  rejects blob sizes that are not multiples of it (`EINVAL` from
  `DRM_IOCTL_VIRTGPU_RESOURCE_CREATE_BLOB`, surfaced as `vkCreateInstance …
  ERROR_OUT_OF_HOST_MEMORY`). Mesa reads `VIRTGPU_PARAM_BLOB_ALIGNMENT` and rounds up
  from 26.2.4; Fedora's 26.2.0 does not. 26.2.4 is in `updates-testing`.
- **No `virgl_renderer_poll()`.** This virglrenderer build stubs
  `venus_context_retire_fences` (prints UNIMPLEMENTED every call); Venus fences arrive
  via `write_context_fence` from virglrenderer's own threads. (Same as elfuse.)
- **The guest sends UNREF without waiting for UNMAP.** `mapMemory`/`unmapMemory` complete
  asynchronously, so the device defers `virgl_renderer_resource_unref` until the unmap
  completion has run — otherwise host memory could be freed while still guest-mapped.
- VZ negotiates packed virtqueues (subset1 bit 34) by default.
- **Guest networking under a full-tunnel VPN:** with Teleport (`utun4`, routes 0/1 +
  128/1) up, VZ NAT forwards guest packets into `utun4` without translating the
  source (192.168.65.x), and the VPN drops them. DNS still works. Packet capture:
  SYNs on `bridge101` and `utun4`, nothing on `en0`, no replies.
- **Rosetta needs a 4 KiB-page guest kernel.** Same guest, same static x86_64 busybox,
  Rosetta via `VZLinuxRosettaDirectoryShare` (virtiofs tag `rosetta`): on Fedora's
  7.2.0-61 (4 KiB) it runs; on Asahi's `kernel-16k` 7.1.13-402 (16 KiB) every x86_64
  binary dies with `rosetta error: unable to mmap ELF: 22`. x86_64 ELF segments are
  4 KiB-aligned. So 16 KiB guest pages are not an escape from blob alignment; fix the
  size rounding in the guest's virtio_gpu instead. Evidence:
  `evidence/2026-10-15-rosetta-page-size/`. (Fedora itself no longer builds kernel-16k.)
- The Fedora 45 Beta Workstation raw image's fstab mounts `subvol=var`/`subvol=home`
  but those subvolumes are nested under `root`; the clone has those lines commented.
- The hvc0 serial console stops accepting input after a while (VZ stops draining
  the FIFO; cause not found). Use SSH.

## Running

VM dir (not in git) `~/VMs/fedora45-vzgpu`: `Image` (zboot payload of the Fedora
vmlinuz, zstd-decompressed), `initramfs.img`, `disk.img` (APFS clone of
`~/Downloads/Fedora-Workstation-Disk-45_Beta-1.3.aarch64.raw`), `ssh/id_ed25519`
(throwaway key for this VM).

```
V=/opt/homebrew/opt/virglrenderer
xcrun clang -fobjc-arc -O2 -Wall -I$V/include/virgl -L$V/lib -lvirglrenderer \
    -framework Foundation -framework Virtualization -o build/vzgpu-venus vzgpu.m
codesign -s - -f --entitlements vzgpu.entitlements build/vzgpu-venus
build/vzgpu-venus ~/VMs/fedora45-vzgpu 2> ~/VMs/fedora45-vzgpu/run/vmm.log
```

- `tools/gssh [ssh opts] [cmd]` — SSH as root. The key goes in on the kernel command
  line as the `ssh.authorized_keys.root` systemd credential (no disk edits); the IP
  comes from `/var/db/dhcpd_leases` via the fixed MAC `02:76:7a:67:70:75`.
- `tools/console` — interactive hvc0 console (Ctrl-] quits); `tools/gsh` — one-shot.
- `VZGPU_TRACE=1` logs every control-queue command; `VK_DRIVER_FILES=…` picks the host ICD.
- Guest package installs while the VPN is up: `tools/gssh -R 18080 'dnf
  --setopt=proxy=socks5h://127.0.0.1:18080 …'` (needs guest `setenforce 0`; Fedora 45's
  policy denies sshd-session binding forward ports). Workaround, not a fix.
