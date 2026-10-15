#!/bin/sh
# Recreates third_party/smithay: upstream Smithay at a pinned revision plus our macOS patch
# (reis made optional so the crate builds on macOS; keymap "sealed files" via a private
# temp file because macOS has no memfd sealing and shm objects can't be write()n).
set -e
cd "$(dirname "$0")/third_party"
REV=023b78b1c5a0
[ -d smithay ] || git clone --filter=blob:none https://github.com/Smithay/smithay.git
git -C smithay checkout -q "$REV"
git -C smithay apply --check ../smithay-macos.patch 2>/dev/null && git -C smithay apply ../smithay-macos.patch || echo "patch already applied"
