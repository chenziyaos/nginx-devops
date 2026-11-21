/*
 * dev-06: read the phase engine and the heads of the filter chains that ngx_init_cycle builds
 * for conf/nginx.conf. Linked against the objects of the pinned build (see labs/ctest.sh).
 *
 *   ph PREFIX CONF
 *
 * Module handlers and filters are static functions, so they are printed as offsets from
 * ngx_http_core_run_phases; run.sh turns the offsets into names with nm.
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


static const char *
checker_name(ngx_http_phase_handler_pt c)
{
    if (c == ngx_http_core_generic_phase) {
        return "generic";
    }
    if (c == ngx_http_core_rewrite_phase) {
        return "rewrite";
    }
    if (c == ngx_http_core_find_config_phase) {
        return "find_config";
    }
    if (c == ngx_http_core_post_rewrite_phase) {
        return "post_rewrite";
    }
    if (c == ngx_http_core_access_phase) {
        return "access";
    }
    if (c == ngx_http_core_post_access_phase) {
        return "post_access";
    }
    if (c == ngx_http_core_content_phase) {
        return "content";
    }
    return "?";
}


static long
off(void *p)
{
    return p ? (long) ((uintptr_t) p - (uintptr_t) ngx_http_core_run_phases) : 0;
}


/* the same steps as main() up to ngx_init_cycle(), as in labs/dev-04/cf.c */
static void
load(char **argv, char *prefix, char *conf)
{
    ngx_log_t    *log;
    ngx_cycle_t  *cycle;
    static ngx_cycle_t  init_cycle;

    ngx_argc = 1;
    ngx_argv = argv;
    ngx_os_argv = argv;

    (void) ngx_strerror_init();
    ngx_time_init();
#if (NGX_PCRE)
    ngx_regex_init();
#endif
    ngx_pid = ngx_getpid();
    ngx_parent = ngx_getppid();

    log = ngx_log_init((u_char *) prefix, (u_char *) "logs/ph.log");

    init_cycle.log = log;
    ngx_cycle = &init_cycle;
    init_cycle.pool = ngx_create_pool(1024, log);

    init_cycle.prefix.data = (u_char *) prefix;
    init_cycle.prefix.len = ngx_strlen(prefix);
    init_cycle.conf_prefix = init_cycle.prefix;
    init_cycle.conf_file.len = init_cycle.prefix.len + ngx_strlen(conf);
    init_cycle.conf_file.data = ngx_pnalloc(init_cycle.pool, init_cycle.conf_file.len + 1);
    (void) ngx_sprintf(init_cycle.conf_file.data, "%s%s%Z", prefix, conf);
    ngx_str_set(&init_cycle.conf_param, "pid logs/ph.pid;");
    ngx_str_set(&init_cycle.error_log, "logs/ph.log");

    if (ngx_os_init(log) != NGX_OK) {
        exit(1);
    }
    ngx_crc32_table_init();
    ngx_slab_sizes_init();
    if (ngx_preinit_modules() != NGX_OK) {
        exit(1);
    }

    ngx_test_config = 1;
    ngx_quiet_mode = 1;

    cycle = ngx_init_cycle(&init_cycle);
    if (cycle == NULL) {
        exit(1);
    }

    ngx_cycle = cycle;
}


int
main(int argc, char **argv)
{
    ngx_uint_t                  i;
    ngx_http_conf_ctx_t        *hctx;
    ngx_http_phase_handler_t   *ph;
    ngx_http_core_main_conf_t  *cmcf;

    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc != 3) {
        return 1;
    }

    load(argv, argv[1], argv[2]);

    hctx = (ngx_http_conf_ctx_t *) ngx_cycle->conf_ctx[ngx_http_module.index];
    cmcf = hctx->main_conf[ngx_http_core_module.ctx_index];
    ph = cmcf->phase_engine.handlers;

    printf("server_rewrite_index=%lu location_rewrite_index=%lu\n",
           (unsigned long) cmcf->phase_engine.server_rewrite_index,
           (unsigned long) cmcf->phase_engine.location_rewrite_index);

    for (i = 0; ph[i].checker; i++) {
        printf("%2lu %-12s next=%-2lu handler=%+ld\n", (unsigned long) i,
               checker_name(ph[i].checker), (unsigned long) ph[i].next, off(ph[i].handler));
    }

    printf("top header filter=%+ld\n", off(ngx_http_top_header_filter));
    printf("top body filter=%+ld\n", off(ngx_http_top_body_filter));

    return 0;
}
