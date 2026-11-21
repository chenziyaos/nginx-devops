# dev-09 hypotheses (from the source, before running)

1. ngx_http_upstream_get_peer with weights 5 1 1 picks A A B A C A A, and after 7 picks every
   current_weight is back to 0 (each pick adds 7 in total and takes 7 from the winner).
2. A failure (free with NGX_PEER_FAILED, max_fails=2) lowers A's effective_weight by
   weight / max_fails = 5 / 2 = 2, to 3; the retry inside the same request cannot pick A (tried
   bit) and picks B. Every later pass over A adds 1 back: 4 at request 2, 5 at request 3.
3. Weights 1 1 1, every server fails: the tried bitmap goes 0x1, 0x3, 0x7 and pc->tries
   3 -> 2 -> 1 -> 0; a fourth get returns NGX_BUSY (-3), and so does the next request while all
   three have fails >= max_fails (1) inside fail_timeout.
4. With a SID hint for A (what the sticky module passes), the first sticky pick reweights
   normally (A: 1 - 3 = -2); while A's current_weight <= -(total - weight) = -2, further sticky
   picks skip the reweighting, so requests 2 and 3 leave -2 1 1 untouched; then B and C.
5. A first request through "upstream one" (default keepalive, local) logs: init keepalive peer,
   get keepalive peer, get rr peer, connect, "http upstream connect: -2" (NGX_AGAIN), then
   send request handler, process header, process upstream (buffered), finalize, free keepalive
   peer: saving connection, free rr peer 1 0. The second request finds the cached connection:
   "using connection", "http upstream connect: -4" (NGX_DONE), no new socket, and the request
   is sent without waiting for a write event.
6. "upstream dead" (19198 first, refused): next upstream with ft_type 2 (NGX_HTTP_UPSTREAM_FT_ERROR),
   free rr peer 2 4 (tries 2, NGX_PEER_FAILED), "upstream server temporarily disabled", then
   get rr peer, try: 1 picks 19181. $upstream_addr has both, $upstream_status "502, 200". The
   next request skips 19198 (fails 1 >= max_fails 1 within 10 s).
7. proxy_pass to an address creates an implicit upstream without srv_conf, which
   ngx_http_upstream_keepalive_init_main_conf skips: three requests use three backend
   connections (c=1 1 1); so does "keepalive 0". "keepalive 16" reuses one (c=1 2 3).
8. Without a keepalive directive the cache is "local": two locations proxying to the same
   upstream do not share connections (1 1 2 2); "keepalive 16" without local shares (1 2 3 4).
9. keepalive_requests 2: c=1 2 1 2 1. A backend answering "Connection: close" makes
   u->keepalive 0, so nothing is saved (1 1 1, no "saving connection").
10. "sticky" saves the current init_upstream and replaces it; "least_conn" written after it
    replaces sticky's with a [warn] "load balancing method redefined", so that upstream sends
    no Set-Cookie. In the other order the cookie is set.
11. proxy_buffering on, 4 x 8k buffers, a 4 MB body and a client that waits: the event pipe
    fills the buffers and writes the rest to a temporary file ([warn] "an upstream response is
    buffered to a temporary file"). proxy_buffering off, or "X-Accel-Buffering: no" from the
    backend, goes through process_non_buffered_upstream and writes no temp file. All three
    deliver 4194304 bytes.
