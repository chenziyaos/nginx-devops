# dev-08 hypotheses (written from the source before running the lab)

All line numbers: src/http/modules/ngx_http_limit_req_module.c at release-1.31.9.

1. A new key stores excess 0 and the first request sees 0 (486, 512, 520-523).
2. Each later request sees `excess - rate * ms / 1000 + 1000` (454); 1r/m is rate 16 (939), so
   a few ms between requests drain nothing visible.
3. A request is rejected when excess > burst * 1000 (462, 1060) and the rejected value is not
   stored (463 returns before 467), so two rejected requests in a row both see the same excess.
4. 3 s at 1r/m drains 16 * 3000 / 1000 = 48 thousandths (454).
5. limit_req runs once per main request: r->main->limit_req_status short-circuits (206-208),
   so an error_page redirect into another limit_req location does not look up again.
6. With two limits, the first is looked up with account = 0: it answers NGX_AGAIN (-2) and only
   bumps count (476-480); the last one is accounted. A rejection calls unlock (276, 609-629)
   and leaves the first zone's excess untouched; a pass lets account() store it (555-603).
7. delay = (excess - delay * 1000) * 1000 / rate ms (552, 596) and becomes a write timer (326).
   rate 1r/s, delay=1: excess 2, 3, 4 -> 1 s, 2 s, 3 s.
8. A new node first tries expire(ctx, 1), which only frees nodes idle >= 60 s (670-683); when the
   slab is full, expire(ctx, 0) deletes the LRU tail by force (497, 686-693), so allocation does
   not fail and the oldest key loses its state.
9. On reload a zone with the same name, size and tag is reused (src/core/ngx_cycle.c 473-488):
   same key keeps the state (722-725), a different key is an emerg (708-719) and the reload fails;
   a different size allocates a fresh zone and init gets no old data, so no key check.
