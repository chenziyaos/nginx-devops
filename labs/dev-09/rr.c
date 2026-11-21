/*
 * dev-09: drive the round robin balancer of the pinned build directly. The program builds an
 * ngx_http_upstream_rr_peers_t by hand (what ngx_http_upstream_init_round_robin builds from an
 * upstream{} block) and calls ngx_http_upstream_get_round_robin_peer and
 * ngx_http_upstream_free_round_robin_peer the way ngx_event_connect_peer and
 * ngx_http_upstream_next / finalize do.
 *
 *   rr swrr W1 W2 W3 N   N requests, print the pick and current_weight after each
 *   rr fail              weights 5 1 1, max_fails=2: A fails once, effective_weight recovers
 *   rr tries             one request, every server fails: tries and the tried bitmap
 *   rr sticky            weights 1 1 1: three requests with a SID hint for A, then two without
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


#define NPEERS  3

static ngx_log_t                     *lg;
static ngx_cycle_t                    cycle;
static ngx_http_upstream_rr_peer_t    peer[NPEERS];
static ngx_http_upstream_rr_peers_t   peers;
static struct sockaddr_in             sin[NPEERS];
static u_char                         sid[NPEERS][NGX_HTTP_UPSTREAM_SID_LEN];
static const char                    *names[NPEERS] = { "A", "B", "C" };


static void
setup(ngx_int_t *w, ngx_uint_t max_fails)
{
    ngx_uint_t  i;

    ngx_memzero(&peers, sizeof(peers));
    ngx_memzero(peer, sizeof(peer));

    for (i = 0; i < NPEERS; i++) {
        sin[i].sin_family = AF_INET;
        sin[i].sin_port = htons(19181 + i);
        sin[i].sin_addr.s_addr = htonl(INADDR_LOOPBACK);

        peer[i].sockaddr = (struct sockaddr *) &sin[i];
        peer[i].socklen = sizeof(struct sockaddr_in);
        peer[i].name.data = (u_char *) names[i];
        peer[i].name.len = 1;

        /* what ngx_http_upstream_init_round_robin copies from "server ... weight=" */
        peer[i].weight = w[i];
        peer[i].effective_weight = w[i];
        peer[i].current_weight = 0;
        peer[i].max_fails = max_fails;
        peer[i].fail_timeout = 10;

        /* the SID of a server without route=: the MD5 of its name */
        peer[i].sid.data = sid[i];
        ngx_http_upstream_init_round_robin_sid(&peer[i], NULL);

        peer[i].next = (i + 1 < NPEERS) ? &peer[i + 1] : NULL;
        peers.total_weight += w[i];
    }

    peers.number = NPEERS;
    peers.tries = NPEERS;
    peers.weighted = 1;
    peers.single = 0;
    peers.peer = peer;
}


/* the per-request state, as ngx_http_upstream_init_round_robin_peer sets it */

static void
request(ngx_http_upstream_rr_peer_data_t *rrp, ngx_peer_connection_t *pc)
{
    ngx_memzero(rrp, sizeof(*rrp));
    ngx_memzero(pc, sizeof(*pc));

    rrp->peers = &peers;
    rrp->tried = &rrp->data;
    rrp->data = 0;

    pc->tries = peers.tries;
    pc->log = lg;
    pc->data = rrp;
}


static const char *
picked(ngx_peer_connection_t *pc)
{
    ngx_uint_t  i;

    for (i = 0; i < NPEERS; i++) {
        if (pc->sockaddr == peer[i].sockaddr) {
            return names[i];
        }
    }

    return "?";
}


static void
weights(const char *field)
{
    ngx_uint_t  i;

    for (i = 0; i < NPEERS; i++) {
        printf("%s%3d", i ? " " : "", (int) (field[0] == 'c' ? peer[i].current_weight
                                                         : peer[i].effective_weight));
    }
}


static void
swrr(ngx_int_t *w, ngx_uint_t n)
{
    ngx_uint_t                        i;
    ngx_peer_connection_t             pc;
    ngx_http_upstream_rr_peer_data_t  rrp;

    setup(w, 1);

    printf("weights %d %d %d, total %d; current_weight A B C after each pick\n",
           (int) w[0], (int) w[1], (int) w[2], (int) peers.total_weight);

    for (i = 0; i < n; i++) {
        request(&rrp, &pc);

        if (ngx_http_upstream_get_round_robin_peer(&pc, &rrp) != NGX_OK) {
            printf("%2u: busy\n", (unsigned) (i + 1));
            return;
        }

        printf("%2u: %s  ", (unsigned) (i + 1), picked(&pc));
        weights("current");
        printf("\n");

        ngx_http_upstream_free_round_robin_peer(&pc, &rrp, 0);
    }
}


static void
fail(void)
{
    ngx_int_t                         w[NPEERS] = { 5, 1, 1 };
    ngx_uint_t                        i;
    ngx_peer_connection_t             pc;
    ngx_http_upstream_rr_peer_data_t  rrp;

    setup(w, 2);

    printf("weights 5 1 1, max_fails=2; effective_weight A B C, then current_weight A B C\n");

    for (i = 0; i < 8; i++) {
        request(&rrp, &pc);

        if (ngx_http_upstream_get_round_robin_peer(&pc, &rrp) != NGX_OK) {
            printf("%u: busy\n", (unsigned) (i + 1));
            return;
        }

        printf("%u: %s  ", (unsigned) (i + 1), picked(&pc));
        weights("effective");
        printf("  |");
        weights("current");

        if (i == 0) {
            /* the first request fails: ngx_http_upstream_next frees with NGX_PEER_FAILED */
            ngx_http_upstream_free_round_robin_peer(&pc, &rrp, NGX_PEER_FAILED);
            printf("  failed: fails=%u effective=%d\n", (unsigned) peer[0].fails,
                   (int) peer[0].effective_weight);

            /* and asks for the next server within the same request */
            if (ngx_http_upstream_get_round_robin_peer(&pc, &rrp) != NGX_OK) {
                printf("   busy\n");
                return;
            }

            printf("   retry: %s  ", picked(&pc));
            weights("effective");
            printf("  |");
            weights("current");
        }

        printf("\n");
        ngx_http_upstream_free_round_robin_peer(&pc, &rrp, 0);
    }
}


static void
tries(void)
{
    ngx_int_t                         w[NPEERS] = { 1, 1, 1 };
    ngx_int_t                         rc;
    ngx_peer_connection_t             pc;
    ngx_http_upstream_rr_peer_data_t  rrp;

    setup(w, 1);
    request(&rrp, &pc);

    printf("start: tries=%u tried=%#lx\n", (unsigned) pc.tries, (unsigned long) rrp.data);

    for ( ;; ) {
        rc = ngx_http_upstream_get_round_robin_peer(&pc, &rrp);

        if (rc != NGX_OK) {
            printf("get: %s (rc=%d)\n", rc == NGX_BUSY ? "NGX_BUSY" : "?", (int) rc);
            break;
        }

        printf("get: %s tried=%#lx", picked(&pc), (unsigned long) rrp.data);

        ngx_http_upstream_free_round_robin_peer(&pc, &rrp, NGX_PEER_FAILED);

        printf(" -> free(NGX_PEER_FAILED): tries=%u fails=%u\n", (unsigned) pc.tries,
               (unsigned) rrp.current->fails);
    }

    /* a new request: every server has fails >= max_fails within fail_timeout */
    request(&rrp, &pc);
    rc = ngx_http_upstream_get_round_robin_peer(&pc, &rrp);
    printf("next request: %s\n", rc == NGX_BUSY ? "NGX_BUSY" : picked(&pc));
}


static void
sticky(void)
{
    ngx_int_t                         w[NPEERS] = { 1, 1, 1 };
    ngx_uint_t                        i;
    ngx_peer_connection_t             pc;
    ngx_http_upstream_rr_peer_data_t  rrp;

    setup(w, 1);

    printf("weights 1 1 1; hint = SID of A (md5 of its name) for requests 1-3\n");

    for (i = 0; i < 5; i++) {
        request(&rrp, &pc);

        if (i < 3) {
            /* what ngx_http_upstream_sticky_get_peer puts into pc->hint */
            pc.hint = &peer[0].sid;
        }

        if (ngx_http_upstream_get_round_robin_peer(&pc, &rrp) != NGX_OK) {
            printf("%u: busy\n", (unsigned) (i + 1));
            return;
        }

        printf("%u: %-6s %s  ", (unsigned) (i + 1), i < 3 ? "hint=A" : "-", picked(&pc));
        weights("current");
        printf("\n");

        ngx_http_upstream_free_round_robin_peer(&pc, &rrp, 0);
    }
}


int
main(int argc, char **argv)
{
    ngx_int_t  w[NPEERS];

    ngx_pagesize = getpagesize();
    ngx_cacheline_size = NGX_CPU_CACHE_LINE;
    ngx_pid = getpid();
    ngx_time_init();

    lg = ngx_log_init((u_char *) "", (u_char *) "");
    lg->log_level = NGX_LOG_EMERG;
    cycle.log = lg;
    ngx_cycle = &cycle;

    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc < 2) {
        return 1;
    }

    if (strcmp(argv[1], "swrr") == 0 && argc == 6) {
        w[0] = atoi(argv[2]);
        w[1] = atoi(argv[3]);
        w[2] = atoi(argv[4]);
        swrr(w, atoi(argv[5]));

    } else if (strcmp(argv[1], "fail") == 0) {
        fail();

    } else if (strcmp(argv[1], "tries") == 0) {
        tries();

    } else if (strcmp(argv[1], "sticky") == 0) {
        sticky();

    } else {
        return 1;
    }

    return 0;
}
