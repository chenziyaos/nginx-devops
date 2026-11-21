/*
 * dev-04: look at what configuration parsing builds. Linked against the objects of the
 * pinned build (see labs/ctest.sh).
 *
 *   cf dirs                      directives of the static modules, and names shared by modules
 *   cf tree PREFIX CONF          load CONF the way nginx -t does, then walk the http tree
 *
 * main() returns from -t before it stores the new cycle in ngx_cycle, so "tree" repeats the
 * steps of main() up to ngx_init_cycle() itself and keeps the cycle it returns.
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


extern ngx_module_t  *ngx_modules[];
extern char          *ngx_module_names[];


static void
dirs(void)
{
    ngx_uint_t      i, j, k, n, total, shared;
    ngx_command_t  *c, *d;

    total = 0;
    shared = 0;

    for (i = 0; ngx_modules[i]; i++) {
        for (c = ngx_modules[i]->commands; c && c->name.len; c++) {
            total++;
        }
    }

    printf("%lu static modules, %lu directives\n", (unsigned long) i,
           (unsigned long) total);

    /* names defined by more than one module, each listed once at its first module */

    for (i = 0; ngx_modules[i]; i++) {
        for (c = ngx_modules[i]->commands; c && c->name.len; c++) {

            for (j = 0; j < i; j++) {
                for (d = ngx_modules[j]->commands; d && d->name.len; d++) {
                    if (ngx_strcmp(d->name.data, c->name.data) == 0) {
                        goto seen;
                    }
                }
            }

            n = 0;
            for (k = i; ngx_modules[k]; k++) {
                for (d = ngx_modules[k]->commands; d && d->name.len; d++) {
                    if (ngx_strcmp(d->name.data, c->name.data) == 0) {
                        n++;
                    }
                }
            }

            if (n > 1) {
                shared++;
                if (ngx_strcmp(c->name.data, "server") == 0
                    || ngx_strcmp(c->name.data, "listen") == 0)
                {
                    printf("\"%s\" is defined by %lu modules:", c->name.data,
                           (unsigned long) n);
                    for (k = i; ngx_modules[k]; k++) {
                        for (d = ngx_modules[k]->commands; d && d->name.len; d++) {
                            if (ngx_strcmp(d->name.data, c->name.data) == 0) {
                                printf(" %s", ngx_module_names[k]);
                            }
                        }
                    }
                    printf("\n");
                }
            }

        seen:
            continue;
        }
    }

    printf("%lu names are defined by more than one module\n", (unsigned long) shared);
}


static ngx_uint_t  nloc;


static void
show(const char *server, ngx_http_core_loc_conf_t *clcf, ngx_http_core_loc_conf_t *parent)
{
    char  loc[64];

    nloc++;
    snprintf(loc, sizeof(loc), "%s%.*s",
             clcf->exact_match ? "= " : clcf->regex ? "~ " : "",
             (int) clcf->name.len, clcf->name.data);
    printf("  %-9s location %-12s client_max_body_size=%lldk parent=%.*s\n",
           server, loc, (long long) clcf->client_max_body_size / 1024,
           parent ? (int) parent->name.len : 6,
           parent ? (char *) parent->name.data : "server");
}


static void walk(const char *server, ngx_http_core_loc_conf_t *clcf);


static void
walk_tree(const char *server, ngx_http_location_tree_node_t *node,
    ngx_http_core_loc_conf_t *parent)
{
    if (node == NULL) {
        return;
    }

    walk_tree(server, node->left, parent);

    if (node->exact) {
        show(server, node->exact, parent);
        walk(server, node->exact);
    }

    if (node->inclusive) {
        show(server, node->inclusive, parent);
        walk(server, node->inclusive);
    }

    walk_tree(server, node->tree, parent);
    walk_tree(server, node->right, parent);
}


static void
walk(const char *server, ngx_http_core_loc_conf_t *clcf)
{
#if (NGX_PCRE)
    ngx_http_core_loc_conf_t  **r;
#endif

    walk_tree(server, clcf->static_locations, clcf->name.len ? clcf : NULL);

#if (NGX_PCRE)
    for (r = clcf->regex_locations; r && *r; r++) {
        show(server, *r, clcf->name.len ? clcf : NULL);
        walk(server, *r);
    }
#endif
}


static ngx_cycle_t *
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

    log = ngx_log_init((u_char *) prefix, (u_char *) "logs/cf.log");

    init_cycle.log = log;
    ngx_cycle = &init_cycle;
    init_cycle.pool = ngx_create_pool(1024, log);

    /* what ngx_process_options() sets from -p, -c and -g */
    init_cycle.prefix.data = (u_char *) prefix;
    init_cycle.prefix.len = ngx_strlen(prefix);
    init_cycle.conf_prefix = init_cycle.prefix;
    init_cycle.conf_file.len = init_cycle.prefix.len + ngx_strlen(conf);
    init_cycle.conf_file.data = ngx_pnalloc(init_cycle.pool, init_cycle.conf_file.len + 1);
    (void) ngx_sprintf(init_cycle.conf_file.data, "%s%s%Z", prefix, conf);
    ngx_str_set(&init_cycle.conf_param, "pid logs/cf.pid;");
    ngx_str_set(&init_cycle.error_log, "logs/cf.log");

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

    return cycle;
}


static void
tree(char **argv)
{
    char                        name[64];
    ngx_uint_t                  s;
    ngx_http_conf_ctx_t        *hctx;
    ngx_http_core_srv_conf_t  **cscfp;
    ngx_http_core_loc_conf_t   *hclcf, *clcf;
    ngx_http_core_main_conf_t  *cmcf;

    (void) load(argv, argv[2], argv[3]);

    hctx = (ngx_http_conf_ctx_t *) ngx_cycle->conf_ctx[ngx_http_module.index];
    cmcf = hctx->main_conf[ngx_http_core_module.ctx_index];
    hclcf = hctx->loc_conf[ngx_http_core_module.ctx_index];

    printf("ngx_http_max_module=%lu, servers=%lu\n", (unsigned long) ngx_http_max_module,
           (unsigned long) cmcf->servers.nelts);
    printf("http{}    client_max_body_size=%lldk (http-level loc_conf)\n",
           (long long) hclcf->client_max_body_size / 1024);

    cscfp = cmcf->servers.elts;
    nloc = 0;

    for (s = 0; s < cmcf->servers.nelts; s++) {
        clcf = cscfp[s]->ctx->loc_conf[ngx_http_core_module.ctx_index];

        snprintf(name, sizeof(name), "server %.*s",
                 (int) cscfp[s]->server_name.len, cscfp[s]->server_name.data);

        printf("%s: main_conf shared with http{}: %s, own srv_conf: %s, "
               "client_max_body_size=%lldk\n", name,
               cscfp[s]->ctx->main_conf == hctx->main_conf ? "yes" : "no",
               cscfp[s]->ctx->srv_conf != hctx->srv_conf ? "yes" : "no",
               (long long) clcf->client_max_body_size / 1024);

        snprintf(name, sizeof(name), "%.*s",
                 (int) cscfp[s]->server_name.len, cscfp[s]->server_name.data);
        walk(name, clcf);
    }

    printf("loc_conf arrays: 1 http + %lu server + %lu location = %lu, each with %lu slots\n",
           (unsigned long) cmcf->servers.nelts, (unsigned long) nloc,
           (unsigned long) (1 + cmcf->servers.nelts + nloc),
           (unsigned long) ngx_http_max_module);
}


int
main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc >= 2 && strcmp(argv[1], "dirs") == 0) {
        dirs();
        return 0;
    }

    if (argc == 4 && strcmp(argv[1], "tree") == 0) {
        tree(argv);
        return 0;
    }

    return 1;
}
