# ops-08 hypotheses (from the source, before running)

1. ssl_protocols defaults to TLSv1.2 TLSv1.3 (NGX_SSL_DEFAULT_PROTOCOLS, 1.27.3 dropped TLSv1
   and TLSv1.1); a TLSv1.1 client fails and the server logs "unsupported protocol" at info.
   ssl_ciphers defaults to "HIGH:!aNULL:!MD5".
2. Two ssl_certificate lines (RSA and ECDSA) on one server: OpenSSL picks the one the client's
   signature algorithms allow.
3. SNI picks the server{} by name; an unknown name gets the default server's certificate;
   "ssl_reject_handshake on" in the default server makes unknown names fail the handshake.
4. A plain HTTP request to an ssl port gets 400 "The plain HTTP request was sent to HTTPS port"
   (internally 497, so error_page 497 can redirect it).
5. Session tickets: without ssl_session_cache and ssl_session_ticket_key, the keys belong to
   the SSL_CTX of the cycle, so a reload makes old tickets useless (a full handshake). With
   "ssl_session_cache shared:...", ngx_ssl_session_ticket_keys keeps the keys in that shared
   zone, which a reload reuses, so tickets still resume.
6. "http2 on" + ALPN gives HTTP/2 over TLS; without it the same client gets HTTP/1.1.
   "listen ... http2" still works but -t warns that it is deprecated. "http2 on" on a plain
   listener accepts prior-knowledge h2c.
7. "listen ... quic" + "http3 on" answers a QUIC handshake with ALPN h3; browsers learn about
   it from an Alt-Svc header that has to be added by hand.
8. error_page 497 can turn the plain-HTTP-to-HTTPS-port error into a redirect; "=301" sets the
   status and the URI keeps $request_uri.
9. ssl_certificate with variables loads the certificate during the handshake (the SNI name is
   known then); without ssl_certificate_cache every handshake reads the file, so a replaced
   file is used at once; with "ssl_certificate_cache max=10" the loaded certificate is kept
   for valid=60s (the default in ngx_http_ssl_certificate_cache) before the file is checked.
   Without SNI, $ssl_server_name is empty and the file ".crt" cannot be loaded.
10. On an h2c port nginx answers the connection preface with SETTINGS (max streams 128,
    initial window 65536, max frame 2^24-1 and, since 1.31.7, NO_RFC7540_PRIORITIES=1) and a
    WINDOW_UPDATE that raises the connection window from 65535 to 2^31-1. A port without
    http2 parses "PRI * HTTP/2.0" as an HTTP/1 request line and answers 400.
