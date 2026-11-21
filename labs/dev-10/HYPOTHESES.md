# dev-10 hypotheses (from the source, before running)

1. modules/ngx_http_hello_module/config declares ngx_module_type=HTTP_FILTER and no
   ngx_module_order, so auto/module writes ngx_module_order = { "ngx_http_hello_module",
   "ngx_http_copy_filter_module" } into objs/ngx_http_hello_module_modules.c. The .so and the
   nginx binary carry the same NGX_MODULE_SIGNATURE string.
2. "hello" sets clcf->handler: GET returns the text plus LF (19 bytes for
   "hi from the module"), HEAD returns the same Content-Length without a body, POST is 405.
3. hello_header is created as NGX_CONF_UNSET_PTR and merged with ngx_conf_merge_ptr_value:
   a location without it inherits the server's "srv"; hello_header "" yields an empty value,
   which the filter skips; a value with $uri is evaluated per request.
4. ngx_add_module inserts the module before ngx_http_copy_filter_module, i.e. after
   ngx_http_headers_filter_module in cycle->modules. Postconfiguration runs in that order and
   each filter puts itself on top, so the hello header filter is called before the headers
   filter: X-Hello is pushed to headers_out.headers first and appears before add_header's X-Add.
5. $hello_requests is NOCACHEABLE: set in the rewrite phase reads the count before the content
   handler increments it; the access log flushes no-cacheable variables of its format
   (ngx_http_script_flush_no_cacheable_variables) and reads it again, one higher.
   Counts: GET /hello 1, HEAD /hello 2 (the counter is incremented before the HEAD check), the
   POST is refused before it, so /count logs before=2 now=3, then before=3 now=4.
   Revised after the first run: the step before also sends one GET and one HEAD inside its
   expect line, so the count is 4 when /count runs: before=4 now=5, then before=5 now=6.
6. ngx_add_module refuses a module whose version is not nginx_version ("version 1030007
   instead of 1031009") or whose signature differs ("is not binary compatible"); load_module
   after events{} is "specified too late" (ngx_count_modules set cycle->modules_used); loading
   the same module twice is "already loaded".
7. The counter is a static variable of the .so: each worker has its own copy. After a reload
   the new worker starts from 0: /total says 6 before (see 5), 1 after one more /hello.
