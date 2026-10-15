#!/usr/bin/env python3
"""Exercise the real compositor without a VM or a Wayland client library.

python3 tests/wayland-stress.py target/release/vzcomp
"""
import array
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile


def uint(*values):
    return struct.pack('<' + 'I' * len(values), *values)


def string(value):
    b = value.encode() + b'\0'
    return uint(len(b)) + b + b'\0' * (-len(b) % 4)


sock, server = socket.socketpair()
sock.settimeout(15)
with tempfile.TemporaryFile(mode='w+') as log:
    proc = subprocess.Popen([sys.argv[1], '--client-fd', str(server.fileno())],
                            pass_fds=[server.fileno()], stderr=log)
    server.close()
    pending = bytearray()
    globals_ = {}
    done = set()
    configured = []
    next_id = 3

    def send(obj, opcode, body=b'', fd=None):
        packet = uint(obj, ((len(body) + 8) << 16) | opcode) + body
        ancillary = [] if fd is None else [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [fd]))]
        assert sock.sendmsg([packet], ancillary) == len(packet)

    def receive_until(predicate):
        while not predicate():
            data, ancillary, _, _ = sock.recvmsg(65536, socket.CMSG_SPACE(16))
            assert data, 'compositor disconnected early'
            # No bound seat means we don't need keymap FDs, but close any received FDs.
            for level, kind, body in ancillary:
                if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                    fds = array.array('i'); fds.frombytes(body[:len(body) // 4 * 4])
                    for fd in fds: os.close(fd)
            pending.extend(data)
            while len(pending) >= 8:
                obj, word = struct.unpack_from('<II', pending)
                size, opcode = word >> 16, word & 65535
                if len(pending) < size: break
                body = bytes(pending[8:size]); del pending[:size]
                assert not (obj == 1 and opcode == 0), f'Wayland protocol error: {body!r}'
                if obj == 2 and opcode == 0:
                    name, n = struct.unpack_from('<II', body)
                    interface = body[8:8+n-1].decode()
                    version, = struct.unpack_from('<I', body, 8 + (n + 3) // 4 * 4)
                    globals_[interface] = (name, version)
                elif obj == 6 and opcode == 0:  # xdg_wm_base.ping
                    send(6, 3, body)
                elif obj == 8 and opcode == 0:  # xdg_surface.configure
                    serial, = struct.unpack('<I', body)
                    configured.append(serial)
                elif (obj == 3 or obj >= 11) and opcode == 0:
                    done.add(obj)

    def sync():
        global next_id
        callback = next_id; next_id += 1
        send(1, 0, uint(callback))
        receive_until(lambda: callback in done)

    try:
        send(1, 1, uint(2))  # registry
        sync()
        for interface, obj, version in [('wl_compositor', 4, 4), ('wl_shm', 5, 1), ('xdg_wm_base', 6, 1)]:
            name, available = globals_[interface]
            send(2, 0, uint(name) + string(interface) + uint(min(version, available), obj))
        send(4, 0, uint(7))  # surface
        send(6, 2, uint(8, 7))  # xdg surface
        send(8, 1, uint(9))  # toplevel
        send(9, 2, string('vzgpu rapid resize regression'))
        send(7, 6)  # initial commit
        receive_until(lambda: configured)
        send(8, 4, uint(configured[-1]))
        # One file, alternating offsets and odd widths to exercise padded strides.
        with tempfile.TemporaryFile() as shm:
            slot_size = 1024 * 768 * 4
            capacity = 10 * slot_size
            shm.truncate(capacity)
            send(5, 0, uint(10, capacity), shm.fileno())
            next_id = 11
            for batch in range(20):
                buffers = []
                for n in range(10):
                    frame = batch * 10 + n
                    w, h = 321 + frame % 7 * 29, 241 + frame % 5 * 23
                    stride = (w * 4 + 63) // 64 * 64
                    offset = n * slot_size + 128
                    pixel = uint(0xff000000 | frame * 1009)
                    os.pwrite(shm.fileno(), pixel * (stride // 4 * h), offset)
                    buffer = next_id; next_id += 1
                    buffers.append(buffer)
                    send(10, 0, uint(buffer, offset, w, h, stride, 1))
                    send(8, 3, uint(0, 0, w, h))  # geometry
                    send(7, 1, uint(buffer, 0, 0))  # attach
                    send(7, 2, uint(0, 0, w, h))  # damage
                    send(7, 6)
                # Ten commits in a burst, using distinct storage until copied.
                sync()
                for buffer in buffers: send(buffer, 0)
                callback = next_id; next_id += 1
                send(7, 3, uint(callback)); send(7, 6)
                receive_until(lambda: callback in done)
        send(9, 0); send(8, 0); send(7, 0)
        sync()
        sock.close()
        assert proc.wait(timeout=10) == 0
        print('PASS: 200 rapid resized frames, 20 display callbacks, clean disconnect')
    finally:
        sock.close()
        if proc.poll() is None: proc.terminate(); proc.wait(timeout=10)
        log.seek(0)
        output = log.read()
        if proc.returncode: print(output, file=sys.stderr)
