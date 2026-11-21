
/*
 * ngx_http_hello_module: the example module of the nginx-devops tutorial.
 *
 *   hello <text>;            location: answer every request with <text>
 *   hello_header <value>;    http, server, location: add "X-Hello: <value>"
 *                            to responses; <value> may contain variables
 *   $hello_requests          requests answered by "hello" in this worker
 */


#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


typedef struct {
    ngx_str_t                  text;
    ngx_http_complex_value_t  *header;
} ngx_http_hello_loc_conf_t;


static ngx_int_t ngx_http_hello_handler(ngx_http_request_t *r);
static ngx_int_t ngx_http_hello_header_filter(ngx_http_request_t *r);
static ngx_int_t ngx_http_hello_requests_variable(ngx_http_request_t *r,
    ngx_http_variable_value_t *v, uintptr_t data);
static char *ngx_http_hello(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static ngx_int_t ngx_http_hello_add_variables(ngx_conf_t *cf);
static void *ngx_http_hello_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_hello_merge_loc_conf(ngx_conf_t *cf, void *parent,
    void *child);
static ngx_int_t ngx_http_hello_init(ngx_conf_t *cf);


static ngx_command_t  ngx_http_hello_commands[] = {

    { ngx_string("hello"),
      NGX_HTTP_LOC_CONF|NGX_CONF_TAKE1,
      ngx_http_hello,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_hello_loc_conf_t, text),
      NULL },

    { ngx_string("hello_header"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE1,
      ngx_http_set_complex_value_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_hello_loc_conf_t, header),
      NULL },

      ngx_null_command
};


static ngx_http_module_t  ngx_http_hello_module_ctx = {
    ngx_http_hello_add_variables,          /* preconfiguration */
    ngx_http_hello_init,                   /* postconfiguration */

    NULL,                                  /* create main configuration */
    NULL,                                  /* init main configuration */

    NULL,                                  /* create server configuration */
    NULL,                                  /* merge server configuration */

    ngx_http_hello_create_loc_conf,        /* create location configuration */
    ngx_http_hello_merge_loc_conf          /* merge location configuration */
};


ngx_module_t  ngx_http_hello_module = {
    NGX_MODULE_V1,
    &ngx_http_hello_module_ctx,            /* module context */
    ngx_http_hello_commands,               /* module directives */
    NGX_HTTP_MODULE,                       /* module type */
    NULL,                                  /* init master */
    NULL,                                  /* init module */
    NULL,                                  /* init process */
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    NULL,                                  /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};


static ngx_http_variable_t  ngx_http_hello_vars[] = {

    { ngx_string("hello_requests"), NULL, ngx_http_hello_requests_variable,
      0, NGX_HTTP_VAR_NOCACHEABLE, 0 },

      ngx_http_null_variable
};


static ngx_http_output_header_filter_pt  ngx_http_next_header_filter;

/* per worker: every worker process has its own copy after fork() */
static ngx_atomic_uint_t  ngx_http_hello_requests;


static ngx_int_t
ngx_http_hello_handler(ngx_http_request_t *r)
{
    ngx_int_t                   rc;
    ngx_buf_t                  *b;
    ngx_chain_t                 out;
    ngx_http_hello_loc_conf_t  *hlcf;

    if (!(r->method & (NGX_HTTP_GET|NGX_HTTP_HEAD))) {
        return NGX_HTTP_NOT_ALLOWED;
    }

    rc = ngx_http_discard_request_body(r);

    if (rc != NGX_OK) {
        return rc;
    }

    hlcf = ngx_http_get_module_loc_conf(r, ngx_http_hello_module);

    ngx_http_hello_requests++;

    ngx_log_debug1(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                   "hello handler, request #%uA in this worker",
                   ngx_http_hello_requests);

    r->headers_out.status = NGX_HTTP_OK;
    r->headers_out.content_length_n = hlcf->text.len + 1;
    ngx_str_set(&r->headers_out.content_type, "text/plain");
    r->headers_out.content_type_len = r->headers_out.content_type.len;

    if (r->method == NGX_HTTP_HEAD) {
        return ngx_http_send_header(r);
    }

    b = ngx_create_temp_buf(r->pool, hlcf->text.len + 1);
    if (b == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    b->last = ngx_cpymem(b->last, hlcf->text.data, hlcf->text.len);
    *b->last++ = LF;
    b->last_buf = (r == r->main) ? 1 : 0;
    b->last_in_chain = 1;

    out.buf = b;
    out.next = NULL;

    rc = ngx_http_send_header(r);

    if (rc == NGX_ERROR || rc > NGX_OK || r->header_only) {
        return rc;
    }

    return ngx_http_output_filter(r, &out);
}


static ngx_int_t
ngx_http_hello_header_filter(ngx_http_request_t *r)
{
    ngx_str_t                   value;
    ngx_table_elt_t            *h;
    ngx_http_hello_loc_conf_t  *hlcf;

    hlcf = ngx_http_get_module_loc_conf(r, ngx_http_hello_module);

    if (hlcf->header == NULL || r != r->main) {
        return ngx_http_next_header_filter(r);
    }

    if (ngx_http_complex_value(r, hlcf->header, &value) != NGX_OK) {
        return NGX_ERROR;
    }

    if (value.len == 0) {
        return ngx_http_next_header_filter(r);
    }

    h = ngx_list_push(&r->headers_out.headers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    h->hash = 1;
    h->next = NULL;
    ngx_str_set(&h->key, "X-Hello");
    h->value = value;

    return ngx_http_next_header_filter(r);
}


static ngx_int_t
ngx_http_hello_requests_variable(ngx_http_request_t *r,
    ngx_http_variable_value_t *v, uintptr_t data)
{
    u_char  *p;

    p = ngx_pnalloc(r->pool, NGX_ATOMIC_T_LEN);
    if (p == NULL) {
        return NGX_ERROR;
    }

    v->len = ngx_sprintf(p, "%uA", ngx_http_hello_requests) - p;
    v->valid = 1;
    v->no_cacheable = 1;
    v->not_found = 0;
    v->data = p;

    return NGX_OK;
}


static char *
ngx_http_hello(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_core_loc_conf_t  *clcf;
    char                      *rv;

    rv = ngx_conf_set_str_slot(cf, cmd, conf);
    if (rv != NGX_CONF_OK) {
        return rv;
    }

    clcf = ngx_http_conf_get_module_loc_conf(cf, ngx_http_core_module);
    clcf->handler = ngx_http_hello_handler;

    return NGX_CONF_OK;
}


static ngx_int_t
ngx_http_hello_add_variables(ngx_conf_t *cf)
{
    ngx_http_variable_t  *var, *v;

    for (v = ngx_http_hello_vars; v->name.len; v++) {
        var = ngx_http_add_variable(cf, &v->name, v->flags);
        if (var == NULL) {
            return NGX_ERROR;
        }

        var->get_handler = v->get_handler;
        var->data = v->data;
    }

    return NGX_OK;
}


static void *
ngx_http_hello_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_hello_loc_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_hello_loc_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    /*
     * set by ngx_pcalloc():
     *
     *     conf->text = { 0, NULL };
     */

    conf->header = NGX_CONF_UNSET_PTR;

    return conf;
}


static char *
ngx_http_hello_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_hello_loc_conf_t  *prev = parent;
    ngx_http_hello_loc_conf_t  *conf = child;

    ngx_conf_merge_str_value(conf->text, prev->text, "");
    ngx_conf_merge_ptr_value(conf->header, prev->header, NULL);

    return NGX_CONF_OK;
}


static ngx_int_t
ngx_http_hello_init(ngx_conf_t *cf)
{
    ngx_http_next_header_filter = ngx_http_top_header_filter;
    ngx_http_top_header_filter = ngx_http_hello_header_filter;

    return NGX_OK;
}
