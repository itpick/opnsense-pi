"""Copy a QEMU serial console (unix socket) to a file, each line prefixed with
the host's clock: "<epoch seconds> <line>". For timing a boot from outside.

usage: console-stamp.py SOCK OUT
Runs until the socket closes (QEMU exits). Keep it the only client of SOCK:
QEMU's socket chardev serves one connection at a time.
"""
import re
import socket
import sys
import time

sock_path, out = sys.argv[1], sys.argv[2]
ansi = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")
for _ in range(100):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        break
    except OSError:
        time.sleep(0.1)
else:
    sys.exit(f"cannot connect to {sock_path}")
buf = b""
s.settimeout(0.5)
with open(out, "ab", buffering=0) as f:
    while True:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            # a prompt ("login: ") ends without a newline: write it once the
            # console has been quiet for a moment, stamped when it arrived
            if buf.strip():
                f.write(b"%.2f " % buf_t + ansi.sub(b"", buf).strip() + b"\n")
            buf = b""
            continue
        if not chunk:
            break
        now = time.time()
        if not buf:
            buf_t = now
        buf += chunk
        *lines, buf = re.split(rb"\r?\n|\r", buf)
        for line in lines:
            line = ansi.sub(b"", line).strip()
            if line:
                f.write(b"%.2f " % now + line + b"\n")
        buf_t = now
    if buf.strip():
        f.write(b"%.2f " % time.time() + ansi.sub(b"", buf).strip() + b"\n")
