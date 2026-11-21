"""dev-05 client: pipelined requests in one write, or a connection that sends nothing."""
import socket
import sys
import time

mode, port = sys.argv[1], int(sys.argv[2])
s = socket.create_connection(("127.0.0.1", port))
if mode == "pipeline":
    s.sendall(b"GET /a HTTP/1.1\r\nHost: x\r\n\r\n"
              b"GET /b HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    print("responses in one connection:", data.count(b"HTTP/1.1 200"))
elif mode == "silent":
    start = time.time()
    s.settimeout(5)
    data = s.recv(4096)
    print("closed by the server without a response: %s, after >= 1 s: %s"
          % (data == b"", time.time() - start >= 1.0))
