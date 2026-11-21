/*
 * dev-02: call nginx's own data structures from a small program linked against the objects
 * of the pinned build (see labs/ctest.sh). Every subcommand prints one experiment.
 *
 *   ds str | array | list | queue | hash NAME... | rbtree | timer | radix
 */

#include <ngx_config.h>
#include <ngx_core.h>


static ngx_pool_t  *pool;
static ngx_log_t   *lg;


/* ngx_str_t: a length and a pointer, no terminating NUL */

static void
str(void)
{
    u_char      buf[64], *last;
    ngx_str_t   host = ngx_string("Example.COM:8080");
    ngx_str_t   name, port;
    u_char     *colon;

    colon = ngx_strlchr(host.data, host.data + host.len, ':');

    name.data = host.data;
    name.len = colon - host.data;
    port.data = colon + 1;
    port.len = host.data + host.len - port.data;

    printf("sizeof(ngx_str_t)=%zu, ngx_string(\"Example.COM:8080\").len=%zu\n",
           sizeof(ngx_str_t), host.len);

    last = ngx_snprintf(buf, sizeof(buf), "name=[%V] port=[%V] port as int=%i",
                        &name, &port, ngx_atoi(port.data, port.len));
    printf("%.*s\n", (int) (last - buf), buf);

    ngx_strlow(buf, name.data, name.len);
    printf("ngx_strlow: %.*s; the byte after name in the original: '%c'\n",
           (int) name.len, buf, name.data[name.len]);
}


/* ngx_array_t: grows in place while it is the last allocation of the pool */

static void
array(void)
{
    ngx_uint_t    i, *p;
    u_char       *first;
    ngx_array_t  *a;

    a = ngx_array_create(pool, 2, sizeof(ngx_uint_t));
    first = a->elts;

    for (i = 0; i < 5; i++) {
        p = ngx_array_push(a);
        *p = i;
        printf("push %lu: nelts=%lu nalloc=%lu moved=%s\n", (unsigned long) i,
               (unsigned long) a->nelts, (unsigned long) a->nalloc,
               (u_char *) a->elts == first ? "no" : "yes");
    }

    /* another allocation after the array: the next push that needs room must copy */
    (void) ngx_palloc(pool, 8);

    for (i = 5; i < 7; i++) {
        p = ngx_array_push(a);
        *p = i;
        printf("push %lu: nelts=%lu nalloc=%lu moved=%s\n", (unsigned long) i,
               (unsigned long) a->nelts, (unsigned long) a->nalloc,
               (u_char *) a->elts == first ? "no" : "yes");
    }
}


/* ngx_list_t: a chain of fixed-size parts; elements never move */

static void
list(void)
{
    ngx_uint_t        i, n, *p, *third;
    ngx_list_t       *l;
    ngx_list_part_t  *part;

    l = ngx_list_create(pool, 4, sizeof(ngx_uint_t));

    third = NULL;

    for (i = 0; i < 10; i++) {
        p = ngx_list_push(l);
        *p = i;
        if (i == 2) {
            third = p;
        }
    }

    n = 0;
    for (part = &l->part; part; part = part->next) {
        printf("part %lu: nelts=%lu first=%lu\n", (unsigned long) n++,
               (unsigned long) part->nelts, (unsigned long) *(ngx_uint_t *) part->elts);
    }

    printf("element 2 is still at the same address: %s\n",
           third == (ngx_uint_t *) l->part.elts + 2 ? "yes" : "no");
}


/* ngx_queue_t: an intrusive list; ngx_queue_sort is a stable merge sort */

typedef struct {
    ngx_uint_t   key;
    char         tag;
    ngx_queue_t  link;
} item_t;


static ngx_int_t
cmp_item(const ngx_queue_t *a, const ngx_queue_t *b)
{
    item_t  *x = ngx_queue_data(a, item_t, link);
    item_t  *y = ngx_queue_data(b, item_t, link);

    return (ngx_int_t) x->key - (ngx_int_t) y->key;
}


static void
queue(void)
{
    static item_t  items[] = {
        { 3, 'a', { NULL, NULL } }, { 1, 'b', { NULL, NULL } },
        { 3, 'c', { NULL, NULL } }, { 2, 'd', { NULL, NULL } },
        { 1, 'e', { NULL, NULL } }
    };

    ngx_uint_t    i;
    ngx_queue_t   head, *q;
    item_t       *it;

    ngx_queue_init(&head);

    for (i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
        ngx_queue_insert_tail(&head, &items[i].link);
    }

    ngx_queue_sort(&head, cmp_item);

    printf("sorted:");
    for (q = ngx_queue_head(&head); q != ngx_queue_sentinel(&head); q = ngx_queue_next(q)) {
        it = ngx_queue_data(q, item_t, link);
        printf(" %lu%c", (unsigned long) it->key, it->tag);
    }

    it = ngx_queue_data(ngx_queue_middle(&head), item_t, link);
    printf("\nmiddle: %lu%c, offsetof(item_t, link)=%zu\n",
           (unsigned long) it->key, it->tag, offsetof(item_t, link));
}


/* ngx_hash_t: exact names plus head and tail wildcards, as server_name builds them */

static int
cmp_dns(const void *one, const void *two)
{
    return (int) ngx_dns_strcmp(((ngx_hash_key_t *) one)->key.data,
                                ((ngx_hash_key_t *) two)->key.data);
}


static void
hash(int argc, char **argv)
{
    static ngx_str_t  names[] = {
        ngx_string("example.com"), ngx_string("www.example.com"),
        ngx_string("api.example.com"), ngx_string("static.example.com"),
        ngx_string("*.example.com"), ngx_string(".example.org"),
        ngx_string("www.example.*")
    };

    /* the values must be 4-byte aligned: the wildcard hash uses the 2 low bits */
    static ngx_uint_t  values[sizeof(names) / sizeof(names[0])];

    int                     i;
    ngx_uint_t              n, k;
    ngx_str_t               s;
    ngx_hash_key_t         *key;
    ngx_hash_init_t         hinit;
    ngx_hash_combined_t     combined;
    ngx_hash_keys_arrays_t  ha;
    void                   *v;

    ngx_memzero(&ha, sizeof(ngx_hash_keys_arrays_t));
    ha.pool = pool;
    ha.temp_pool = ngx_create_pool(16384, lg);
    ngx_hash_keys_array_init(&ha, NGX_HASH_SMALL);

    for (n = 0; n < sizeof(names) / sizeof(names[0]); n++) {
        values[n] = n;
        /* ngx_hash_add_key lowercases wildcard keys in place: give it writable copies */
        s.len = names[n].len;
        s.data = ngx_pstrdup(pool, &names[n]);
        ngx_hash_add_key(&ha, &s, &values[n], NGX_HASH_WILDCARD_KEY);
    }

    printf("exact keys: %lu, head wildcards: %lu, tail wildcards: %lu\n",
           (unsigned long) ha.keys.nelts, (unsigned long) ha.dns_wc_head.nelts,
           (unsigned long) ha.dns_wc_tail.nelts);

    key = ha.dns_wc_head.elts;
    for (n = 0; n < ha.dns_wc_head.nelts; n++) {
        printf("head key stored as \"%.*s\"\n", (int) key[n].key.len, key[n].key.data);
    }
    key = ha.dns_wc_tail.elts;
    for (n = 0; n < ha.dns_wc_tail.nelts; n++) {
        printf("tail key stored as \"%.*s\"\n", (int) key[n].key.len, key[n].key.data);
    }

    ngx_memzero(&combined, sizeof(ngx_hash_combined_t));

    hinit.key = ngx_hash_key_lc;
    hinit.max_size = 512;
    hinit.bucket_size = ngx_align(64, ngx_cacheline_size);
    hinit.name = "test_hash";
    hinit.pool = pool;

    hinit.hash = &combined.hash;
    hinit.temp_pool = NULL;
    ngx_hash_init(&hinit, ha.keys.elts, ha.keys.nelts);
    printf("exact hash: bucket_size=%lu, size=%lu\n",
           (unsigned long) hinit.bucket_size, (unsigned long) combined.hash.size);

    key = ha.keys.elts;
    for (n = 0; n < ha.keys.nelts; n++) {
        printf("  %-20.*s key_hash=%lu bucket=%lu elt_size=%lu\n",
               (int) key[n].key.len, key[n].key.data, (unsigned long) key[n].key_hash,
               (unsigned long) (key[n].key_hash % combined.hash.size),
               (unsigned long) (sizeof(void *) + ngx_align(key[n].key.len + 2, sizeof(void *))));
    }

    ngx_qsort(ha.dns_wc_head.elts, ha.dns_wc_head.nelts, sizeof(ngx_hash_key_t), cmp_dns);
    hinit.hash = NULL;
    hinit.temp_pool = ha.temp_pool;
    ngx_hash_wildcard_init(&hinit, ha.dns_wc_head.elts, ha.dns_wc_head.nelts);
    combined.wc_head = (ngx_hash_wildcard_t *) hinit.hash;

    ngx_qsort(ha.dns_wc_tail.elts, ha.dns_wc_tail.nelts, sizeof(ngx_hash_key_t), cmp_dns);
    hinit.hash = NULL;
    ngx_hash_wildcard_init(&hinit, ha.dns_wc_tail.elts, ha.dns_wc_tail.nelts);
    combined.wc_tail = (ngx_hash_wildcard_t *) hinit.hash;

    for (i = 0; i < argc; i++) {
        s.data = (u_char *) argv[i];
        s.len = ngx_strlen(argv[i]);
        k = ngx_hash_key(s.data, s.len);
        v = ngx_hash_find_combined(&combined, k, s.data, s.len);
        if (v) {
            printf("find %-22s -> %.*s\n", argv[i], (int) names[*(ngx_uint_t *) v].len,
                   names[*(ngx_uint_t *) v].data);
        } else {
            printf("find %-22s -> not found\n", argv[i]);
        }
    }
}


/* ngx_rbtree_t: equal keys go right, so an in-order walk keeps insertion order */

typedef struct {
    ngx_rbtree_node_t  node;
    char               tag;
} rbitem_t;


static ngx_int_t
check(ngx_rbtree_node_t *n, ngx_rbtree_node_t *s, ngx_uint_t *bad)
{
    ngx_int_t  l, r;

    if (n == s) {
        return 1;
    }

    if (ngx_rbt_is_red(n) && (ngx_rbt_is_red(n->left) || ngx_rbt_is_red(n->right))) {
        (*bad)++;
    }

    l = check(n->left, s, bad);
    r = check(n->right, s, bad);

    if (l != r) {
        (*bad)++;
    }

    return l + (ngx_rbt_is_black(n) ? 1 : 0);
}


static void
rbtree(void)
{
    static ngx_uint_t  keys[] = { 50, 20, 70, 20, 10, 60, 80, 20, 90, 30 };

    ngx_uint_t          i, bad;
    ngx_int_t           bh;
    ngx_rbtree_t        tree;
    ngx_rbtree_node_t   sentinel, *n;
    rbitem_t           *it;

    ngx_rbtree_init(&tree, &sentinel, ngx_rbtree_insert_value);

    for (i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
        it = ngx_pcalloc(pool, sizeof(rbitem_t));
        it->node.key = keys[i];
        it->tag = 'a' + i;
        ngx_rbtree_insert(&tree, &it->node);
    }

    printf("in order:");
    for (n = ngx_rbtree_min(tree.root, tree.sentinel); n; n = ngx_rbtree_next(&tree, n)) {
        it = (rbitem_t *) n;
        printf(" %lu%c", (unsigned long) n->key, it->tag);
    }

    bad = 0;
    bh = check(tree.root, tree.sentinel, &bad);
    printf("\nroot is black: %s, red nodes with a red child or unequal black heights: %lu, "
           "black height: %ld\n",
           ngx_rbt_is_black(tree.root) ? "yes" : "no", (unsigned long) bad, (long) bh);
}


/* the timer tree compares keys as signed differences, so it survives a wrap-around */

static void
timer(void)
{
    ngx_rbtree_t        plain, timers;
    ngx_rbtree_node_t   s1, s2, a1, b1, a2, b2;

    ngx_rbtree_init(&plain, &s1, ngx_rbtree_insert_value);
    ngx_rbtree_init(&timers, &s2, ngx_rbtree_insert_timer_value);

    /* "a" is due 16 ms before the counter wraps, "b" 16 ms after it */
    a1.key = a2.key = (ngx_rbtree_key_t) -16;
    b1.key = b2.key = 16;

    ngx_rbtree_insert(&plain, &a1);
    ngx_rbtree_insert(&plain, &b1);
    ngx_rbtree_insert(&timers, &a2);
    ngx_rbtree_insert(&timers, &b2);

    printf("insert_value:       min is %s\n",
           ngx_rbtree_min(plain.root, plain.sentinel) == &a1 ? "a (2^64-16)" : "b (16)");
    printf("insert_timer_value: min is %s\n",
           ngx_rbtree_min(timers.root, timers.sentinel) == &a2 ? "a (2^64-16)" : "b (16)");
}


/* ngx_radix_tree_t: longest-prefix match on 32-bit keys */

static void
radix(void)
{
    static const char  *addrs[] = { "10.1.2.3", "10.2.0.1", "11.0.0.1", "10.1.255.255" };

    ngx_uint_t         i;
    uintptr_t          v;
    ngx_radix_tree_t  *t;

    t = ngx_radix_tree_create(pool, -1);

    ngx_radix32tree_insert(t, 0x0a000000, 0xff000000, 1);   /* 10.0.0.0/8 */
    ngx_radix32tree_insert(t, 0x0a010000, 0xffff0000, 2);   /* 10.1.0.0/16 */

    printf("insert 10.0.0.0/8 again: %s\n",
           ngx_radix32tree_insert(t, 0x0a000000, 0xff000000, 3) == NGX_BUSY ? "NGX_BUSY" : "ok");

    for (i = 0; i < sizeof(addrs) / sizeof(addrs[0]); i++) {
        v = ngx_radix32tree_find(t, ntohl(inet_addr(addrs[i])));
        if (v == NGX_RADIX_NO_VALUE) {
            printf("find %-13s -> no value\n", addrs[i]);
        } else {
            printf("find %-13s -> %lu\n", addrs[i], (unsigned long) v);
        }
    }
}


int
main(int argc, char **argv)
{
    ngx_pagesize = getpagesize();
    ngx_cacheline_size = NGX_CPU_CACHE_LINE;
    ngx_time_init();

    lg = ngx_log_init((u_char *) "", (u_char *) "");
    pool = ngx_create_pool(1024, lg);

    if (argc < 2) {
        return 1;
    }

    if (strcmp(argv[1], "str") == 0) {
        str();
    } else if (strcmp(argv[1], "array") == 0) {
        array();
    } else if (strcmp(argv[1], "list") == 0) {
        list();
    } else if (strcmp(argv[1], "queue") == 0) {
        queue();
    } else if (strcmp(argv[1], "hash") == 0) {
        hash(argc - 2, argv + 2);
    } else if (strcmp(argv[1], "rbtree") == 0) {
        rbtree();
    } else if (strcmp(argv[1], "timer") == 0) {
        timer();
    } else if (strcmp(argv[1], "radix") == 0) {
        radix();
    } else {
        return 1;
    }

    return 0;
}
