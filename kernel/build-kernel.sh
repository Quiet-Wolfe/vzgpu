#!/bin/bash
# build-kernel.sh — build the vzgpu guest kernel (arm64 Image). Runs on any Fedora host;
# on x86 it cross-compiles (dnf install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
# make flex bison bc perl elfutils-libelf-devel openssl-devel). Output: $W/out/{Image,config}.
#
# Like WSL's kernel: one kernel for every distro, no modules and no initramfs. Everything a VM
# needs is built in, so the distro's disk never has to match our kernel version. The config is
# Fedora's (fedora-*.config), reduced with `localyesconfig` to the modules in lsmod.txt (made
# built-in), plus the options forced below.
#
# lsmod.txt was captured in a Fedora 45 guest after loading what a typical user needs:
#   virtio devices, Rosetta/virtiofs, containers (podman/docker/flatpak), firewall, VPNs,
#   common filesystems, zram — see the module list in git history (2026-10-15) to regenerate.
set -euo pipefail
VER=${VER:-7.2.11}
HERE=$(cd "$(dirname "$0")" && pwd)
W=${W:-$HOME/vzkernel}
mkdir -p "$W/out" && cd "$W"

if [ "$(uname -m)" != aarch64 ]; then
    export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
fi

[ -f linux-$VER.tar.xz ] || curl -sSfLO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$VER.tar.xz
if [ ! -d linux-$VER ]; then
    tar xf linux-$VER.tar.xz
    # Round blob sizes up to the host's blob_alignment instead of failing with EINVAL.
    (cd linux-$VER/drivers/gpu/drm/virtio && patch -p0 < "$HERE/../guest/virtio-gpu-blob-roundup.patch")
fi
cd linux-$VER

cp "$HERE"/fedora-*.config .config
make -s olddefconfig
# (yes dies of SIGPIPE when make stops reading; that is not a failure)
{ yes '' || true; } | make -s LSMOD="$HERE/lsmod.txt" localyesconfig >/dev/null

# Force: built-in virtio stack (no initramfs), 4K pages (Rosetta for Linux needs them),
# cgroups/namespaces for containers, no module signing/debug info/BTF (size, build time).
./scripts/config \
    -e VIRTIO -e VIRTIO_PCI -e VIRTIO_MMIO -e VIRTIO_BLK -e VIRTIO_NET -e VIRTIO_CONSOLE \
    -e HVC_DRIVER -e VIRTIO_FS -e FUSE_FS -e DRM -e DRM_VIRTIO_GPU -e BTRFS_FS -e EXT4_FS -e XFS_FS \
    -e DEVTMPFS -e DEVTMPFS_MOUNT -e ARM64_4K_PAGES -e VSOCKETS -e VIRTIO_VSOCKETS \
    -e CGROUPS -e MEMCG -e CGROUP_BPF -e USER_NS -e NAMESPACES -e OVERLAY_FS -e IKCONFIG -e IKCONFIG_PROC \
    -d MODULE_SIG -d MODULE_SIG_FORCE -d DEBUG_INFO -d DEBUG_INFO_BTF -e DEBUG_INFO_NONE -d IMA_APPRAISE \
    --set-str LOCALVERSION "-vzgpu" -d LOCALVERSION_AUTO \
    --set-str SYSTEM_TRUSTED_KEYS "" --set-str SYSTEM_REVOCATION_KEYS ""
make -s olddefconfig

time make -s -j"$(nproc)" Image
cp arch/arm64/boot/Image "$W/out/Image"
cp .config "$W/out/config"
echo "built $(make -s kernelrelease): $(du -h "$W/out/Image" | cut -f1)"
