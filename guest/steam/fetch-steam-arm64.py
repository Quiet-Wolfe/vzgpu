#!/usr/bin/env python3
"""fetch-steam-arm64.py [DEST] — assemble Valve's native Linux ARM64 Steam client.

Valve publishes it only as updater packages (no installer): the manifest at
client-update.steamstatic.com/steam_client_linuxarm64 lists zips, each verified here by SHA-256.
`*_linuxarm64_linuxarm64` packages are native AArch64; plain `*_linuxarm64` ones carry the x86/i386
pieces that run under FEX. Zip paths use backslashes and carry no Unix modes, so paths are
rewritten and ELF files and scripts made executable. DEST defaults to ~/.local/share/Steam.
"""
import hashlib
import os
import re
import sys
import urllib.request
import zipfile

CDN = "https://client-update.steamstatic.com/"
DEST = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.local/share/Steam")
CACHE = os.path.join(DEST, "package")


def fetch(url, path):
    tmp = path + ".part"
    with urllib.request.urlopen(url) as r, open(tmp, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
    os.replace(tmp, path)


def main():
    os.makedirs(CACHE, exist_ok=True)
    manifest = os.path.join(CACHE, "steam_client_linuxarm64")
    fetch(CDN + "steam_client_linuxarm64", manifest)
    text = open(manifest).read()
    version = re.search(r'"version"\s*"(\d+)"', text).group(1)
    pkgs = re.findall(r'"([a-z0-9_]+)"\s*\{\s*"file"\s*"([^"]+)"\s*"size"\s*"(\d+)"\s*"sha2"\s*"([0-9a-f]+)"', text)
    print(f"client version {version}: {len(pkgs)} packages", flush=True)
    for i, (name, file, size, sha2) in enumerate(pkgs, 1):
        path = os.path.join(CACHE, file)
        if not (os.path.exists(path) and os.path.getsize(path) == int(size)):
            print(f"[{i}/{len(pkgs)}] {name} ({int(size) / 1e6:.1f} MB)", flush=True)
            fetch(CDN + file, path)
        h = hashlib.sha256(open(path, "rb").read()).hexdigest()
        if h != sha2:
            os.remove(path)
            sys.exit(f"{name}: SHA-256 mismatch")
        with zipfile.ZipFile(path) as z:
            for info in z.infolist():
                rel = info.filename.replace("\\", "/")
                if rel.endswith("/"):
                    continue
                out = os.path.join(DEST, rel)
                os.makedirs(os.path.dirname(out), exist_ok=True)
                data = z.read(info)
                with open(out, "wb") as f:
                    f.write(data)
                if data[:4] == b"\x7fELF" or data[:2] == b"#!":
                    os.chmod(out, 0o755)
    open(os.path.join(DEST, "package", "installed_version"), "w").write(version + "\n")
    print(f"done: {DEST}", flush=True)


main()
