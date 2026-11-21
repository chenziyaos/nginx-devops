# dev-02 hypotheses (from the source, before running)

1. ngx_str_t is { size_t len; u_char *data; } (16 bytes on 64-bit); ngx_string() uses
   sizeof - 1; a slice points into the original bytes, so the byte after it is whatever
   follows in the original (here ':').
2. ngx_array_push on a full array: if the elements are the last allocation of the pool and
   the block has room for one more, d.last moves by one element and nalloc grows by 1;
   otherwise ngx_palloc(2 * size), memcpy, nalloc *= 2. Created with 2: 2 2 3 4 5, then
   after another allocation 10 10 with a move.
3. ngx_list_push never moves elements: a full part gets a new part of nalloc elements.
   10 elements with nalloc 4: parts of 4, 4, 2.
4. ngx_queue_sort is a merge sort (ngx_queue_middle, split, merge with cmp <= 0 taking the
   left element first), so it is stable: 1b 1e 2d 3a 3c.
5. ngx_hash_add_key with NGX_HASH_WILDCARD_KEY: "*.example.com" goes to dns_wc_head as
   "com.example.", ".example.org" as "org.example" (matches the bare name too),
   "www.example.*" to dns_wc_tail as "www.example". ngx_hash_find_combined tries exact,
   then head, then tail. Lookups do not fold case (callers lowercase first).
   ngx_hash_init picks the smallest size from nelts / ((bucket - 8) / 16) up where every
   bucket holds at most bucket - 8 bytes of elements (8 + align(len + 2, 8) each).
6. A bucket must hold one element plus the 8-byte end marker: with a bucket of B bytes the
   longest name is the largest len with 8 + align(len + 2, 8) + 8 <= B. The default
   server_names_hash_bucket_size is ngx_cacheline_size (hw.cachelinesize on macOS: 128 on
   this machine, so 110 bytes; 64 on most x86 Linux, so 46 bytes).
   Revised after the first run: a single server on an address never builds the names hash
   (ngx_http_optimize_servers only calls ngx_http_server_names when servers.nelts > 1), so
   the test needs a second server.
7. ngx_rbtree_insert_value sends equal keys right, so an in-order walk lists them in
   insertion order; after the inserts the root is black, no red node has a red child, and
   every path has the same number of black nodes.
8. ngx_rbtree_insert_timer_value compares (ngx_rbtree_key_int_t) (a - b), so a key just
   before the wrap sorts before a key just after it; ngx_rbtree_insert_value does not.
9. ngx_radix32tree_insert returns NGX_BUSY for a prefix that already has a value;
   ngx_radix32tree_find returns the value of the longest matching prefix, or
   NGX_RADIX_NO_VALUE.
