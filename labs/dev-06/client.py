"""dev-06 client: send raw requests that curl cannot produce.

  client.py split PORT         the request line and the headers in three writes, 0.2 s apart
  client.py raw PORT NAME      one request from REQUESTS, print the status line
"""

import socket
import sys
import time

REQUESTS = {
    # one header line of 2000 bytes: more than client_header_buffer_size (1k), fits in 4k
    "long-2k": b"GET /a.txt HTTP/1.1\r\nHost: x\r\nX-Long: " + b"a" * 2000 + b"\r\n\r\n",
    # one header line of 5000 bytes: more than one large buffer (4k)
    "long-5k": b"GET /a.txt HTTP/1.1\r\nHost: x\r\nX-Long: " + b"a" * 5000 + b"\r\n\r\n",
    # 11 header lines: more than max_headers (10)
    "many": b"GET /a.txt HTTP/1.1\r\n" + b"".join(b"X-H%d: 1\r\n" % i for i in range(10))
            + b"Host: x\r\n\r\n",
    # a header line without a colon (rejected since 1.31.9)
    "nocolon": b"GET /a.txt HTTP/1.1\r\nHost: x\r\nX-No-Colon\r\n\r\n",
    "nohost": b"GET /a.txt HTTP/1.1\r\n\r\n",
    "cl-te": b"POST /a.txt HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n"
             b"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
}


def status(sock):
    data = b""
    while b"\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk
    return data.split(b"\r\n", 1)[0].decode()


def main():
    mode, port = sys.argv[1], int(sys.argv[2])
    s = socket.create_connection(("127.0.0.1", port))
    if mode == "split":
        for part in (b"GET /a.txt HT", b"TP/1.1\r\nHost: x\r\n", b"Connection: close\r\n\r\n"):
            s.sendall(part)
            time.sleep(0.2)
        print(status(s))
    else:
        s.sendall(REQUESTS[sys.argv[3]])
        print(sys.argv[3] + ": " + status(s))
    s.close()


main()
