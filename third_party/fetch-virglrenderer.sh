#!/bin/sh
# Build the krunkit virglrenderer (the one Homebrew's libkrun tap ships) with our
# venus_context.c fix, into third_party/virgl-prefix. The VMM links against that.
set -e
cd "$(dirname "$0")"
T=virglrenderer-0.10.4e-krunkit
[ -d $T ] || {
    curl -sSfL -o vr.tgz https://gitlab.freedesktop.org/slp/virglrenderer/-/archive/0.10.4e-krunkit/$T.tar.gz
    echo "09d000623fbdb966cb604eb48c962a0815e8142383e6066d6494809335b76dbb  vr.tgz" | shasum -a 256 -c
    tar xzf vr.tgz && rm vr.tgz
    (cd $T && patch -p1 < ../virglrenderer-venus-fence-race.patch)
}
export PATH=/opt/homebrew/bin:$PATH PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig
cd $T
[ -d build ] || meson setup build -Dvenus=true -Drender-server=false --buildtype=release --prefix="$PWD/../virgl-prefix"
ninja -C build install
# meson links MoltenVK directly (-lMoltenVK); go through the Vulkan loader instead so
# VK_DRIVER_FILES can pick the host ICD (KosmicKrisp, MoltenVK, ...).
SDK=${VULKAN_SDK:-$(ls -d "$HOME"/VulkanSDK/*/macOS | sort -V | tail -1)}
install_name_tool -change @rpath/libMoltenVK.dylib "$SDK/lib/libvulkan.1.dylib" ../virgl-prefix/lib/libvirglrenderer.1.dylib
codesign -s - -f ../virgl-prefix/lib/libvirglrenderer.1.dylib
