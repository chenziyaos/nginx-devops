/*
 * dev-07: dump the rewrite module's code array of a server or a location, and the indexed
 * variables, as ngx_init_cycle builds them for conf/nginx.conf. Linked against the objects of
 * the pinned build (see labs/ctest.sh).
 *
 *   rw PREFIX CONF NAME...      NAME is "server" or the name of a prefix location
 *   rw PREFIX CONF -vars        the indexed variables and their flags
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


/* the same layout as in ngx_http_rewrite_module.c */
typedef struct {
    ngx_array_t  *codes;
    ngx_uint_t    stack_size;
    ngx_flag_t    log;
    ngx_flag_t    uninitialized_variable_warn;
} rewrite_loc_conf_t;

extern ngx_module_t  ngx_http_rewrite_module;

static ngx_http_core_main_conf_t  *cmcf;


static const char *
var_name(ngx_uint_t index, int *len)
{
    ngx_http_variable_t  *v = cmcf->variables.elts;

    *len = (int) v[index].name.len;
    return (const char *) v[index].name.data;
}


/* print one code, return its size */
static size_t
code(u_char *ip, size_t at)
{
    int                       n;
    const char               *s;
    ngx_http_script_code_pt   c = *(ngx_http_script_code_pt *) ip;

    printf("  %4lu  ", (unsigned long) at);

    if (c == NULL) {
        printf("stop\n");
        return sizeof(uintptr_t);
    }

    if (c == ngx_http_script_regex_start_code) {
        ngx_http_script_regex_code_t *rc = (void *) ip;
        printf("regex_start \"%.*s\" next=+%lu%s%s%s%s%s\n", (int) rc->name.len,
               rc->name.data, (unsigned long) rc->next, rc->uri ? " uri" : "",
               rc->test ? " test" : "", rc->break_cycle ? " break" : "",
               rc->redirect ? " redirect" : "", rc->add_args ? " add_args" : "");
        if (rc->status) {
            printf("        (status %lu)\n", (unsigned long) rc->status);
        }
        return sizeof(ngx_http_script_regex_code_t);
    }

    if (c == ngx_http_script_regex_end_code) {
        printf("regex_end\n");
        return sizeof(ngx_http_script_regex_end_code_t);
    }

    if (c == ngx_http_script_copy_code) {
        ngx_http_script_copy_code_t *cc = (void *) ip;
        printf("copy \"%.*s\"\n", (int) cc->len, ip + sizeof(ngx_http_script_copy_code_t));
        return sizeof(ngx_http_script_copy_code_t)
               + ((cc->len + sizeof(uintptr_t) - 1) & ~(sizeof(uintptr_t) - 1));
    }

    if (c == ngx_http_script_copy_capture_code) {
        ngx_http_script_copy_capture_code_t *cc = (void *) ip;
        printf("copy_capture $%lu\n", (unsigned long) cc->n / 2);
        return sizeof(ngx_http_script_copy_capture_code_t);
    }

    if (c == ngx_http_script_copy_var_code || c == ngx_http_script_var_code
        || c == ngx_http_script_set_var_code)
    {
        ngx_http_script_var_code_t *vc = (void *) ip;
        s = var_name(vc->index, &n);
        printf("%s $%.*s\n", c == ngx_http_script_copy_var_code ? "copy_var"
                             : c == ngx_http_script_var_code ? "push_var" : "set_var",
               n, s);
        return sizeof(ngx_http_script_var_code_t);
    }

    if (c == ngx_http_script_var_set_handler_code) {
        printf("set_var_handler\n");
        return sizeof(ngx_http_script_var_handler_code_t);
    }

    if (c == ngx_http_script_start_args_code) {
        printf("start_args\n");
        return sizeof(uintptr_t);
    }

    if (c == ngx_http_script_value_code) {
        ngx_http_script_value_code_t *vc = (void *) ip;
        printf("push_value \"%.*s\"\n", (int) vc->text_len, (char *) vc->text_data);
        return sizeof(ngx_http_script_value_code_t);
    }

    if (c == ngx_http_script_complex_value_code) {
        printf("complex_value\n");
        return sizeof(ngx_http_script_complex_value_code_t);
    }

    if (c == ngx_http_script_complex_value_end_code) {
        printf("complex_value_end\n");
        return sizeof(ngx_http_script_complex_value_end_code_t);
    }

    if (c == ngx_http_script_equal_code || c == ngx_http_script_not_equal_code) {
        printf("%s\n", c == ngx_http_script_equal_code ? "equal" : "not_equal");
        return sizeof(uintptr_t);
    }

    if (c == ngx_http_script_if_code) {
        ngx_http_script_if_code_t *ic = (void *) ip;
        printf("if next=+%lu%s\n", (unsigned long) ic->next,
               ic->loc_conf ? " (switches to the if{} location)" : "");
        return sizeof(ngx_http_script_if_code_t);
    }

    if (c == ngx_http_script_return_code) {
        ngx_http_script_return_code_t *rc = (void *) ip;
        printf("return %lu \"", (unsigned long) rc->status);
        for (n = 0; n < (int) rc->text.value.len; n++) {
            if (rc->text.value.data[n] == '\n') {
                printf("\\n");
            } else {
                putchar(rc->text.value.data[n]);
            }
        }
        printf("\"%s\n", rc->text.lengths ? " (with variables)" : "");
        return sizeof(ngx_http_script_return_code_t);
    }

    if (c == ngx_http_script_break_code) {
        printf("break\n");
        return sizeof(uintptr_t);
    }

    if (c == ngx_http_script_file_code) {
        printf("file\n");
        return sizeof(ngx_http_script_file_code_t);
    }

    printf("unknown code\n");
    exit(1);
}


static void
dump(const char *name, void **loc_conf)
{
    u_char              *p;
    size_t               at;
    rewrite_loc_conf_t  *rlcf;

    rlcf = loc_conf[ngx_http_rewrite_module.ctx_index];

    if (rlcf->codes == NULL) {
        printf("%s: no codes\n", name);
        return;
    }

    printf("%s: %lu bytes of codes, stack %lu\n", name,
           (unsigned long) rlcf->codes->nelts, (unsigned long) rlcf->stack_size);

    p = rlcf->codes->elts;

    for (at = 0; at < rlcf->codes->nelts; /* void */) {
        at += code(p + at, at);
    }
}


static ngx_http_core_loc_conf_t *
find(ngx_http_location_tree_node_t *node, const char *name)
{
    ngx_http_core_loc_conf_t  *clcf;

    if (node == NULL) {
        return NULL;
    }

    clcf = node->exact ? node->exact : node->inclusive;

    if (clcf && clcf->name.len == strlen(name)
        && ngx_strncmp(clcf->name.data, name, clcf->name.len) == 0)
    {
        return clcf;
    }

    if ((clcf = find(node->left, name)) || (clcf = find(node->right, name))
        || (clcf = find(node->tree, name)))
    {
        return clcf;
    }

    return NULL;
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

    log = ngx_log_init((u_char *) prefix, (u_char *) "logs/rw.log");

    init_cycle.log = log;
    ngx_cycle = &init_cycle;
    init_cycle.pool = ngx_create_pool(1024, log);

    init_cycle.prefix.data = (u_char *) prefix;
    init_cycle.prefix.len = ngx_strlen(prefix);
    init_cycle.conf_prefix = init_cycle.prefix;
    init_cycle.conf_file.len = init_cycle.prefix.len + ngx_strlen(conf);
    init_cycle.conf_file.data = ngx_pnalloc(init_cycle.pool, init_cycle.conf_file.len + 1);
    (void) ngx_sprintf(init_cycle.conf_file.data, "%s%s%Z", prefix, conf);
    ngx_str_set(&init_cycle.conf_param, "pid logs/rw.pid;");
    ngx_str_set(&init_cycle.error_log, "logs/rw.log");

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
    int                         i;
    ngx_uint_t                  k;
    ngx_http_variable_t        *v;
    ngx_http_conf_ctx_t        *hctx;
    ngx_http_core_srv_conf_t  **cscfp;
    ngx_http_core_loc_conf_t   *clcf, *sclcf;

    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc < 4) {
        return 1;
    }

    load(argv, argv[1], argv[2]);

    hctx = (ngx_http_conf_ctx_t *) ngx_cycle->conf_ctx[ngx_http_module.index];
    cmcf = hctx->main_conf[ngx_http_core_module.ctx_index];

    if (strcmp(argv[3], "-vars") == 0) {
        v = cmcf->variables.elts;
        printf("%lu indexed variables, %lu prefix variables\n",
               (unsigned long) cmcf->variables.nelts,
               (unsigned long) cmcf->prefix_variables.nelts);
        for (k = 0; k < cmcf->variables.nelts; k++) {
            printf("  %2lu $%-24.*s%s%s%s\n", (unsigned long) k, (int) v[k].name.len,
                   v[k].name.data,
                   v[k].flags & NGX_HTTP_VAR_CHANGEABLE ? " changeable" : "",
                   v[k].flags & NGX_HTTP_VAR_NOCACHEABLE ? " nocacheable" : "",
                   v[k].flags & NGX_HTTP_VAR_PREFIX ? " prefix" : "");
        }
        return 0;
    }

    cscfp = cmcf->servers.elts;
    sclcf = cscfp[0]->ctx->loc_conf[ngx_http_core_module.ctx_index];

    for (i = 3; i < argc; i++) {
        if (strcmp(argv[i], "server") == 0) {
            dump("server", cscfp[0]->ctx->loc_conf);
            continue;
        }

        clcf = find(sclcf->static_locations, argv[i]);
        if (clcf == NULL) {
            printf("%s: no such location\n", argv[i]);
            continue;
        }

        dump(argv[i], clcf->loc_conf);
    }

    return 0;
}
