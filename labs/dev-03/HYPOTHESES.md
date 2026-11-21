# dev-03 hypotheses (from the source, before running)

1. ngx_create_pool(1024): sizeof(ngx_pool_t) is 80 on 64-bit (ngx_pool_data_t is 32 of it),
   max = min(1024 - 80, ngx_pagesize - 1) = 944. ngx_palloc aligns d.last to NGX_ALIGNMENT,
   ngx_pnalloc does not. A new block (ngx_palloc_block) has the size of the first one and keeps
   only ngx_pool_data_t, so its first allocation is at +32. 944 bytes is still a small
   allocation, 945 goes to ngx_alloc and the large list; ngx_pfree only frees large blocks.
   Revised after the first run: NGX_ALIGNMENT is 16 on this machine, not 8. ngx_config.h
   defaults it to sizeof(uintptr_t), but auto/os/conf defines 16 for aarch64/arm64. The
   900-byte allocation still fits in block 0 (+112 after the 16-byte alignment), so the new
   block appears with the 944-byte allocation; the script was changed to show that.
2. ngx_palloc_block increments d.failed of every block from current to the tail, and moves
   current past a block when its old failed value was already above 4. With 600-byte
   allocations in a 1024-byte pool every allocation needs a new block; block 0 fails from
   the 3rd allocation on, reaches failed=5 at the 7th and is skipped at the 8th; after that
   current moves one block per allocation.
3. ngx_palloc_large looks for a free slot in at most the first 5 nodes of the large list
   (n++ > 3 breaks after the 5th), newest first. Freeing the oldest of 6 large blocks does not
   help (a 7th node is added); freeing the newest does (still 7).
4. ngx_pool_cleanup_add prepends, ngx_destroy_pool walks from the head: handlers run c, b, a.
5. ngx_free_chain pushes the link on pool->chain and ngx_alloc_chain_link pops it.
   ngx_buf_size is last - pos for a buffer in memory, file_last - file_pos otherwise; a
   last_buf-only buffer is ngx_buf_special with size 0. ngx_chain_update_chains moves out to
   busy, frees the links of other tags to pool->chain, moves consumed buffers of its tag to
   free (reset to start) and stops at the first one with data left: free = a, busy = b c.
6. Slab on a 1 MB zone with 16 KB pages (ngx_pagesize_shift 14, min_shift 3): 11 slots
   (8 .. 8192 bytes). ngx_slab_sizes_init: exact size = 16384 / 64 = 256, max = 8192. Sizes
   up to 128 are "small" (bitmap at the start of the page), 256 "exact" (bitmap in
   page->slab, 64 per page), 512 .. 8192 "big" (bitmap in the high 32 bits of page->slab),
   above 8192 whole pages. Per page: 8-byte chunks 2048 - 32 bitmap chunks = 2016, 16-byte
   1024 - 8 = 1016, 128-byte 128 - 1 = 127. The page count follows ngx_slab_init (recomputed
   in run.sh). Freed pages come back to pfree.
7. ngx_shmtx_lock: CAS of the lock word from 0 to ngx_pid, spin 2048, then sched_yield (no
   POSIX semaphores on macOS). 4 processes x 100000 locked increments = 400000. A process
   that exits holding the lock leaves its pid in the lock word; ngx_shmtx_force_unlock only
   clears it for that pid (the master does this in ngx_unlock_mutexes).
8. One request on a default server: the connection pool is 64 * sizeof(void *) = 512 bytes
   (created before the connection has its own log), the 1 KB client header buffer is larger
   than that pool's max (432) and comes from malloc, the request pool is 4096 bytes. On
   keepalive the request pool is destroyed and the header buffer is freed with ngx_pfree;
   the connection pool goes at close. With request_pool_size 16k one block is enough.
9. ngx_shared_memory_add: the same name with another tag is "already declared for a
   different use"; the same name with another size "conflicts with already declared size";
   a zone referenced with size 0 before its declaration takes the declared size; a zone
   never declared fails in ngx_init_cycle with "zero size shared memory zone".
