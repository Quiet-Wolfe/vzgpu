#!/bin/bash
# install-guest.sh <user> — set a fresh Fedora guest up for vzgpu. Idempotent. Run as root,
# from the vzgpu share (/mnt/vzgpu/guest) or a copy of the repo's guest/ directory.
# Installs: sommelier (prebuilt, patched), wl-run, vz-export-apps, the host-share mount, the
# app-export watcher, a lingering user with sommelier as a user service, and the Wayland env.
set -euo pipefail
USERNAME=${1:?usage: install-guest.sh <user>}
HERE=$(cd "$(dirname "$0")" && pwd)

# Venus needs Mesa >= 26.2.4 (reads VIRTGPU_PARAM_BLOB_ALIGNMENT); sommelier's runtime libs.
dnf install -y -q mesa-vulkan-drivers vulkan-loader mesa-libgbm libdrm pixman libxkbcommon \
    libwayland-client libwayland-server libxcb cloud-utils-growpart xorg-x11-server-Xwayland
dnf upgrade -y -q 'mesa-*' || true

install -m 755 "$HERE/payload/sommelier" "$HERE/wl-run" "$HERE/x11-run" "$HERE/vz-export-apps" /usr/local/bin/
install -m 644 "$HERE/units/mnt-vzgpu.mount" "$HERE/units/vz-export-apps.service" \
    "$HERE/units/vz-export-apps.path" "$HERE/units/mnt-rosetta.mount" \
    "$HERE/units/vzgpu-rosetta.service" /etc/systemd/system/
# x86 on ARM: Rosetta runs x86-64 (vzgpu-rosetta.service registers it after the mount), FEX
# runs 32-bit x86 (Rosetta can't), QEMU keeps the other architectures. Empty overrides stop
# QEMU and FEX from claiming those at boot.
dnf install -y -q fex-emu fex-emu-rootfs-fedora fex-emu-thunks
mkdir -p /etc/binfmt.d
for f in qemu-x86_64-static FEX-x86_64 qemu-i386-static qemu-i486-static; do : > /etc/binfmt.d/$f.conf; done
install -m 644 "$HERE/units/sommelier.service" "$HERE/units/sommelier-x.service" /etc/systemd/user/
install -D -m 644 "$HERE/units/50-vzgpu.conf" /etc/environment.d/50-vzgpu.conf
install -m 644 "$HERE/units/vzgpu.sh" /etc/profile.d/vzgpu.sh

# Same timezone as the Mac (the installer writes it next to this script's share).
tz=$(cat "$HERE/../timezone" 2>/dev/null || true)
[ -n "$tz" ] && timedatectl set-timezone "$tz" 2>/dev/null || true

if ! id "$USERNAME" >/dev/null 2>&1; then
    useradd -m -G wheel,render,video "$USERNAME"
    passwd -d "$USERNAME" >/dev/null
fi
usermod -aG wheel,render,video "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-vzgpu-$USERNAME
chmod 440 /etc/sudoers.d/90-vzgpu-$USERNAME
# The host's SSH key (systemd credential, also given to root) for the user too.
if [ -s /root/.ssh/authorized_keys ]; then
    install -d -m 700 -o "$USERNAME" -g "$USERNAME" /home/$USERNAME/.ssh
    install -m 600 -o "$USERNAME" -g "$USERNAME" /root/.ssh/authorized_keys /home/$USERNAME/.ssh/
fi

# Grow the root partition and filesystem to the disk (the installer makes the disk image
# bigger than the distro's). systemd-growfs can't: without an initramfs, root is /dev/root.
part=$(sed -n 's/.*root=PARTUUID=\([^ ]*\).*/\1/p' /proc/cmdline)
dev=${part:+$(blkid -t PARTUUID="$part" -o device | head -1)}
if [ -n "$dev" ]; then
    disk=/dev/$(lsblk -no PKNAME "$dev"); num=$(cat /sys/class/block/${dev#/dev/}/partition)
    growpart "$disk" "$num" >/dev/null 2>&1 || true
    case $(findmnt -no FSTYPE /) in
        btrfs) btrfs filesystem resize max / >/dev/null ;;
        ext4) resize2fs "$dev" >/dev/null ;;
        xfs) xfs_growfs / >/dev/null ;;
    esac
fi

systemctl daemon-reload
systemctl enable --now mnt-vzgpu.mount vz-export-apps.path
systemctl restart systemd-binfmt.service  # apply the overrides now (FEX's own install restarted it too)
systemctl enable --now mnt-rosetta.mount vzgpu-rosetta.service || echo "vzgpu: Rosetta not available" >&2
systemctl start vz-export-apps.service || true
systemctl --global enable sommelier.service sommelier-x.service
loginctl enable-linger "$USERNAME"   # start the user manager (and sommelier) at boot
echo "vzgpu guest ready for $USERNAME"
