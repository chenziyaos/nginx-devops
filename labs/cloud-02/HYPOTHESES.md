# cloud-02 hypotheses (from the source, before running)

1. `server backend.<ns>.svc.cluster.local;` in an upstream block is resolved once, at
   startup, to the ClusterIP: one peer. Since 1.29.7 an upstream block keeps connections
   (keepalive 32 local, ngx_http_upstream_keepalive_module.c init_main_conf); kube-proxy
   picks a pod per connection, so with one worker and sequential requests all 300 go to
   the same pod.
2. `proxy_pass http://name;` with no upstream block gets no keepalive (ops-06), so each
   request is a new connection and kube-proxy spreads them over all 3 pods.
3. `server <headless name> resolve;` in an upstream with a zone is not resolved at startup
   (u.no_resolve = 1, ngx_http_upstream.c:6704-6707) but by the zone module's timer through
   `resolver`; every A record becomes a peer, and round robin over 3 equal peers with one
   worker gives exactly 100/100/100.
4. The resolve timer fires again (valid - now + 1) s after an answer
   (ngx_http_upstream_zone_module.c:1029); `valid=1s` overrides the TTL
   (ngx_resolver.c:2458). New pods appear once DNS returns them; CoreDNS caches answers
   (cache 30 in its Corefile), so the delay is bounded by that cache, not by valid.
   The same name without `resolve` keeps its 3 startup addresses.
5. Scaling 5 -> 2 under load: requests that hit a stopped pod fail to connect and
   proxy_next_upstream (error timeout by default) retries another peer; the client sees
   no errors. Once DNS drops the addresses, round robin over 2 peers gives 150/150.
6. nginx's resolver does not use the search list of /etc/resolv.conf, so a short name with
   `resolve` is never found: "could not be resolved (3: Host not found)" and 502.
