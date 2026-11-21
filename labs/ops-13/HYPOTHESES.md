# ops-13 hypotheses (from the source, before running)

1. nginx -T prints "# configuration file <path>:" before each file it read, the main file
   first, then each include in the order it was read.
2. Errors in the request line and headers are logged at "info" (ngx_http_request.c), so an
   "error_log ... " without a level (NGX_LOG_ERR, ngx_log_set_levels) does not show them:
   HTTP/1.1 without Host -> 400.
   Revised after the first run: a space in a header name is not "ignored" but returns
   NGX_HTTP_PARSE_INVALID_HEADER (ch <= 0x20 in sw_name) -> 400; only other invalid
   characters, such as "_" with underscores_in_headers off, set invalid_header and are
   dropped with ignore_invalid_headers on (the default), the request goes on.
3. With large_client_header_buffers 4 1k: a URI longer than 1k -> 414 "client sent too
   long URI"; a header line longer than 1k -> 494, which ngx_http_special_response_handler
   sends as 400 and the access log records as 400.
4. client_max_body_size is checked against Content-Length when the location is chosen:
   413 and "client intended to send too large body: N bytes" at error level.
5. client_header_timeout: the connection is closed without a reply, access log 408,
   "client timed out" at info.
6. 403 "directory index of ... is forbidden", 404 "open() ... failed (2: ...)", 500
   "rewrite or internal redirection cycle" (10 URI changes), all at error.
7. 502 variants: connect refused; "upstream prematurely closed connection" (backend
   closes without a reply); "upstream sent too big header" (header > proxy_buffer_size);
   "no live upstreams" when every server in the group is disabled.
8. 504: proxy_read_timeout expires -> NGX_HTTP_UPSTREAM_FT_TIMEOUT -> 504 "upstream timed
   out". A connect timeout takes the same path.
9. 499: the client closes while nginx waits for the upstream; on kqueue
   "kevent() reported that client prematurely closed connection, so upstream connection
   is closed too" at info.
10. 503 from limit_req: "limiting requests, excess: ... by zone" at error.
11. A debug log has "http request line", "http uri", "http args", the phase lines,
    "test location", "using configuration" and "http finalize request: 0".
