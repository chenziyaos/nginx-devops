# ops-05 hypotheses (from the source, before running)

1. `sendfile` defaults to off (ngx_http_core_merge_loc_conf: `sendfile, 0`). Without it the
   darwin debug log shows `writev:` lines and no `sendfile: @` lines; with `sendfile on` the file
   goes out through `sendfile: @0 ...`.
2. The static module sets Last-Modified to the file mtime and ETag to `"%xT-%xO"`, i.e.
   `"<mtime in hex>-<size in hex>"` (ngx_http_set_etag).
3. not_modified filter: a matching If-None-Match gives 304; an If-Modified-Since equal to the
   mtime gives 304; a later IMS gives 200 under the default `if_modified_since exact` and 304
   under `before`. When both headers are sent, both have to say "not modified": a matching
   ETag with a wrong IMS gives 200. If-None-Match compares weakly, so `W/"..."` matches.
4. A 304 drops Content-Length and Accept-Ranges and keeps ETag.
5. Range: one range gives 206 + Content-Range; `bytes=-3` is the last 3 bytes; two ranges give
   multipart/byteranges; with `max_ranges 1` two ranges give 200 and the whole file; a start
   past the end gives 416 with `Content-Range: bytes */<size>`; an If-Range that does not match
   the ETag gives 200.
6. gzip with defaults: only text/html (gzip_types), at least 20 bytes, HTTP/1.1 and above
   (gzip_http_version 1.1), and no Via request header (gzip_proxied off). A gzipped response
   loses Content-Length and Accept-Ranges and gets a weak ETag, so Range on it gives 200.
7. gzip_static serves file.gz with its own Content-Length when the client accepts gzip, and the
   plain file otherwise.
8. `expires 1h` gives `Cache-Control: max-age=3600`; `expires modified 1h` on a file older than
   one hour gives `no-cache`; a 404 gets no Cache-Control (not a "safe" status).
9. open_file_cache keeps the descriptor: within `open_file_cache_valid`, a file replaced by rename is still
   served from the old descriptor; a location without the cache sees the new file.
10. `keepalive_requests 3`: the third response carries `Connection: close`, so four requests on
    one curl command use two connections (num_connects 1 0 0 1). `keepalive_timeout 75s 60s`
    sends `Keep-Alive: timeout=60`.
11. client_max_body_size is checked against Content-Length when the location is chosen (413 and
    "client intended to send too large body"); a chunked body is checked while it is read
    ("too large chunked body").
12. A body larger than client_body_buffer_size goes to a temp file with the warn
    "a client request body is buffered to a temporary file".
