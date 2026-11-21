# ops-06 hypotheses (from the source, before running)

1. proxy_pass without a URI part sends the client's raw request line URI (r->unparsed_uri):
   %2F, double slashes and the query string go through untouched
   (ngx_http_proxy_create_request, ngx_http_proxy_module.c:1263-1265).
2. proxy_pass with a URI part replaces the matched location prefix in the decoded, normalized
   r->uri and escapes the rest again (:1267-1277): /b/x%2Fy -> /new/x/y, /b//x -> /new/x.
   "location /c0" + "proxy_pass .../new" maps /c0x to /newx.
3. rewrite ... break clears r->valid_location (ngx_http_script.c:1183-1185), so the URI part of
   proxy_pass is ignored and the rewritten URI is sent whole.
4. A URI part in a regex location is a configuration error (:4475-4490).
5. Default request headers (ngx_http_proxy_headers, :761-772): Host is $proxy_host
   (127.0.0.1:18120, or the upstream name), Connection/Upgrade/TE/Keep-Alive are not passed,
   other client headers are. A proxy_set_header in a location drops all inherited ones.
   proxy_set_header Host "" with HTTP/1.1 falls back to $proxy_host (:1239-1243).
6. Keepalive to the backend since 1.29.7: an upstream{} block gets "keepalive 32 local" by
   default, but implicit upstreams (proxy_pass to an address) are skipped
   (ngx_http_upstream_keepalive_init_main_conf: "skip implicit upstreams"). Expected:
   implicit -> req=1 each time, upstream block -> req=1,2,3 on one connection.
   "local" only reuses a connection for the same proxy configuration (tag check, :236), so a
   second location using the same upstream opens a new connection; without "local" it reuses.
   proxy_http_version 1.0 and "keepalive 0" -> no reuse.
7. Connection refused -> 502 with "connect() failed"; proxy_read_timeout expiring -> 504 with
   "upstream timed out". With two servers, the refused one is retried on the next
   (proxy_next_upstream error timeout): $upstream_status "502, 200"; with the default
   max_fails=1 the failed server is skipped on the next request.
8. proxy_buffering on: nginx reads the whole response from the backend into memory and a temp
   file, so $upstream_response_time is short while $request_time follows the slow client;
   off: both follow the client.
9. proxy_http_version 2 (1.29.4) talks h2c to a backend with "http2 on": $server_protocol on
   the backend is HTTP/2.0.
10. tunnel_pass (1.31.0) answers CONNECT with 200 and then copies bytes both ways
    (process_header sets u->upgrade); a server without tunnel_pass answers CONNECT with 405
    ("client sent CONNECT method", ngx_http_request.c:2098-2103). Default target is
    $host:$request_port.
11. realip with real_ip_header X-Forwarded-For takes the last address; with real_ip_recursive
    on it skips trusted addresses from the right.
