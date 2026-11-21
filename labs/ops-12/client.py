#!/usr/bin/env python3
"""Small TCP / TLS / UDP clients for the ops-12 lab.

  client.py tcp PORT [PAYLOAD]   send PAYLOAD (\\r\\n escapes allowed), read until EOF
  client.py tls PORT SNI CAFILE  TLS handshake with SNI, read until EOF
  client.py udp PORT PAYLOAD     send one datagram, wait up to 2 s for one reply

Prints "local_port=<n> bytes=<n>" and the first line received, so run.sh can compare the
port the client used with the port the backend saw.
"""
import socket
import ssl
import sys


def show(local_port, data):
    first = data.split(b'\n', 1)[0].decode('latin-1').rstrip('\r')
    print('local_port=%d bytes=%d first=%s' % (local_port, len(data), first))


def read_all(sock):
    out = b''
    while True:
        try:
            chunk = sock.recv(65536)
        except ConnectionResetError:
            return out + b'(reset)'
        if not chunk:
            return out
        out += chunk


def main():
    mode, port = sys.argv[1], int(sys.argv[2])
    if mode == 'udp':
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        s.sendto(sys.argv[3].encode(), ('127.0.0.1', port))
        try:
            data = s.recv(65536)
        except socket.timeout:
            data = b''
        show(s.getsockname()[1], data)
        return
    s = socket.create_connection(('127.0.0.1', port), timeout=5)
    local_port = s.getsockname()[1]
    if mode == 'tls':
        ctx = ssl.create_default_context(cafile=sys.argv[4])
        try:
            t = ctx.wrap_socket(s, server_hostname=sys.argv[3])
        except (ssl.SSLError, OSError) as e:
            print('local_port=%d handshake failed: %s' % (local_port, type(e).__name__))
            return
        cert = t.getpeercert()
        cn = dict(x[0] for x in cert['subject'])['commonName']
        data = read_all(t)
        show(local_port, data)
        print('cert=%s' % cn)
        return
    if len(sys.argv) > 3:
        s.sendall(sys.argv[3].encode().decode('unicode_escape').encode('latin-1'))
    show(local_port, read_all(s))


main()
