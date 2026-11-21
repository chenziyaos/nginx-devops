# ops-07 hypotheses (from the source, before running)

1. Round robin is the smooth weighted algorithm of ngx_http_upstream_get_peer: every pick adds
   effective_weight to each peer's current_weight, takes the largest, subtracts the total from
   it. Weights 5/1/1 give A A B A C A A per 7 requests (simulated in run.sh, not hard coded).
2. A failed attempt (connect refused) with max_fails=1 marks the peer for fail_timeout: within
   that time it is not tried again; after it, one request tries it again. error.log logs
   "upstream server temporarily disabled" at warn.
3. An upstream with one server never marks it failed (peers->single resets fails), so every
   request tries to connect; there is no "no live upstreams".
4. When all servers of a group are failed, get_round_robin_peer returns NGX_BUSY and the next
   request gets 502 with "no live upstreams" without connecting. backup servers are used only
   when the primary group has no usable peer; "down" servers are never chosen.
5. proxy_next_upstream defaults to "error timeout": a 500 from a backend goes to the client and
   does not count as a failure. With http_500 the request moves to the next server and the
   500 counts towards max_fails. A POST that was already sent is not retried
   (NGX_HTTP_UPSTREAM_FT_NON_IDEMPOTENT) unless non_idempotent is listed.
6. hash ... consistent: removing a server only moves the keys that were on it; plain hash
   moves others too.
7. ip_hash hashes the first 3 bytes of an IPv4 address: hash = 89, then
   hash = (hash * 113 + byte) % 6271, peer = hash % total_weight (simulated in run.sh).
8. least_conn sends new requests to the peer with fewer active connections; least_time
   last_byte prefers the peer with the lower averaged response time (rounded up to 20 ms),
   so a peer that took 0.5 s once gets no more requests while the other is fast.
9. sticky cookie: the cookie value is the MD5 hex of the server name ("127.0.0.1:port"),
   or the route= value; a request with the cookie goes to that server.
