#!/usr/bin/env python3
"""gen-notices.py: write THIRD_PARTY_NOTICES.md from third_party/licenses/ and cargo metadata.

Covers everything vzgpu redistributes: the libraries and data inside vzgpu.app, the prebuilt
sommelier in the guest package, the Rust crates linked into vzcomp, and the kernel release.
Rerun after changing a dependency: python3 tools/gen-notices.py
"""
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIC = ROOT / "third_party" / "licenses"


def text(name):
    return (LIC / name).read_text().strip()


COMPONENTS = [
    ("sommelier", "ChromiumOS platform2 `vm_tools/sommelier` (main, 2026-10-15) with "
     "`guest/sommelier-full-copy.patch` and `guest/sommelier-cursor-shape.patch`",
     "Prebuilt binary in the guest package (`guest/payload/sommelier`): the guest's Wayland bridge",
     "BSD-3-Clause", ["chromiumos-platform2.LICENSE"]),
    ("virglrenderer", "0.10.4e-krunkit (gitlab.freedesktop.org/slp/virglrenderer) with "
     "`third_party/virglrenderer-venus-fence-race.patch`",
     "vzgpu.app/Contents/Frameworks/libvirglrenderer.1.dylib: Venus in the VMM",
     "MIT", ["virglrenderer.COPYING"]),
    ("Mesa (KosmicKrisp Vulkan driver)", "Vulkan SDK 1.4.363.0 build "
     "(gitlab.freedesktop.org/aitor/mesa 269a955c898df283fc36f4827643769068cf3d29)",
     "vzgpu.app/Contents/Frameworks/libvulkan_kosmickrisp.dylib: the host Vulkan driver",
     "MIT (core Mesa; individual files carry SPDX identifiers)", ["mesa.MIT"]),
    ("Vulkan Loader", "Vulkan SDK 1.4.363.0 build "
     "(github.com/KhronosGroup/Vulkan-Loader fa218055ff4948b159f31d43f800c808a13d51df)",
     "vzgpu.app/Contents/Frameworks/libvulkan.1.dylib",
     "Apache-2.0", ["vulkan-loader.LICENSE.txt"]),
    ("libepoxy", "1.5.10 (Homebrew build)",
     "vzgpu.app/Contents/Frameworks/libepoxy.0.dylib (linked by virglrenderer)",
     "MIT", ["libepoxy.COPYING"]),
    ("libxkbcommon", "1.13.1 (Homebrew build)",
     "vzgpu.app/Contents/Frameworks/libxkbcommon.0.dylib: keymaps in vzcomp",
     "MIT and MIT-like (see text)", ["libxkbcommon.LICENSE"]),
    ("xkeyboard-config", "2.47 (Homebrew build)",
     "vzgpu.app/Contents/Resources/xkb: keyboard layout data for libxkbcommon",
     "MIT/X11-style (see text)", ["xkeyboard-config.COPYING"]),
]


def rust_crates():
    meta = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--format-version", "1"], cwd=ROOT / "compositor"))
    used = {n["id"] for n in meta["resolve"]["nodes"]}
    rows = sorted((p["name"], p["version"], p.get("license") or "see crate")
                  for p in meta["packages"] if p["id"] in used and p["name"] != "vzcomp")
    return rows


def main():
    out = ["# Third-party notices", "",
           "vzgpu's own code is under the MIT license (`LICENSE`). It redistributes the following "
           "third-party software, each under its own license, reproduced below. "
           "This file ships in vzgpu.app as `Contents/Resources/THIRD_PARTY_NOTICES.md`.", ""]
    for name, version, use, spdx, files in COMPONENTS:
        out += [f"## {name}", "", f"- Version: {version}", f"- Used as: {use}", f"- License: {spdx}", ""]
        for f in files:
            out += ["```", text(f), "```", ""]

    out += ["## Rust crates linked into vzcomp", "",
            "Statically linked into `vzcomp` (vzgpu.app and the launcher bundles). Each crate's "
            "copyright holders are named in its source; where a crate offers a choice, vzgpu takes "
            "MIT. Smithay is built from rev 023b78b1c5a0 with `compositor/third_party/smithay-macos.patch`.",
            "", "| Crate | Version | License |", "|---|---|---|"]
    out += [f"| {n} | {v} | {l} |" for n, v, l in rust_crates()]
    out += ["", "### MIT", "", "```", text("MIT.txt"), "```", "",
            "### Apache-2.0", "", "```", text("Apache-2.0.txt"), "```", ""]

    out += ["## Linux kernel (release asset, not in vzgpu.app)", "",
            "- Version: 7.2.11 with `guest/virtio-gpu-blob-roundup.patch`, configured by "
            "`kernel/build-kernel.sh` (`kernel/fedora-*.config`, `kernel/lsmod.txt`)",
            "- Used as: the guest kernel `Image.xz` in the GitHub release `kernel-7.2.11-vzgpu`",
            "- License: GPL-2.0 WITH Linux-syscall-note",
            "- Corresponding source: https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.11.tar.xz "
            "plus the patch and build script in this repository, which reproduce the binary.", "",
            "```", text("linux.COPYING"), "```", "",
            "```", text("linux.GPL-2.0"), "```", "",
            "```", text("linux.syscall-note"), "```", ""]

    (ROOT / "THIRD_PARTY_NOTICES.md").write_text("\n".join(out))
    print(f"wrote THIRD_PARTY_NOTICES.md ({len(out)} lines)")


main()
