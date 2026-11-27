# cloud-08 hypotheses (from the source of nginx 1.26.3, 1.30.8 and 1.31.10)

Three pods with the same config: the official images nginx:1.26.3 and nginx:1.30.8, and
the lab image of 1.31.10. The 1.30 stable branch was cut from 1.29.x (1.30.0 on 2026-04-14),
so it has the 1.29 features and none of 1.31.

1. All three accept conf/nginx.conf.
2. `server ... resolve` (1.27.3): 1.26.3 has no "resolve" in ngx_http_upstream.c and
   answers `invalid parameter "resolve"`. `sticky` (1.29.6) and `least_time` (1.31.0) are
   modules built by default (auto/options: HTTP_UPSTREAM_STICKY=YES,
   HTTP_UPSTREAM_LEAST_TIME=YES); a version without them answers `unknown directive`.
   resolve: n y y, sticky: n y y, least_time: n n y.
3. 1.29.7 turned keepalive on for upstream blocks: max_cached defaults to 32
   (ngx_http_upstream_keepalive_module.c:552-555) and proxy_http_version to 1.1
   (ngx_http_proxy_module.c:4071-4072), but implicit upstreams (an address in proxy_pass)
   are skipped (lines 536-539). 10 sequential requests: 1.26.3 opens 10 connections to
   both backends; 1.30.8 and 1.31.10 one to the upstream block and 10 to the address.
4. A chunk size line ended by LF alone: 1.26.3 accepts it (case LF in
   ngx_http_parse_chunked), 1.29.4 and later go to invalid: 200, 400, 400.
5. A header line without a colon: before 1.31.9, CR in sw_name ends the header with an
   empty value; 1.31.10 returns NGX_HTTP_PARSE_INVALID_HEADER for any byte <= 0x20 in the
   name (ngx_http_parse.c, sw_name): 200, 200, 400.
