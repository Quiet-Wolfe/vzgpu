#!/bin/bash
# build-sommelier.sh — build the guest/payload/sommelier binary. Run in a Fedora guest (aarch64).
# Upstream ChromiumOS sommelier + our patches:
#   sommelier-full-copy.patch     copy whole frames into the host buffer (damage-only copy garbles GTK4)
#   sommelier-cursor-shape.patch  wp_cursor_shape_v1 pass-through, so apps' standard cursors
#                                 become native macOS cursors in vzcomp
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
W=${W:-$HOME/sommelier-build}
sudo dnf install -y -q meson gcc-c++ wayland-devel libxkbcommon-devel pixman-devel libdrm-devel \
    mesa-libgbm-devel libxcb-devel patch
rm -rf "$W" && mkdir -p "$W" && cd "$W"
curl -sSfL 'https://chromium.googlesource.com/chromiumos/platform2/+archive/refs/heads/main/vm_tools/sommelier.tar.gz' | tar xz
(cd compositor && patch -s -p0 < "$HERE/sommelier-full-copy.patch")
patch -s -p1 < "$HERE/sommelier-cursor-shape.patch"
meson setup build -Dwith_tests=false --buildtype=release >/dev/null
ninja -C build >/dev/null
strip -o sommelier build/sommelier
echo "built $W/sommelier"
