#!/bin/bash
# package-app.sh — assemble build/vzgpu.app, self-contained (no Homebrew, no Vulkan SDK, no
# checkout needed at runtime). Inputs are this checkout's builds plus SDK/Homebrew libraries:
#
#   Contents/MacOS/      vzcomp (the broker; bundle executable), vzgpu-vm (VMM), vzgpu-tool, vzgpu (CLI)
#   Contents/Frameworks/ libvirglrenderer (our patched build), libvulkan (loader), the KosmicKrisp
#                        ICD, libepoxy (linked by virglrenderer), libxkbcommon (vzcomp)
#   Contents/Resources/  vulkan/icd.d/kosmickrisp_icd.json, xkb/ (keymap data for xkbcommon),
#                        guest/ (the guest package install-guest.sh runs from)
#
# The kernel is not bundled: `vzgpu install` downloads the release asset (kernel/release.sh).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
SDK=${VULKAN_SDK:-$HOME/VulkanSDK/1.4.363.0/macOS}
BREW=${BREW:-/opt/homebrew}
APP=$REPO/build/vzgpu.app
C=$APP/Contents

say() { printf '\033[1m%s\033[0m\n' "$*"; }

say "Building"
(cd "$REPO/compositor" && cargo build --release -q)
V=$REPO/third_party/virgl-prefix
[ -f "$V/lib/libvirglrenderer.1.dylib" ] || "$REPO/third_party/fetch-virglrenderer.sh"
xcrun clang -fobjc-arc -O2 -Wall -I"$V/include/virgl" -L"$V/lib" -lvirglrenderer \
    -Wl,-rpath,@executable_path/../Frameworks -framework Foundation -framework Virtualization \
    -o "$REPO/build/vzgpu-vm" "$REPO/vzgpu.m" "$REPO/crossdomain.m"
xcrun clang -O2 -fobjc-arc -Wall -framework Foundation -framework AppKit -framework ImageIO \
    -framework UniformTypeIdentifiers -lcompression -o "$REPO/build/vzgpu-tool" "$REPO/tools/vzgpu-tool.m"

say "Assembling $APP"
rm -rf "$APP"
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources/vulkan/icd.d"
cp "$REPO/compositor/target/release/vzcomp" "$REPO/build/vzgpu-vm" "$REPO/build/vzgpu-tool" "$C/MacOS/"
cp "$REPO/tools/vzgpu" "$C/MacOS/vzgpu"
cp -L "$V/lib/libvirglrenderer.1.dylib" "$SDK/lib/libvulkan.1.dylib" "$SDK/lib/libvulkan_kosmickrisp.dylib" \
    "$BREW/opt/libepoxy/lib/libepoxy.0.dylib" "$BREW/opt/libxkbcommon/lib/libxkbcommon.0.dylib" "$C/Frameworks/"
chmod u+w "$C"/Frameworks/*
cat > "$C/Resources/vulkan/icd.d/kosmickrisp_icd.json" <<'EOF'
{
    "ICD": {
        "api_version": "1.4.0",
        "library_path": "../../../Frameworks/libvulkan_kosmickrisp.dylib"
    },
    "file_format_version": "1.0.0"
}
EOF
cp -RL "$BREW/share/X11/xkb" "$C/Resources/xkb"
cp -R "$REPO/guest" "$C/Resources/guest"
cp "$REPO/LICENSE" "$REPO/THIRD_PARTY_NOTICES.md" "$C/Resources/"

# Every non-system library reference -> @rpath (= Contents/Frameworks).
fix() {  # $1 = Mach-O file
    local f=$1 dep
    otool -L "$f" | tail -n +2 | awk '{print $1}' | { grep -vE '^(/System|/usr/lib|@rpath|@executable_path)' || true; } |
    while read -r dep; do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null
    done
}
for lib in "$C"/Frameworks/*.dylib; do
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
    fix "$lib"
done
fix "$C/MacOS/vzcomp"
install_name_tool -add_rpath @executable_path/../Frameworks "$C/MacOS/vzcomp"
fix "$C/MacOS/vzgpu-vm"
# Nothing may still point into Homebrew, the SDK or this checkout.
if otool -L "$C"/MacOS/vzcomp "$C"/MacOS/vzgpu-vm "$C"/MacOS/vzgpu-tool "$C"/Frameworks/*.dylib |
    grep -E $'^\t' | grep -E "$BREW|VulkanSDK|$REPO"; then
    echo "package-app: leftover absolute library paths (above)" >&2
    exit 1
fi

cat > "$C/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>vzgpu</string>
  <key>CFBundleIdentifier</key><string>dev.vzgpu</string>
  <key>CFBundleExecutable</key><string>vzcomp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

say "Signing (ad hoc)"
for f in "$C"/Frameworks/*.dylib "$C/MacOS/vzgpu-tool" "$C/MacOS/vzgpu"; do codesign -s - -f "$f" 2>/dev/null; done
codesign -s - -f --entitlements "$REPO/vzgpu.entitlements" "$C/MacOS/vzgpu-vm" 2>/dev/null
codesign -s - -f "$APP" 2>/dev/null
codesign -v "$APP" && say "$APP ($(du -sh "$APP" | cut -f1))"
