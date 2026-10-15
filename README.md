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

**2026-10-15 — Wayland passthrough: window appears, but tears (not done).**
Cross-domain context (capset 5, `crossdomain.m`, ported from rutabaga_gfx whose macOS
backend is a stub) + stock sommelier `--virtgpu-channel` (built from ChromiumOS source;
Fedora's `cros-sommelier` is only a wrapper) + Cocoa-Way 2.0.3: guest `vkcube` (Venus)
opens a native macOS window at ~55 commits/s. Window buffers are POSIX shm mapped into the
guest and passed to the compositor as the same fd. Evidence:
`evidence/2026-10-15-wayland-window/`.

Open defects:
- **Tearing / stale frames.** sommelier allocates one output buffer per window and reuses
  it as soon as Cocoa-Way sends `wl_buffer.release`, which Cocoa-Way does with each frame
  callback (~17 ms after commit) while it apparently still reads the shm afterwards
  (`sommelier-host-protocol-excerpt.txt`: same `wl_buffer#36` every frame). Protocol-legal
  on the guest side; the early release is the compositor's.
- **VMM abort on Venus context destroy** after `vkcube` exits:
  `venus_context_destroy` → `util_hash_table_remove` → free of an unallocated pointer, in the
  Homebrew (slp) virglrenderer. vulkaninfo / compute contexts destroy cleanly.

The guest's `virtio_gpu` module is rebuilt with `guest/virtio-gpu-blob-roundup.patch`
(`verify_blob()` rounds sizes up to `blob_alignment` instead of `EINVAL`), so userspace
needs no alignment patches; `guest/wl-run` starts sommelier and runs a client.

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

## GTK drawing and resize fixes (2026-10-15)

The old KosmicKrisp from SDK 1.4.350.0 produced striped/transparent GTK Vulkan
frames during rapid resizing; the corruption was present in the incoming SHM
pixels before macOS presentation. Cairo did not reproduce it. The same Vulkan
workload with SDK 1.4.363.0's KosmicKrisp no longer produced those anomalous
frames, and interactive testing confirmed the drawing problem resolved.

Use `tools/run-vm` for the tested configuration: SDK 1.4.363.0's loader and
KosmicKrisp ICD, the local virglrenderer prefix, and `build/vzgpu-venus.fixed`.
The local renderer build addresses the separate context-destroy crash. Set
`VZGPU_VULKAN_SDK` or `VZGPU_BINARY` to explicitly test a different stack.
Start `compositor/target/release/vzcomp` first. An already-running VM must stop
before another is launched; the script does not restart the running VM.

The compositor stages pixels and geometry and publishes them together on display
ticks. Its native and Wayland regression checks are documented in
`compositor/tests/README.md`.

## Running

VM dir (not in git) `~/VMs/fedora45-vzgpu`: `Image` (zboot payload of the Fedora
vmlinuz, zstd-decompressed), `initramfs.img`, `disk.img` (APFS clone of
`~/Downloads/Fedora-Workstation-Disk-45_Beta-1.3.aarch64.raw`), `ssh/id_ed25519`
(throwaway key for this VM).

```
third_party/fetch-virglrenderer.sh   # krunkit virglrenderer + venus fence fix
V=$PWD/third_party/virgl-prefix
xcrun clang -fobjc-arc -O2 -Wall -I$V/include/virgl -L$V/lib -lvirglrenderer -Wl,-rpath,$V/lib \
    -framework Foundation -framework Virtualization -o build/vzgpu-venus vzgpu.m crossdomain.m
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

## virglrenderer fence bugs (fixed in third_party/virglrenderer-venus-fence-race.patch)

The krunkit virglrenderer 0.10.4e (Homebrew `libkrun/krun` tap) has two bugs in
`src/venus_context.c`, found 2026-10-15:

1. **Race → VMM abort.** Venus runs with `VKR_RENDERER_THREAD_SYNC|ASYNC_FENCE_CB`, so
   fences retire on vkr's per-queue sync threads while `submit_fence` runs on the device
   queue, and all the mutexes are commented out. The fence lists get corrupted and
   `venus_context_destroy` frees a garbage pointer (`POINTER_BEING_FREED_WAS_NOT_ALLOCATED`)
   whenever a Venus app exits — the "vkcube kill" crash, and the 13:33 crash during GTK tests.
2. **Fences signalled early.** The retire callback compared the guest `fence_id` with a
   private per-timeline seqno (0, 1, 2 …), so any completed fence retired *every* pending
   fence on that ring. The guest was told GPU work was done before it was.
   Suspected contributor to GTK's half-drawn first frames after resize (Vulkan renderer only).

Fix: a per-context fence mutex (not held across `vkr_renderer_submit_fence`, since ring 0
retires synchronously inside it), a lock on the context list, retire by `fence_id <=`
reported id, and free pending timeline fences on destroy.

## Dock icons, app names, fullscreen Spaces (2026-10-15)

- The VMM shares `~/Library/Application Support/vzgpu/share` as virtiofs tag `vzgpu`.
  In the guest, `guest/vz-export-apps` (installed as `/usr/local/bin/vz-export-apps`)
  writes `apps/<desktop-id>/{name,icon.svg|icon.png}` for every `.desktop` file (108 on F45).
- vzcomp strips sommelier's `org.chromium.guest_os.termina.wayland.` app_id prefix and looks
  the app up there (exact, case-insensitive, then last dotted component). Verified with GNOME
  Calculator: its icon in the Dock and "Calculator" in the menu bar.
- `NSApp.applicationIconImage` set right after the activation-policy change is lost (the Dock
  makes the tile afterwards and uses the bundle icon); it is re-applied 300 ms later.
- All app processes share one bundle, so the menu-bar/Cmd-Tab name is set per process with
  LaunchServices' private `_LSSetApplicationInformationItem(_kLSDisplayNameKey)`.
- Fullscreen: `weston-fullscreen -f` gets `windowDidEnterFullScreen` and a 1512x949
  configure (the notched display below the camera housing) in its own Space. macOS 14+
  cooperative activation means the user is not switched to that Space when the app was
  launched from elsewhere; it shows up as a Dock tile / Mission Control Space.
- Runtime toggle verified by hand (weston-fullscreen `f`): one Space transition per press.
  A key-up swallowed by the Space animation used to leave the client auto-repeating `f`
  (fullscreen loop); held keys are now released on resign-key and fullscreen transitions.
- Open: apps with no `.desktop` file show the generic blank icon instead of the letter
  placeholder (the drawingHandler image isn't picked up by the Dock).

## One-command install (2026-10-15)

```
tools/vzgpu install -D Fedora      # ~5 min: 550 MB download, unpack, 20 s first boot
tools/vzgpu shell sudo dnf install -y gnome-calculator
tools/vzgpu run gnome-calculator   # opens as a macOS app with its own Dock icon
```

Verified end to end on 2026-10-15 from a stock `Fedora-Cloud-Base-AmazonEC2-45_Beta-1.3`
image: no Homebrew, no cloud-init, no edits to the image before boot.

- **Kernel** (`kernel/`): our `7.2.11-vzgpu`, Fedora's config reduced with `localyesconfig`
  to `lsmod.txt` and everything built in (virtio incl. the blob round-up patch, virtiofs,
  containers, netfilter, WireGuard, common filesystems): no modules, no initramfs, one kernel
  for every distro (like WSL). Cross-compiles on x86 Fedora in 3.5 min. Root is
  `PARTUUID=`; `systemd-growfs-root`/`repart` are masked because without an initramfs btrfs
  reports `/dev/root` (and `rootflags=device=` panics: no /dev yet).
- **First boot**: the VMM passes `guest/units/vzgpu-firstboot.service` as a
  `systemd.extra-unit.*` credential (systemd >= 256). It mounts the share and runs
  `guest/install-guest.sh <mac user>`: Mesa, sommelier (prebuilt) as a lingering user
  service, Wayland env, share mount, path-triggered app export, user + sudo + SSH key,
  root partition/filesystem growth, the Mac's timezone. `systemd-firstboot` must be masked:
  the cloud image prompts on hvc0 for a root password even with `systemd.firstboot=off`.
- **CLI** (`tools/vzgpu`, helper `tools/vzgpu-tool.m`): downloads, checks Fedora's SHA-256,
  unpacks .xz with Apple's Compression framework (byte-identical to Python lzma), sparse
  64 GB disk, root PARTUUID from GPT/MBR, SSH key, vzcomp LaunchAgent
  (`dev.vzgpu.vzcomp`). `install` resumes after unpacking if the first boot fails.
- Not yet: other distros, more than one guest at a time (fixed MAC), packaging the
  binaries (the CLI uses this checkout's `build/`), a downloadable kernel release.

## Native cursors (2026-10-15)

sommelier didn't support `wp_cursor_shape_v1`, so GTK drew its Adwaita cursors as images.
`guest/sommelier-cursor-shape.patch` passes the protocol through; vzcomp maps the CSS cursor
names to NSCursor (macOS 15 frame-resize/column/row/zoom cursors included). Apps that set
their own cursor image keep it. Verified by Jayden: native arrow, I-beam and resize cursors
over GNOME Calculator. `guest/build-sommelier.sh` rebuilds `guest/payload/sommelier`.

## Launchers in /Applications/<distro>/ (2026-10-15)

Every app a menu would show (no `NoDisplay`/`Hidden`/`Terminal` entries) gets
`/Applications/Fedora/<Name>.app`, so Spotlight, Launchpad and Finder can start it.
- Guest: `vz-export-apps` also writes `apps/<id>/desktop` (the .desktop path), prunes
  uninstalled apps and touches `apps/.stamp`. Its path unit waits 2 s before exporting: the
  first file a dnf transaction writes fires the trigger, and the .desktop file used to land
  after the (millisecond) export had finished.
- Mac: LaunchAgent `dev.vzgpu.sync-apps` watches `share/apps` and runs `vzgpu sync-apps`:
  Info.plist, `.icns` (`vzgpu-tool icns`, Apple's 1024 grid), a background-only stub that
  runs `vzgpu launch <id>` (= `gio launch <desktop file>` in the guest, which parses `Exec=`).
  Only bundles with our `Contents/Resources/vzgpu-id` marker are replaced or removed.
- Verified: `open` on Calculator.app and Text Editor.app starts them (booting the guest if
  needed); `dnf install/remove gnome-text-editor` adds/removes its launcher within seconds;
  Spotlight indexes both.
- Known: a launcher pinned in the Dock shows next to the running app's own tile (the window
  belongs to a vzcomp process). Fix later: hand the Wayland connection to the launcher.
- One guest at a time: `share/apps` is shared, not per distro.

## One Dock tile per app: launcher handoff (2026-10-15)

A launcher bundle's executable is a copy of vzcomp (`compositor/src/handoff.rs`). Opened from
Finder/Spotlight/Launchpad/the Dock it claims the app's Wayland connection on the broker's
control socket (`$TMPDIR/vzcomp/control`), starts the app (`vzgpu launch`), receives the
connection by SCM_RIGHTS and serves it itself: Dock tile, pinning, Cmd-Tab and name are the
bundle's. The app's own connection always arrives before its short-lived helper connections;
a claimed connection that closes without a window re-execs the launcher (same pid) to claim
again. Re-opening a running app is handled by LaunchServices (same bundle); apps started
elsewhere leave `$TMPDIR/vzcomp/apps/<id>.pid` so the launcher activates them instead.
Launch to window: 1.4 s with the VM running.

Found on the way:
- **Local Network privacy.** A new (ad-hoc) app bundle can't reach the VM's 192.168.65.x
  address: `connect: No route to host`, no prompt in the log. The CLI now reaches the guest's
  sshd over **vsock**: the VMM has a virtio-socket device and relays `<vm>/run/ssh.sock` to
  guest port 22, where systemd-ssh-generator listens automatically in a VM (an explicit
  `systemd.ssh_listen=vsock::22` makes a second, failing unit). Also independent of DHCP and VPN.
- **Window dragging** never worked for client-drawn windows: `xdg_toplevel.move` arrives after
  a guest round trip, too late for `performWindowDragWithEvent:` ("Window move completed
  without beginning"). vzcomp tracks the move itself, like interactive resize.
- `vzgpu run` must detach the app from SSH (`setsid -f … </dev/null`) or the command never
  returns. `GDK_DEBUG=no-portals`: without a GNOME session GTK waited seconds for the portal.
