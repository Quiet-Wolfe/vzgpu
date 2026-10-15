#!/bin/sh
# Mount the VMM's Rosetta share, register it for x86_64 ELF, and run a static
# x86_64 busybox. Prints the page size so the result is tied to the kernel.
echo "kernel $(uname -r), page size $(getconf PAGESIZE)"
modprobe virtiofs 2>/dev/null; modprobe binfmt_misc 2>/dev/null
mountpoint -q /proc/sys/fs/binfmt_misc || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
mkdir -p /mnt/rosetta
mountpoint -q /mnt/rosetta || mount -t virtiofs rosetta /mnt/rosetta || { echo "mount failed"; exit 1; }
ls -la /mnt/rosetta
[ -e /proc/sys/fs/binfmt_misc/rosetta ] || printf '%s' ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/rosetta/rosetta:CF' > /proc/sys/fs/binfmt_misc/register
head -3 /proc/sys/fs/binfmt_misc/rosetta
/root/x86/usr/bin/busybox uname -m; echo "busybox uname rc=$?"
/root/x86/usr/bin/busybox sh -c 'echo hello from x86_64 busybox; i=0; while [ $i -lt 100000 ]; do i=$((i+1)); done; echo loop=$i'; echo "busybox sh rc=$?"
