/*
 * dev-10: a do-nothing dynamic module whose version or signature can be overridden at
 * compile time, to show the checks ngx_add_module makes before it accepts a module.
 *
 *   cc ... -shared -DFAKE_VERSION=1030007 fake.c        "version ... instead of ..."
 *   cc ... -shared -DFAKE_SIGNATURE='"8,4,8,0"' fake.c  "is not binary compatible"
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


#ifndef FAKE_VERSION
#define FAKE_VERSION    nginx_version
#endif

#ifndef FAKE_SIGNATURE
#define FAKE_SIGNATURE  NGX_MODULE_SIGNATURE
#endif


static ngx_http_module_t  ngx_http_fake_module_ctx = {
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
};


/* NGX_MODULE_V1 spelled out, so that version and signature can be replaced */

ngx_module_t  ngx_http_fake_module = {
    NGX_MODULE_UNSET_INDEX, NGX_MODULE_UNSET_INDEX,
    NULL, 0, 0, FAKE_VERSION, FAKE_SIGNATURE,
    &ngx_http_fake_module_ctx,             /* module context */
    NULL,                                  /* module directives */
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


/* what configure writes into objs/<module>_modules.c for a dynamic module */

ngx_module_t  *ngx_modules[] = {
    &ngx_http_fake_module,
    NULL
};

char  *ngx_module_names[] = {
    "ngx_http_fake_module",
    NULL
};
