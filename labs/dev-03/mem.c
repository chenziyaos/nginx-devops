/*
 * dev-03: call nginx's memory APIs from a small program linked against the objects of the
 * pinned build (see labs/ctest.sh). Every subcommand prints one experiment.
 *
 *   mem pool | current | large | cleanup | chain | slab | shmtx
 */

#include <ngx_config.h>
#include <ngx_core.h>

#include <sys/wait.h>


static ngx_log_t    *lg;
static ngx_cycle_t   cycle;


static ngx_uint_t
nblocks(ngx_pool_t *pool)
{
    ngx_uint_t   n;
    ngx_pool_t  *p;

    for (n = 0, p = pool; p; p = p->d.next) {
        n++;
    }

    return n;
}


static ngx_uint_t
block_index(ngx_pool_t *pool, ngx_pool_t *b)
{
    ngx_uint_t   n;
    ngx_pool_t  *p;

    for (n = 0, p = pool; p != b; p = p->d.next) {
        n++;
    }

    return n;
}


/* where small allocations go: aligned or not, and what a new block looks like */

static void
pool_small(void)
{
    u_char      *a, *b, *c, *d, *e;
    ngx_pool_t  *pool;

    pool = ngx_create_pool(1024, lg);

    printf("sizeof(ngx_pool_t)=%zu, sizeof(ngx_pool_data_t)=%zu, ngx_pagesize=%lu\n",
           sizeof(ngx_pool_t), sizeof(ngx_pool_data_t), (unsigned long) ngx_pagesize);
    printf("ngx_create_pool(1024): max=%zu (1024 - sizeof(ngx_pool_t))\n", pool->max);

    a = ngx_palloc(pool, 1);
    b = ngx_palloc(pool, 1);
    c = ngx_pnalloc(pool, 1);
    d = ngx_pnalloc(pool, 1);

    printf("ngx_palloc(1) at +%td, ngx_palloc(1) at +%td, ngx_pnalloc(1) at +%td, "
           "ngx_pnalloc(1) at +%td\n",
           a - (u_char *) pool, b - (u_char *) pool, c - (u_char *) pool,
           d - (u_char *) pool);

    e = ngx_palloc(pool, 900);
    printf("ngx_palloc(900): blocks=%lu, at +%td\n",
           (unsigned long) nblocks(pool), e - (u_char *) pool);

    e = ngx_palloc(pool, 944);
    printf("ngx_palloc(944) (= max): blocks=%lu, at +%td in the new block, from the heap: %s\n",
           (unsigned long) nblocks(pool), e - (u_char *) pool->d.next,
           pool->large ? "yes" : "no");

    e = ngx_palloc(pool, 945);
    printf("ngx_palloc(945) (> max): blocks=%lu, from the heap: %s\n",
           (unsigned long) nblocks(pool), pool->large && pool->large->alloc == e ? "yes" : "no");

    printf("ngx_pfree(945-byte block)=%s, ngx_pfree(small)=%s\n",
           ngx_pfree(pool, e) == NGX_OK ? "NGX_OK" : "NGX_DECLINED",
           ngx_pfree(pool, a) == NGX_OK ? "NGX_OK" : "NGX_DECLINED");

    ngx_destroy_pool(pool);
}


/* pool->current skips a block that failed to serve an allocation more than 4 times */

static void
pool_current(void)
{
    ngx_uint_t   i;
    ngx_pool_t  *pool;

    pool = ngx_create_pool(1024, lg);

    for (i = 1; i <= 10; i++) {
        (void) ngx_palloc(pool, 600);
        printf("ngx_palloc(600) #%-2lu blocks=%-2lu current=block %lu, block 0 failed=%lu\n",
               (unsigned long) i, (unsigned long) nblocks(pool),
               (unsigned long) block_index(pool, pool->current),
               (unsigned long) pool->d.failed);
    }

    ngx_destroy_pool(pool);
}


/* large blocks: a freed slot is reused only if it is among the first 5 on the list */

static ngx_uint_t
nlarge(ngx_pool_t *pool)
{
    ngx_uint_t         n;
    ngx_pool_large_t  *l;

    for (n = 0, l = pool->large; l; l = l->next) {
        n++;
    }

    return n;
}


static void
pool_large(void)
{
    void        *p[6];
    ngx_uint_t   i;
    ngx_pool_t  *pool;

    pool = ngx_create_pool(1024, lg);

    for (i = 0; i < 6; i++) {
        p[i] = ngx_palloc(pool, 2000);
    }

    printf("6 large allocations: %lu list nodes (the newest first)\n",
           (unsigned long) nlarge(pool));

    (void) ngx_pfree(pool, p[0]);
    (void) ngx_palloc(pool, 2000);
    printf("free the oldest (6th on the list), allocate again: %lu nodes\n",
           (unsigned long) nlarge(pool));

    (void) ngx_pfree(pool, pool->large->alloc);
    (void) ngx_palloc(pool, 2000);
    printf("free the newest (1st on the list), allocate again: %lu nodes\n",
           (unsigned long) nlarge(pool));

    ngx_destroy_pool(pool);
}


/* cleanup handlers run in reverse order of registration */

static void
say(void *data)
{
    printf("cleanup %s\n", (char *) data);
}


static void
pool_cleanup(void)
{
    char                *names[] = { "a", "b", "c" };
    ngx_uint_t           i;
    ngx_pool_t          *pool;
    ngx_pool_cleanup_t  *cln;

    pool = ngx_create_pool(1024, lg);

    for (i = 0; i < 3; i++) {
        cln = ngx_pool_cleanup_add(pool, 0);
        cln->handler = say;
        cln->data = names[i];
        printf("add cleanup %s\n", names[i]);
    }

    ngx_destroy_pool(pool);
}


/* ngx_buf_t / ngx_chain_t: sizes, special buffers, free links and update_chains */

static ngx_chain_t *
link_buf(ngx_pool_t *pool, ngx_buf_tag_t tag, size_t left, ngx_chain_t *next)
{
    ngx_chain_t  *cl;

    cl = ngx_alloc_chain_link(pool);
    cl->buf = ngx_create_temp_buf(pool, 16);
    cl->buf->tag = tag;
    cl->buf->last += 8;
    cl->buf->pos = cl->buf->last - left;
    cl->next = next;

    return cl;
}


static void
names(const char *title, ngx_chain_t *cl, ngx_chain_t **all, const char *labels)
{
    ngx_uint_t  i;

    printf("%s:", title);

    for ( /* void */ ; cl; cl = cl->next) {
        for (i = 0; all[i]; i++) {
            if (all[i] == cl) {
                printf(" %c", labels[i]);
            }
        }
    }

    printf("\n");
}


static void
chain(void)
{
    int           mine, other;
    ngx_buf_t    *b, file;
    ngx_pool_t   *pool;
    ngx_chain_t  *cl, *cl2, *a, *bb, *c, *d, *out, *busy, *free;
    ngx_chain_t  *all[5];

    pool = ngx_create_pool(1024, lg);

    cl = ngx_alloc_chain_link(pool);
    ngx_free_chain(pool, cl);
    cl2 = ngx_alloc_chain_link(pool);
    printf("ngx_free_chain then ngx_alloc_chain_link returns the same link: %s\n",
           cl == cl2 ? "yes" : "no");

    b = ngx_create_temp_buf(pool, 100);
    b->last = ngx_cpymem(b->last, "0123456789", 10);
    printf("temp buf: temporary=%u, ngx_buf_size=%lld, room left=%td\n",
           b->temporary, (long long) ngx_buf_size(b), b->end - b->last);

    ngx_memzero(&file, sizeof(ngx_buf_t));
    file.in_file = 1;
    file.file_pos = 100;
    file.file_last = 4196;
    printf("file buf: in_memory=%d, ngx_buf_size=%lld\n",
           ngx_buf_in_memory(&file) ? 1 : 0, (long long) ngx_buf_size(&file));

    ngx_memzero(&file, sizeof(ngx_buf_t));
    file.last_buf = 1;
    printf("last_buf only: ngx_buf_special=%d, ngx_buf_size=%lld\n",
           ngx_buf_special(&file) ? 1 : 0, (long long) ngx_buf_size(&file));

    /* out = d (another tag, sent) -> a (sent) -> b (3 bytes left) -> c (sent) */
    c = link_buf(pool, &mine, 0, NULL);
    bb = link_buf(pool, &mine, 3, c);
    a = link_buf(pool, &mine, 0, bb);
    d = link_buf(pool, &other, 0, a);
    all[0] = a; all[1] = bb; all[2] = c; all[3] = d; all[4] = NULL;

    out = d;
    busy = NULL;
    free = NULL;
    ngx_chain_update_chains(pool, &free, &busy, &out, &mine);

    names("after ngx_chain_update_chains free", free, all, "abcd");
    names("busy", busy, all, "abcd");
    printf("d's link went to pool->chain: %s; a's buffer was reset: %s\n",
           pool->chain == d ? "yes" : "no",
           a->buf->pos == a->buf->start && a->buf->last == a->buf->start ? "yes" : "no");

    ngx_destroy_pool(pool);
}


/* the slab allocator on a shared mapping, as ngx_init_zone_pool sets it up */

static ngx_slab_pool_t *
zone(size_t size)
{
    ngx_shm_t         shm;
    ngx_slab_pool_t  *sp;

    ngx_memzero(&shm, sizeof(ngx_shm_t));
    shm.size = size;
    ngx_str_set(&shm.name, "lab");
    shm.log = lg;

    if (ngx_shm_alloc(&shm) != NGX_OK) {
        exit(1);
    }

    sp = (ngx_slab_pool_t *) shm.addr;
    sp->end = shm.addr + shm.size;
    sp->min_shift = 3;
    sp->addr = shm.addr;

    if (ngx_shmtx_create(&sp->mutex, &sp->lock, NULL) != NGX_OK) {
        exit(1);
    }

    ngx_slab_init(sp);

    return sp;
}


static const char *
page_type(ngx_slab_pool_t *sp, void *p)
{
    ngx_slab_page_t  *page;
    static const char *types[] = { "pages", "big", "exact", "small" };

    page = &sp->pages[((u_char *) p - sp->start) >> ngx_pagesize_shift];

    return types[page->prev & 3];
}


static void
slab(void)
{
    void             *p, *big[3];
    size_t            sizes[] = { 1, 8, 9, 100, 128, 129, 256, 257, 8192, 8193, 40000 };
    ngx_uint_t        i, before, slot, shift;
    ngx_slab_pool_t  *sp;

    sp = zone(1024 * 1024);

    printf("1 MB zone: sizeof(ngx_slab_pool_t)=%zu, slots=%lu, pages=%lu, "
           "first page at +%td\n",
           sizeof(ngx_slab_pool_t), (unsigned long) (ngx_pagesize_shift - sp->min_shift),
           (unsigned long) sp->pfree, sp->start - (u_char *) sp);

    for (i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        before = sp->pfree;
        p = ngx_slab_alloc(sp, sizes[i]);

        if (sizes[i] > (size_t) ngx_pagesize / 2) {
            printf("alloc %5zu -> %-5s %lu page(s)\n", sizes[i], page_type(sp, p),
                   (unsigned long) (before - sp->pfree));
            continue;
        }

        for (shift = 1; ((size_t) 1 << shift) < sizes[i]; shift++) { /* void */ }
        if (shift < sp->min_shift) {
            shift = sp->min_shift;
        }
        slot = shift - sp->min_shift;

        printf("alloc %5zu -> %-5s slot %lu (%lu-byte chunks), %lu per page, new page: %s\n",
               sizes[i], page_type(sp, p), (unsigned long) slot,
               (unsigned long) ((size_t) 1 << shift),
               (unsigned long) sp->stats[slot].total,
               before != sp->pfree ? "yes" : "no");
    }

    before = sp->pfree;
    for (i = 0; i < 3; i++) {
        big[i] = ngx_slab_alloc(sp, 2 * ngx_pagesize);
    }
    printf("3 x 2 pages: free pages %lu -> %lu", (unsigned long) before,
           (unsigned long) sp->pfree);
    for (i = 0; i < 3; i++) {
        ngx_slab_free(sp, big[i]);
    }
    printf(", after freeing them: %lu\n", (unsigned long) sp->pfree);

    for (i = 0; ngx_slab_alloc(sp, ngx_pagesize); i++) { /* void */ }
    printf("then whole pages until it fails: %lu more; stats for 8-byte chunks: "
           "reqs=%lu used=%lu fails=%lu\n", (unsigned long) i,
           (unsigned long) sp->stats[0].reqs, (unsigned long) sp->stats[0].used,
           (unsigned long) sp->stats[0].fails);
}


/* ngx_shmtx_t: the lock word holds the owner's pid */

static void
shmtx(void)
{
    pid_t            pid;
    ngx_uint_t       i, n;
    ngx_shm_t        shm;
    ngx_shmtx_t      mtx;
    ngx_shmtx_sh_t  *sh;
    ngx_atomic_t    *counter;

    ngx_memzero(&shm, sizeof(ngx_shm_t));
    shm.size = ngx_pagesize;
    ngx_str_set(&shm.name, "lock");
    shm.log = lg;
    if (ngx_shm_alloc(&shm) != NGX_OK) {
        exit(1);
    }

    sh = (ngx_shmtx_sh_t *) shm.addr;
    counter = (ngx_atomic_t *) (shm.addr + 64);

    ngx_memzero(&mtx, sizeof(ngx_shmtx_t));
    (void) ngx_shmtx_create(&mtx, sh, NULL);

    printf("spin=%lu, ngx_ncpu=%s, posix semaphore: %s\n", (unsigned long) mtx.spin,
           ngx_ncpu > 1 ? ">1" : "1",
#if (NGX_HAVE_POSIX_SEM)
           "yes"
#else
           "no"
#endif
           );

    for (n = 0; n < 4; n++) {
        if (fork() == 0) {
            ngx_pid = getpid();
            for (i = 0; i < 100000; i++) {
                ngx_shmtx_lock(&mtx);
                *counter = *counter + 1;
                ngx_shmtx_unlock(&mtx);
            }
            _exit(0);
        }
    }
    while (wait(NULL) > 0) { /* void */ }
    printf("4 processes x 100000 locked increments: %lu\n", (unsigned long) *counter);

    pid = fork();
    if (pid == 0) {
        ngx_pid = getpid();
        ngx_shmtx_lock(&mtx);
        _exit(0);
    }
    (void) waitpid(pid, NULL, 0);

    printf("a child locked it and exited: lock word == child pid: %s, trylock: %lu\n",
           *mtx.lock == (ngx_atomic_uint_t) pid ? "yes" : "no",
           (unsigned long) ngx_shmtx_trylock(&mtx));
    printf("ngx_shmtx_force_unlock(other pid): %lu, ngx_shmtx_force_unlock(child pid): %lu, "
           "trylock: %lu\n",
           (unsigned long) ngx_shmtx_force_unlock(&mtx, pid + 1),
           (unsigned long) ngx_shmtx_force_unlock(&mtx, pid),
           (unsigned long) ngx_shmtx_trylock(&mtx));
}


int
main(int argc, char **argv)
{
    ngx_uint_t  n;

    ngx_pagesize = getpagesize();
    for (n = ngx_pagesize; n >>= 1; ngx_pagesize_shift++) { /* void */ }
    ngx_cacheline_size = NGX_CPU_CACHE_LINE;
    ngx_ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    ngx_pid = getpid();
    ngx_time_init();

    lg = ngx_log_init((u_char *) "", (u_char *) "");
    cycle.log = lg;
    ngx_cycle = &cycle;
    ngx_slab_sizes_init();

    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc < 2) {
        return 1;
    }

    if (strcmp(argv[1], "pool") == 0) {
        pool_small();
    } else if (strcmp(argv[1], "current") == 0) {
        pool_current();
    } else if (strcmp(argv[1], "large") == 0) {
        pool_large();
    } else if (strcmp(argv[1], "cleanup") == 0) {
        pool_cleanup();
    } else if (strcmp(argv[1], "chain") == 0) {
        chain();
    } else if (strcmp(argv[1], "slab") == 0) {
        slab();
    } else if (strcmp(argv[1], "shmtx") == 0) {
        shmtx();
    } else {
        return 1;
    }

    return 0;
}
