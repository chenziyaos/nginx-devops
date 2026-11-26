# dev-06 hypotheses (from the source, before running)

1. The phase engine that ngx_http_init_phase_handlers builds is the array labs/dev-01 derived
   from the module list: 18 entries, find_config at 2, post_rewrite at 4 with next = 2,
   post_access at 11, content handlers 14-17 with next = 18 (the terminating entry).
   server_rewrite_index = 1, location_rewrite_index = 3. Access handlers have next = 12, the
   entry after post_access, so "satisfy any" jumps over post_access. The heads of the filter
   chains are the last filter modules in ngx_modules[]: not_modified for headers, range_body
   for bodies.
2. A request line that arrives in pieces: ngx_http_process_request_line gets NGX_AGAIN from the
   parser, returns, and runs again on the next read event; the same for the header lines.
3. client_header_buffer_size 1k: a 2000-byte header line does not fit, so
   ngx_http_alloc_large_header_buffer takes a 4k buffer and copies the unparsed part (1024 minus
   the 30 bytes of "GET /a.txt HTTP/1.1\r\nHost: x\r\n") = 994 bytes. A 5000-byte line does not
   fit in one large buffer: NGX_HTTP_REQUEST_HEADER_TOO_LARGE (494), sent and logged as 400.
4. max_headers 10: the 11th header line is "too many header lines" (494, 400). A header line
   without a colon is "invalid header line" (400) in 1.31.10. After the last line,
   ngx_http_process_request_header rejects HTTP/1.1 without Host and Content-Length together
   with Transfer-Encoding: chunked, both 400.
5. rewrite ... last: the rewrite handler changes the URI, post_rewrite (4) sees uri_changed and
   sets phase_handler = next = 2 (find_config); the location is searched again and the request
   continues at 3. uri_changes starts at 11; a location that always rewrites to itself gets 11
   post_rewrite lines ("uri changes: 11" .. "1") and then 500 "rewrite or internal redirection
   cycle".
6. error_page 404 /a.txt is ngx_http_internal_redirect: the phases restart at
   server_rewrite_index (1), not 0, and main->count goes to 2 until the redirect returns
   NGX_DONE. The status stays 404 because error_page has no "=".
7. deny all: the access handler returns 403; with satisfy all the access checker finalizes the
   request at index 8 and no later phase runs.
8. SSI with two includes: two ngx_http_subrequest calls, main->count 1 -> 3; c->data moves to
   the first subrequest, so the main request finalizes as not active (a:0). The proxied /slow
   waits for its upstream; /fast.txt runs first, its output is kept by the postpone filter and
   written after /slow and "B". The whole response (headers and chunks) is smaller than
   postpone_output (1460), so the write filter sends it in one writev at the end.
