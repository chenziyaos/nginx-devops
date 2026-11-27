# cloud-07 hypotheses (from the source of nginx 1.31.10, njs 1.0.2, ngx-rust 0.5.0 and glibc)

One nginx loads three dynamic modules built against the configure arguments of the base
image: ngx_http_js_module (njs with QuickJS-NG, `js_engine qjs`), ngx_http_curl_module (the
"curl" example of ngx-rust) and ngx_http_nocurl_module (the same check in C). Each refuses a
User-Agent starting with "curl" in the access phase.

1. `nginx -t` passes with all three and `js_engine qjs` (the qjs engine exists only when
   configure found QuickJS, nginx/config of njs).
2. /js, /rust and /c answer 403 to curl and pass Mozilla and Wget to the backend (200).
   njs: `r.return(403)` sends the response, `ngx_http_js_access_finalize` sees
   `header_sent` and ends the request; returning without a response leaves `ctx->status`
   NGX_OK and the phase goes on (nginx/ngx_http_js_module.c:1533-1647).
3. `js_import` compiles the file while the config is parsed. A changed nocurl.js on disk
   does nothing until a reload; after it /js refuses Wget, /c still passes it.
4. `load_module` calls `dlopen(path, RTLD_NOW | RTLD_GLOBAL)` in the master
   (src/core/nginx.c:1680, src/os/unix/ngx_dlopen.h:16). The old cycle, and with its pool
   the dlclose() of its handle, goes away only after the new cycle is built
   (src/core/ngx_cycle.c:783-785). glibc returns the loaded object for a file name it has
   loaded, without opening the file. After `mv` of the 451 build over
   ngx_http_nocurl_module.so and a reload, the new worker still answers 403, and its maps
   show the old file as "(deleted)".
5. With load_module pointing to another file, nocurl-451.so is opened and mapped. Its
   references to `ngx_http_nocurl_module` (the `ngx_modules` table and the handler's
   `ngx_http_get_module_loc_conf`) are relocations against a default-visibility symbol,
   resolved in the global scope, where the object loaded first with RTLD_GLOBAL defines it.
   The new cycle uses the old module structure, the old handler: still 403. The binding
   keeps the old object loaded after its dlclose().
6. A new master (container restart) loads every module from scratch: 451.
7. A call that throws: `ngx_qjs_call` logs "js call exception" and returns NGX_ERROR
   (nginx/ngx_js.c:1240-1245); the access handler returns 500 (ngx_http_js_module.c:1573-1575).
   The worker keeps running.
8. `curl yes`: the Rust example sets `enable = false` first and changes it only for "on"
   or "off" (examples/curl.rs:129-137), so the config is accepted and curl passes (200).
   `nocurl yes`: ngx_conf_set_flag_slot rejects it with `invalid value "yes"`.
