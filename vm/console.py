"""Drive a QEMU serial console over a unix socket.

usage: console.py SOCK TIMEOUT EXPECT_REGEX [SEND]
Sends SEND followed by CR (if given), then reads until EXPECT_REGEX matches or
TIMEOUT seconds pass. Prints what was read (ANSI escapes stripped).
Exit 0 on match, 1 on timeout.
"""
import re
import socket
import sys
import time

sock_path, timeout, pattern = sys.argv[1], float(sys.argv[2]), sys.argv[3]
send = sys.argv[4] if len(sys.argv) > 4 else None

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.settimeout(0.5)
if send is not None:
    s.sendall(send.encode() + b"\r")
buf = b""
rx = re.compile(pattern.encode())
deadline = time.time() + timeout
while time.time() < deadline and not rx.search(buf):
    try:
        chunk = s.recv(65536)
    except socket.timeout:
        continue
    if not chunk:
        break
    buf += chunk
sys.stdout.write(re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", buf).decode(errors="replace"))
sys.exit(0 if rx.search(buf) else 1)
