# ops-10 hypotheses (from the source, before running)

1. The default proxy_cache_key is $scheme$proxy_host$request_uri; the file name is the hex
   MD5 of the key, and levels=1:2 takes the directories from the end of that name
   (ngx_create_hashed_filename): <path>/<last 1>/<2 before it>/<md5>. The file starts with
   a binary header (version 5) and a "\nKEY: <key>\n" line.
2. With proxy_cache_valid 200 1s: MISS, HIT, then after the entry expires EXPIRED (a full
   request to the backend), then HIT again. The backend sees 2 requests.
3. Freshness, highest first: X-Accel-Expires, Cache-Control s-maxage, max-age, Expires,
   proxy_cache_valid. Cache-Control no-cache/no-store/private, max-age=0, X-Accel-Expires: 0
   and Set-Cookie make the response uncacheable. An Expires in the past followed by
   Cache-Control max-age is cached (1.23.0). The stored valid_sec - date shows the winner.
4. HEAD is converted to GET for the cache (proxy_cache_convert_head on), so a later GET hits.
5. proxy_cache_min_uses 2: the first request is not stored (MISS), the second is stored
   (MISS), the third is a HIT.
6. proxy_cache_use_stale updating + proxy_cache_background_update on: the first request
   after expiry gets STALE with the old body at once, a background subrequest refreshes it,
   and the next request is a HIT with the new body.
7. proxy_cache_lock on: of 5 concurrent requests for a missing entry one goes to the
   backend (MISS), the others wait (polling at most every 500 ms) and get HIT. Without
   the lock all 5 go to the backend.
8. proxy_cache_use_stale error http_500: when the backend fails after expiry, the old
   entry is sent with status STALE; without it the client gets the 500.
9. proxy_cache_revalidate on: an expired entry with an ETag is checked with a conditional
   request; the backend answers 304 and the status is REVALIDATED.
10. inactive=2s: the cache manager deletes an entry not accessed for 2 s, even if it is
    still valid.
11. proxy_cache_bypass with a non-empty, non-"0" value gives BYPASS.
