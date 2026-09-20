#!/usr/bin/python3
# Helper H: take a reference on the server's /dev/ublkcN via pidfd_getfd() and
# sit on it. SIGUSR1: try a user-copy pread of q0/tag0's request data.
import os, sys, ctypes, signal
pid = int(sys.argv[1]); target = None
for f in os.listdir(f'/proc/{pid}/fd'):
    try:
        if os.readlink(f'/proc/{pid}/fd/{f}').startswith('/dev/ublkc'):
            target = int(f)
    except OSError:
        pass
libc = ctypes.CDLL(None, use_errno=True)
fd = libc.syscall(438, os.pidfd_open(pid), target, 0)   # pidfd_getfd
print(f"HELPER {os.getpid()} holds ublkc fd {fd} (server fd {target})", flush=True)
def tryread(*a):
    try:
        d = os.pread(fd, 4096, 0x80000000)               # UBLKSRV_IO_BUF_OFFSET, q0 tag0
        print(f"HELPER pread OK: {len(d)} bytes of the in-flight WRITE, starts {d[:4]!r}", flush=True)
    except OSError as e:
        print(f"HELPER pread failed: errno {e.errno} ({os.strerror(e.errno)})", flush=True)
signal.signal(signal.SIGUSR1, tryread)
while True:
    signal.pause()
