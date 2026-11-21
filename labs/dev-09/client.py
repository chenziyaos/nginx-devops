"""dev-09 client: a slow reader. Sends one GET with a small receive buffer, waits before
reading, then reads to the end and prints the body size.

    python3 client.py PORT PATH [DELAY]
"""
import socket
import sys
import time

port, path = int(sys.argv[1]), sys.argv[2]
delay = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
# a fixed 16 KB receive buffer: no autotuning, so the proxy cannot push the body into the kernel
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16384)
s.connect(("127.0.0.1", port))
s.sendall(f"GET {path} HTTP/1.1\r\nHost: lab\r\nConnection: close\r\n\r\n".encode())
time.sleep(delay)

data = b""
while True:
    chunk = s.recv(65536)
    if not chunk:
        break
    data += chunk
s.close()

head, _, body = data.partition(b"\r\n\r\n")
print(f"{path}: {head.split(b' ')[1].decode()} body {len(body)} bytes")
