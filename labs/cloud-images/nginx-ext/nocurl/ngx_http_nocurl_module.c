
/*
 * ngx_http_nocurl_module: the "curl" example module of ngx-rust, written in C.
 * "nocurl on;" makes the access phase answer 403 to requests whose User-Agent
 * starts with "curl"; other requests go on to the next access handler.
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


typedef struct {
    ngx_flag_t  enable;
} ngx_http_nocurl_loc_conf_t;


static ngx_int_t ngx_http_nocurl_handler(ngx_http_request_t *r);
static void *ngx_http_nocurl_create_loc_conf(ngx_conf_t *cf);
static char *ngx_http_nocurl_merge_loc_conf(ngx_conf_t *cf, void *parent,
    void *child);
static ngx_int_t ngx_http_nocurl_init(ngx_conf_t *cf);


static ngx_command_t  ngx_http_nocurl_commands[] = {

    { ngx_string("nocurl"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_FLAG,
      ngx_conf_set_flag_slot,
      NGX_HTTP_LOC_CONF_OFFSET,
      offsetof(ngx_http_nocurl_loc_conf_t, enable),
      NULL },

      ngx_null_command
};


static ngx_http_module_t  ngx_http_nocurl_module_ctx = {
    NULL,                                  /* preconfiguration */
    ngx_http_nocurl_init,                  /* postconfiguration */

    NULL,                                  /* create main configuration */
    NULL,                                  /* init main configuration */

    NULL,                                  /* create server configuration */
    NULL,                                  /* merge server configuration */

    ngx_http_nocurl_create_loc_conf,       /* create location configuration */
    ngx_http_nocurl_merge_loc_conf         /* merge location configuration */
};


ngx_module_t  ngx_http_nocurl_module = {
    NGX_MODULE_V1,
    &ngx_http_nocurl_module_ctx,           /* module context */
    ngx_http_nocurl_commands,              /* module directives */
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


static ngx_int_t
ngx_http_nocurl_handler(ngx_http_request_t *r)
{
    ngx_table_elt_t             *ua;
    ngx_http_nocurl_loc_conf_t  *nlcf;

    nlcf = ngx_http_get_module_loc_conf(r, ngx_http_nocurl_module);

    if (!nlcf->enable) {
        return NGX_DECLINED;
    }

    ua = r->headers_in.user_agent;

    if (ua != NULL
        && ua->value.len >= sizeof("curl") - 1
        && ngx_strncmp(ua->value.data, "curl", sizeof("curl") - 1) == 0)
    {
        return NGX_HTTP_FORBIDDEN;
    }

    return NGX_DECLINED;
}


static void *
ngx_http_nocurl_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_nocurl_loc_conf_t  *conf;

    conf = ngx_pcalloc(cf->pool, sizeof(ngx_http_nocurl_loc_conf_t));
    if (conf == NULL) {
        return NULL;
    }

    conf->enable = NGX_CONF_UNSET;

    return conf;
}


static char *
ngx_http_nocurl_merge_loc_conf(ngx_conf_t *cf, void *parent, void *child)
{
    ngx_http_nocurl_loc_conf_t *prev = parent;
    ngx_http_nocurl_loc_conf_t *conf = child;

    ngx_conf_merge_value(conf->enable, prev->enable, 0);

    return NGX_CONF_OK;
}


static ngx_int_t
ngx_http_nocurl_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt        *h;
    ngx_http_core_main_conf_t  *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_ACCESS_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }

    *h = ngx_http_nocurl_handler;

    return NGX_OK;
}
