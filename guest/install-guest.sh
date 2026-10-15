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
    libwayland-client libwayland-server libxcb cloud-utils-growpart
dnf upgrade -y -q 'mesa-*' || true

install -m 755 "$HERE/payload/sommelier" "$HERE/wl-run" "$HERE/vz-export-apps" /usr/local/bin/
install -m 644 "$HERE/units/mnt-vzgpu.mount" "$HERE/units/vz-export-apps.service" \
    "$HERE/units/vz-export-apps.path" /etc/systemd/system/
install -m 644 "$HERE/units/sommelier.service" /etc/systemd/user/
install -D -m 644 "$HERE/units/50-vzgpu.conf" /etc/environment.d/50-vzgpu.conf
install -m 644 "$HERE/units/vzgpu.sh" /etc/profile.d/vzgpu.sh

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

systemctl daemon-reload
systemctl enable --now mnt-vzgpu.mount vz-export-apps.path
systemctl start vz-export-apps.service || true
systemctl --global enable sommelier.service
loginctl enable-linger "$USERNAME"   # start the user manager (and sommelier) at boot
echo "vzgpu guest ready for $USERNAME"
